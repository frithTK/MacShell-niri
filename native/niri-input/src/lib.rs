//! Pure transformations for the generated niri input profile.
//! It never writes the user's configuration.
pub mod coordinator;
pub mod exchange;
mod fragment;
pub mod includes;
pub mod journal;
pub mod journal_store;
pub mod lock;
pub mod prepare;
pub mod progress;
pub mod progress_store;
pub mod recovery;
pub mod snapshot;
pub mod staging;
pub mod validation;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// A complete in-memory plan. Nothing is written by constructing this value.
/// Both changed and unchanged files remain in `before` for conflict detection.
#[derive(Debug, PartialEq, Eq)]
pub struct Plan {
    pub before: BTreeMap<PathBuf, Vec<u8>>,
    pub changes: BTreeMap<PathBuf, Vec<u8>>,
}

/// Plan only an update to the managed fragment. Existing managed input nodes
/// elsewhere require explicit migration and are never rewritten by this plan.
/// This is a conservative syntax check, not an authorization to write.
pub fn plan_single_fragment(
    files: BTreeMap<PathBuf, Vec<u8>>,
    fragment: &Path,
    values: &Value,
) -> Result<Plan, String> {
    includes::require_single_reachable(&files, fragment)?;
    let plan = plan_profile(files, fragment, values)?;
    if let Some((path, _)) = plan.changes.iter().find(|(path, _)| *path != fragment) {
        return Err(format!(
            "Managed input settings exist outside the input fragment: {}",
            path.display()
        ));
    }
    Ok(plan)
}

/// Build a plan only from a complete snapshot of a single generated profile.
/// Callers must separately ensure the snapshot is complete, validate the
/// resulting profile and enforce filesystem identity before committing it.
pub fn plan_profile(
    files: BTreeMap<PathBuf, Vec<u8>>,
    fragment: &Path,
    values: &Value,
) -> Result<Plan, String> {
    const MAX_FILES: usize = 1024;
    const MAX_TOTAL: usize = 16 * 1024 * 1024;
    const MAX_FILE: usize = 2 * 1024 * 1024;
    fn safe_relative(path: &Path) -> bool {
        !path.as_os_str().is_empty()
            && path
                .components()
                .all(|part| matches!(part, Component::Normal(_)))
            && path.extension().is_some_and(|ext| ext == "kdl")
    }
    if files.len() > MAX_FILES || !safe_relative(fragment) || fragment == Path::new("config.kdl") {
        return Err("Invalid profile or input fragment".into());
    }
    if !files.contains_key(Path::new("config.kdl")) || !files.contains_key(fragment) {
        return Err("Incomplete profile snapshot".into());
    }
    let mut total = 0usize;
    let mut changes = BTreeMap::new();
    let generated = input_config(values)?.into_bytes();
    for (path, before) in &files {
        total = total
            .checked_add(before.len())
            .ok_or("Profile is too large")?;
        if !safe_relative(path) || before.len() > MAX_FILE || total > MAX_TOTAL {
            return Err("Invalid or oversized profile file".into());
        }
        let text = std::str::from_utf8(before).map_err(|_| "Profile is not UTF-8")?;
        let after = if path == fragment {
            if before != &generated && !fragment::is_untouched(text) {
                return Err("Input fragment contains unrecognized changes".into());
            }
            generated.clone()
        } else {
            without_input_preferences(text)?.into_bytes()
        };
        if after != *before {
            changes.insert(path.clone(), after);
        }
    }
    Ok(Plan {
        before: files,
        changes,
    })
}

fn number(values: &Value, name: &str, lo: f64, hi: f64) -> Result<f64, String> {
    let value = values
        .get(name)
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("Invalid {name}"))?;
    Ok(value.clamp(lo, hi))
}

pub fn input_config(values: &Value) -> Result<String, String> {
    fn flag<'a>(v: &Value, key: &str, setting: &'a str) -> Result<&'a str, String> {
        match v.get(key).and_then(Value::as_bool) {
            Some(true) => Ok(setting),
            Some(false) => Ok(""),
            None => Err(format!("Invalid {key}")),
        }
    }
    let rate = number(values, "repeatRate", 1.0, 200.0)? as i32;
    let delay = number(values, "repeatDelay", 100.0, 2000.0)? as i32;
    let mouse = number(values, "mouseSens", -1.0, 1.0)?;
    let scroll = number(values, "tpScroll", 0.1, 5.0)?;
    let mn = flag(values, "mouseNatural", "natural-scroll;")?;
    let tn = flag(values, "tpNatural", "natural-scroll;")?;
    let tap = flag(values, "tpTap", "tap;")?;
    let dwt = flag(values, "tpDwt", "dwt;")?;
    Ok(format!("// Generated only when input preferences change in MacShell.\ninput {{\n    keyboard {{ repeat-rate {rate}; repeat-delay {delay}; }}\n    mouse {{ accel-speed {mouse:.2}; {mn} }}\n    touchpad {{\n        {tn}\n        {tap}\n        {dwt}\n        scroll-factor {scroll:.2}\n    }}\n}}\n"))
}

/// Remove only managed fields, retaining all other bytes. Refuse incomplete
/// strings, comments and braces instead of guessing how to edit the document.
pub fn without_input_preferences(text: &str) -> Result<String, String> {
    includes::check_newlines(text)?;
    let bytes = text.as_bytes();
    let mut masked = bytes.to_vec();
    let mut i = 0;
    let mut comments = Vec::new();
    while i < bytes.len() {
        let start = i;
        let mut end = None;
        if bytes[i..].starts_with(b"//") {
            i += 2;
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            comments.push((start, i));
            end = Some(i);
        } else if bytes[i..].starts_with(b"/*") {
            i += 2;
            let mut depth = 1;
            while i < bytes.len() && depth > 0 {
                if bytes[i..].starts_with(b"/*") {
                    depth += 1;
                    i += 2;
                } else if bytes[i..].starts_with(b"*/") {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if depth != 0 {
                return Err("Unclosed comment".into());
            }
            comments.push((start, i));
            end = Some(i);
        } else if bytes[i..].starts_with(b"/-") {
            // Niri disables one complete node with `/-`. Preserve it byte-for-
            // byte while hiding its managed-looking children from the removal
            // scanner below.
            let start_disabled = i;
            i += 2;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() && bytes[i] != b'\n' { i += 1; }
            let mut braces = 0usize;
            let mut quote = false;
            while i < bytes.len() {
                if !quote && bytes[i..].starts_with(b"//") {
                    while i < bytes.len() && bytes[i] != b'\n' { i += 1; }
                } else if !quote && bytes[i] == b'"' {
                    quote = true; i += 1;
                } else if quote && bytes[i] == b'\\' {
                    i = (i + 2).min(bytes.len());
                } else if quote && bytes[i] == b'"' {
                    quote = false; i += 1;
                } else if !quote && bytes[i] == b'{' {
                    braces += 1; i += 1;
                } else if !quote && bytes[i] == b'}' {
                    braces = braces.checked_sub(1).ok_or("Unmatched disabled node")?;
                    i += 1;
                    if braces == 0 { break; }
                } else if !quote && braces == 0 && bytes[i] == b';' {
                    i += 1; break;
                } else { i += 1; }
            }
            if quote || braces != 0 { return Err("Unclosed disabled node".into()); }
            for byte in &mut masked[start_disabled..i] {
                if *byte != b'\n' { *byte = b' '; }
            }
        } else if bytes[i..].starts_with(b"\"\"\"") || bytes[i] == b'\\' {
            return Err("Unsupported KDL syntax".into());
        } else {
            let mut raw = i;
            if bytes[i] == b'r' {
                raw += 1;
            }
            while raw < bytes.len() && bytes[raw] == b'#' {
                raw += 1;
            }
            let hashes = raw - i - usize::from(bytes[i] == b'r');
            let raw_string = raw < bytes.len() && bytes[raw] == b'"' && hashes > 0;
            if raw_string && bytes[raw..].starts_with(b"\"\"\"") {
                return Err("Unsupported KDL multiline string".into());
            }
            if bytes[i] == b'"' || raw_string {
                i = if raw_string { raw + 1 } else { i + 1 };
                let mut closed = false;
                while i < bytes.len() {
                    if !raw_string && bytes[i] == b'\\' {
                        i = (i + 2).min(bytes.len());
                        continue;
                    }
                    if bytes[i] == b'"'
                        && (!raw_string
                            || (i + 1 + hashes <= bytes.len()
                                && bytes[i + 1..i + 1 + hashes].iter().all(|b| *b == b'#')))
                    {
                        i += 1 + if raw_string { hashes } else { 0 };
                        closed = true;
                        break;
                    }
                    i += 1;
                }
                if !closed {
                    return Err("Unclosed string".into());
                }
                end = Some(i);
            }
        }
        if let Some(end) = end {
            for byte in &mut masked[start..end] {
                if *byte != b'\n' {
                    *byte = b' ';
                }
            }
        } else {
            i += 1;
        }
    }
    let is_word = |b: u8| b.is_ascii_alphanumeric() || b == b'_' || b == b'-';
    let mut stack: Vec<String> = Vec::new();
    let mut node_name = String::new();
    let mut at_node_start = true;
    let mut removals = Vec::new();
    let mut i = 0;
    while i < masked.len() {
        if masked[i] == b'{' {
            stack.push(node_name.clone());
            node_name.clear();
            at_node_start = true;
            i += 1;
        } else if masked[i] == b'}' {
            if stack.pop().is_none() {
                return Err("Unmatched closing brace".into());
            }
            node_name.clear();
            at_node_start = false;
            i += 1;
        } else if masked[i].is_ascii_alphabetic() || masked[i] == b'_' {
            let start = i;
            i += 1;
            while i < masked.len() && is_word(masked[i]) {
                i += 1;
            }
            let word = &text[start..i];
            let managed = at_node_start
                && stack.len() >= 2
                && stack[stack.len() - 2] == "input"
                && match stack.last().map(String::as_str) {
                    Some("keyboard") => matches!(word, "repeat-rate" | "repeat-delay"),
                    Some("mouse") => matches!(word, "accel-speed" | "natural-scroll"),
                    Some("touchpad") => {
                        matches!(word, "natural-scroll" | "tap" | "dwt" | "scroll-factor")
                    }
                    _ => false,
                };
            if managed {
                while i < masked.len() && !matches!(masked[i], b';' | b'\n' | b'}') {
                    i += 1;
                }
                if i < masked.len() && masked[i] == b';' {
                    i += 1;
                }
                // Removing a node must not silently discard or split a
                // user's comment. Until comments can be retained with their
                // intended association, reject this edit rather than guess.
                let next = comments.partition_point(|&(_, end)| end <= start);
                if comments.get(next).is_some_and(|&(begin, _)| begin < i) {
                    return Err("Comment inside managed input setting".into());
                }
                removals.push((start, i));
                node_name.clear();
                at_node_start = i > 0 && masked[i - 1] == b';';
            } else {
                if at_node_start {
                    node_name = word.to_owned();
                }
                at_node_start = false;
            }
        } else {
            if matches!(masked[i], b';' | b'\n') {
                node_name.clear();
                at_node_start = true;
            } else if !masked[i].is_ascii_whitespace() {
                at_node_start = false;
            }
            i += 1;
        }
    }
    if !stack.is_empty() {
        return Err("Unclosed block".into());
    }
    let mut result = text.to_owned();
    for (start, end) in removals.into_iter().rev() {
        result.replace_range(start..end, "");
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn removes_only_managed_nodes_and_preserves_comments_and_strings() {
        let original = "// repeat-rate 90\ninput { keyboard { repeat-rate 30; xkb { layout \"us,ru\"; }; }; mouse { natural-scroll; accel-profile \"flat\"; }; }\n";
        let result = without_input_preferences(original).unwrap();
        assert_eq!(result, "// repeat-rate 90\ninput { keyboard {  xkb { layout \"us,ru\"; }; }; mouse {  accel-profile \"flat\"; }; }\n");
    }
    #[test]
    fn rejects_incomplete_documents() {
        for input in ["input {", "input { mouse { tap; }", "/* x", "\"oops", "}"] {
            assert!(without_input_preferences(input).is_err());
        }
    }

    #[test]
    fn transformation_rejects_unhandled_node_boundaries() {
        for newline in ["\r", "\u{000c}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let input = format!("input {{ keyboard {{ repeat-rate 30{newline}layout \"us\"; }} }}");
            assert!(without_input_preferences(&input).is_err());
        }
        assert!(
            without_input_preferences("input {\r\n mouse { natural-scroll; }\r\n}\r\n").is_ok()
        );
    }

    #[test]
    fn does_not_discard_or_split_comments_in_managed_nodes() {
        for input in [
            "input { keyboard { repeat-rate 30 // user's note\n; } }",
            "input { keyboard { repeat-rate /* keep */ 30; } }",
            "input { keyboard { repeat-rate 30 /* first\nsecond */; } }",
        ] {
            assert!(without_input_preferences(input).is_err(), "{input}");
        }
        let input = "input { keyboard { repeat-rate 30; // keep\n } }";
        let output = without_input_preferences(input).unwrap();
        assert!(output.contains("// keep"));
        assert!(!output.contains("repeat-rate"));
    }
    #[test]
    fn masks_nested_comments_and_raw_strings() {
        let input = "input { keyboard { xkb { layout r#\"} repeat-rate 12\"#; }; /* nested /* } */ ok */ repeat-rate 30; }; }";
        let out = without_input_preferences(input).unwrap();
        assert!(out.contains("r#\"} repeat-rate 12\"#"));
        assert!(out.contains("/* nested /* } */ ok */"));
        assert!(!out.contains("repeat-rate 30"));
    }
    #[test]
    fn leaves_unmanaged_arguments_alone_and_rejects_unsupported_syntax() {
        let input = "input { mouse { custom tap; natural-scroll; } }";
        assert_eq!(
            without_input_preferences(input).unwrap(),
            "input { mouse { custom tap;  } }"
        );
        for input in [
            "input { mouse { foo \"\"\"x\"\"\"; } }",
            "input { mouse { foo #\"\"\"x\"\"\"#; } }",
        ] {
            assert!(without_input_preferences(input).is_err());
        }
    }
    #[test]
    fn plans_complete_profiles_without_writing() {
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let files = BTreeMap::from([
            (
                PathBuf::from("config.kdl"),
                b"include \"./old.kdl\"\n".to_vec(),
            ),
            (
                PathBuf::from("old.kdl"),
                b"input { mouse { natural-scroll; } }\n".to_vec(),
            ),
            (
                PathBuf::from("macshell-input.kdl"),
                b"// Input preferences remain unchanged until edited in MacShell.\n".to_vec(),
            ),
        ]);
        let plan = plan_profile(files.clone(), Path::new("macshell-input.kdl"), &values).unwrap();
        assert_eq!(plan.before, files);
        assert_eq!(plan.changes.len(), 2);
        assert!(!plan.changes.contains_key(Path::new("config.kdl")));
        assert_eq!(
            plan.changes[Path::new("old.kdl")],
            b"input { mouse {  } }\n"
        );
        let mut bad = files.clone();
        bad.insert(PathBuf::from("../outside.kdl"), Vec::new());
        assert!(plan_profile(bad, Path::new("macshell-input.kdl"), &values).is_err());
        let mut incomplete = files;
        incomplete.remove(Path::new("config.kdl"));
        assert!(plan_profile(incomplete, Path::new("macshell-input.kdl"), &values).is_err());
    }

    #[test]
    fn single_fragment_plan_refuses_external_managed_nodes() {
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let fragment = Path::new("macshell-input.kdl");
        let mut files = BTreeMap::from([
            (
                PathBuf::from("config.kdl"),
                b"include \"./macshell-input.kdl\"\n".to_vec(),
            ),
            (
                fragment.to_owned(),
                b"// Input preferences remain unchanged until edited in MacShell.\n".to_vec(),
            ),
            (
                PathBuf::from("nested/extra.kdl"),
                b"input { keyboard { xkb { layout \"us\"; }; }; }\n".to_vec(),
            ),
        ]);
        let plan = plan_single_fragment(files.clone(), fragment, &values).unwrap();
        assert_eq!(plan.changes.len(), 1);
        assert!(plan.changes.contains_key(fragment));
        files.insert(
            PathBuf::from("nested/extra.kdl"),
            b"input { mouse { accel-speed 0.2; } }\n".to_vec(),
        );
        let error = plan_single_fragment(files.clone(), fragment, &values).unwrap_err();
        assert!(error.contains("nested/extra.kdl"));
        assert_eq!(
            files[Path::new("nested/extra.kdl")],
            b"input { mouse { accel-speed 0.2; } }\n"
        );
        files.insert(
            PathBuf::from("nested/extra.kdl"),
            b"/- input { mouse { accel-speed 0.2; } }\n".to_vec(),
        );
        assert!(plan_single_fragment(files.clone(), fragment, &values).is_ok());
    }

    #[test]
    fn refuses_to_replace_edited_fragment() {
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let generated = input_config(&values).unwrap();
        let edited = format!("{generated}// user's note\n");
        let files = BTreeMap::from([
            (PathBuf::from("config.kdl"), b"// config\n".to_vec()),
            (PathBuf::from("macshell-input.kdl"), edited.into_bytes()),
        ]);
        let error =
            plan_profile(files.clone(), Path::new("macshell-input.kdl"), &values).unwrap_err();
        assert!(error.contains("unrecognized changes"));
        assert!(files[Path::new("macshell-input.kdl")].ends_with(b"// user's note\n"));
    }
}
