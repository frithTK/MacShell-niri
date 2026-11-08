//! Conservative include analysis for validation of a staged profile.
//!
//! Accepts only plain relative include strings referring to files in the
//! snapshot. Unfamiliar syntax is rejected rather than resolved externally.
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

fn fail<T>() -> Result<T, String> {
    Err("Unsupported or external include in niri profile".into())
}
fn word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-')
}

/// Check every file, not just files reachable from config.kdl. This ensures the
/// staged profile cannot gain an unchecked include if an include graph changes.
pub fn check(files: &BTreeMap<PathBuf, Vec<u8>>) -> Result<(), String> {
    for (path, contents) in files {
        let text = std::str::from_utf8(contents).map_err(|_| "Profile is not UTF-8")?;
        check_newlines(text)?;
        check_file(path, contents, files)?;
    }
    Ok(())
}

/// Require the managed fragment to be reached exactly once from config.kdl.
/// This uses the same conservative syntax restrictions as validation. It does
/// not establish that niri has reloaded or applied the configuration.
pub fn require_single_reachable(
    files: &BTreeMap<PathBuf, Vec<u8>>,
    fragment: &Path,
) -> Result<(), String> {
    let mut graph = BTreeMap::new();
    for (path, contents) in files {
        let text = std::str::from_utf8(contents).map_err(|_| "Profile is not UTF-8")?;
        check_newlines(text)?;
        graph.insert(path.clone(), check_file(path, contents, files)?);
    }
    let root = PathBuf::from("config.kdl");
    if !graph.contains_key(&root) || !graph.contains_key(fragment) {
        return fail();
    }
    let mut stack = vec![root];
    let mut visited = BTreeSet::new();
    let mut count = 0usize;
    while let Some(path) = stack.pop() {
        if !visited.insert(path.clone()) {
            // Reject duplicate inclusions and cycles rather than guessing how
            // niri merges or limits repeated include paths.
            return fail();
        }
        if path == fragment {
            count += 1;
        }
        stack.extend(graph.get(&path).ok_or("Missing include")?.iter().cloned());
    }
    if count != 1 {
        return Err("Managed input fragment is not reachable from config.kdl".into());
    }
    Ok(())
}

// Both byte-oriented scanners only recognize LF (including CRLF). Reject
// other KDL newline characters everywhere, including strings and comments.
pub(crate) fn check_newlines(text: &str) -> Result<(), String> {
    let bytes = text.as_bytes();
    if text.contains(['\u{000c}', '\u{0085}', '\u{2028}', '\u{2029}'])
        || bytes
            .iter()
            .enumerate()
            .any(|(i, b)| *b == b'\r' && bytes.get(i + 1) != Some(&b'\n'))
    {
        return fail();
    }
    Ok(())
}

fn check_file(
    path: &Path,
    data: &[u8],
    files: &BTreeMap<PathBuf, Vec<u8>>,
) -> Result<Vec<PathBuf>, String> {
    let mut i = 0;
    let mut node_start = true;
    let mut depth = 0usize;
    let mut includes = Vec::new();
    while i < data.len() {
        let mut raw = i;
        if data[i] == b'r' { raw += 1; }
        while raw < data.len() && data[raw] == b'#' { raw += 1; }
        if raw > i && data[raw..].starts_with(b"\"") && data[i..raw].contains(&b'#') {
            if node_start { return fail(); }
            let hashes = raw - i - 1;
            i = raw + 1;
            let mut closed = false;
            while i < data.len() {
                if data[i] == b'"' {
                    let mut end = i + 1;
                    let mut count = 0;
                    while count < hashes && end < data.len() && data[end] == b'#' { end += 1; count += 1; }
                    if count == hashes { i = end; closed = true; break; }
                }
                if data[i] == b'\n' { /* raw strings may contain newlines */ }
                i += 1;
            }
            if !closed { return fail(); }
            node_start = false;
        } else if data[i..].starts_with(b"//") {
            while i < data.len() && data[i] != b'\n' {
                i += 1;
            }
        } else if data[i..].starts_with(b"/*") {
            i += 2;
            let mut depth = 1usize;
            while i < data.len() && depth > 0 {
                if data[i..].starts_with(b"/*") {
                    depth += 1;
                    i += 2;
                } else if data[i..].starts_with(b"*/") {
                    depth -= 1;
                    i += 2;
                } else if data[i] == b'\n' {
                    return fail();
                } else {
                    i += 1;
                }
            }
            if depth != 0 {
                return fail();
            }
        } else if data[i..].starts_with(b"/-") {
            // Niri's `/-` disables one complete node. It is still valid KDL
            // syntax and must be skipped without treating includes inside the
            // disabled node as active includes.
            i += 2;
            while i < data.len() && data[i].is_ascii_whitespace() && data[i] != b'\n' {
                i += 1;
            }
            if i >= data.len() || !data[i].is_ascii_alphabetic() {
                return fail();
            }
            while i < data.len() && data[i] != b'\n' && data[i] != b'{' && data[i] != b';' {
                if data[i] == b'"' {
                    i += 1;
                    while i < data.len() && data[i] != b'"' {
                        if data[i] == b'\\' { i = (i + 2).min(data.len()); } else { i += 1; }
                    }
                    if i >= data.len() { return fail(); }
                }
                i += 1;
            }
            if i < data.len() && data[i] == b';' {
                i += 1;
            } else if i < data.len() && data[i] == b'{' {
                let mut nested = 1usize;
                i += 1;
                while i < data.len() && nested > 0 {
                    if data[i..].starts_with(b"//") {
                        while i < data.len() && data[i] != b'\n' { i += 1; }
                    } else if data[i] == b'{' { nested += 1; i += 1; }
                    else if data[i] == b'}' { nested -= 1; i += 1; }
                    else if data[i] == b'"' {
                        i += 1;
                        while i < data.len() && data[i] != b'"' {
                            if data[i] == b'\\' { i = (i + 2).min(data.len()); } else { i += 1; }
                        }
                        if i < data.len() { i += 1; }
                    } else { i += 1; }
                }
                if nested != 0 { return fail(); }
            }
            node_start = true;
        } else if data[i] == b'\\'
            || data[i..].starts_with(b"\"\"\"")
        {
            return fail();
        } else if matches!(data[i], b'\n' | b';' | b'{' | b'}') {
            if data[i] == b'{' {
                depth = depth.checked_add(1).ok_or("Invalid nesting")?;
            } else if data[i] == b'}' {
                depth = depth.checked_sub(1).ok_or("Invalid nesting")?;
            }
            node_start = true;
            i += 1;
        } else if data[i].is_ascii_whitespace() {
            i += 1;
        } else if node_start && (data[i].is_ascii_alphabetic() || data[i] == b'_') {
            let start = i;
            i += 1;
            while i < data.len() && word(data[i]) {
                i += 1;
            }
            if &data[start..i] == b"include" {
                if depth != 0 {
                    return fail();
                }
                while i < data.len() && matches!(data[i], b' ' | b'\t') {
                    i += 1;
                }
                if i >= data.len() || data[i] != b'"' {
                    return fail();
                }
                i += 1;
                let target_start = i;
                while i < data.len() && data[i] != b'"' {
                    if data[i] == b'\\' || data[i].is_ascii_control() {
                        return fail();
                    }
                    i += 1;
                }
                if i >= data.len() {
                    return fail();
                }
                let target =
                    std::str::from_utf8(&data[target_start..i]).map_err(|_| "Invalid include")?;
                let mut resolved = path.parent().unwrap_or(Path::new("")).to_path_buf();
                if target.is_empty()
                    || !target.bytes().all(|b| {
                        b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'/')
                    })
                {
                    return fail();
                }
                for part in Path::new(target).components() {
                    match part {
                        Component::Normal(name) => resolved.push(name),
                        Component::CurDir => (),
                        _ => return fail(),
                    }
                }
                if !files.contains_key(&resolved) {
                    return fail();
                }
                includes.push(resolved);
                i += 1;
                while i < data.len() && matches!(data[i], b' ' | b'\t' | b'\r') {
                    i += 1;
                }
                if i < data.len()
                    && !matches!(data[i], b'\n' | b';' | b'}')
                    && !data[i..].starts_with(b"//")
                {
                    return fail();
                }
            }
            node_start = false;
        } else if data[i] == b'"' {
            // Quoted node identifiers could spell "include" using escapes.
            if node_start {
                return fail();
            }
            i += 1;
            let mut closed = false;
            while i < data.len() {
                if data[i] == b'\\' {
                    i = (i + 2).min(data.len());
                } else if data[i] == b'"' {
                    i += 1;
                    closed = true;
                    break;
                } else if data[i] == b'\n' {
                    return fail();
                } else {
                    i += 1;
                }
            }
            if !closed {
                return fail();
            }
        } else {
            // Reject raw string and typed node syntax at a node boundary.
            if node_start {
                return fail();
            }
            i += 1;
        }
    }
    if depth != 0 {
        return fail();
    }
    Ok(includes)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(config: &str) -> BTreeMap<PathBuf, Vec<u8>> {
        BTreeMap::from([
            (PathBuf::from("config.kdl"), config.as_bytes().to_vec()),
            (PathBuf::from("nested/local.kdl"), b"// harmless\n".to_vec()),
        ])
    }
    #[test]
    fn accepts_local_include_and_ignores_text_in_comments_and_values() {
        assert!(check(&profile(
            "// include \"/private\"\ninclude \"./nested/local.kdl\"\nspawn \"include /tmp/x\"\n"
        ))
        .is_ok());
    }
    #[test]
    fn accepts_niri_disabled_nodes_without_following_their_contents() {
        let mut files = profile(
            "/- output \"DP-1\" { include \"./missing.kdl\"; mode \"2560x1440\"; }\ninclude \"./nested/local.kdl\"\n",
        );
        assert!(check(&files).is_ok());
        assert!(require_single_reachable(&files, Path::new("nested/local.kdl")).is_ok());
        files.insert(
            PathBuf::from("config.kdl"),
            b"/- include \"./nested/local.kdl\"\ninclude \"./nested/local.kdl\"\n".to_vec(),
        );
        assert!(require_single_reachable(&files, Path::new("nested/local.kdl")).is_ok());
    }
    #[test]
    fn accepts_installed_disabled_output_template() {
        let mut files = profile("include \"./nested/local.kdl\"\n");
        files.insert(PathBuf::from("display.kdl"), br#"/- output "DP-1" {
    mode "2560x1440@359.979"
    scale 1
}
"#.to_vec());
        assert!(check(&files).is_ok());
    }
    #[test]
    fn rejects_escape_missing_and_ambiguous_syntax() {
        for text in [
            "include \"/tmp/outside.kdl\"",
            "include \"../outside.kdl\"",
            "include \"missing.kdl\"",
            "\"include\" \"/tmp/x\"",
            "include \"./nested/../nested/local.kdl\"",
            "include \"./nested/local.kdl\" extra",
            "include r#\"/tmp/x\"#",
            "foo /*\n*/ include \"/tmp/x\"",
        ] {
            assert!(check(&profile(text)).is_err(), "{text}");
        }
    }

    #[test]
    fn rejects_unhandled_kdl_newlines_even_in_comments() {
        for newline in ["\r", "\u{000c}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            for prefix in ["screenshot-path \"foo\"", "// comment"] {
                let config = format!("{prefix}{newline}include \"/tmp/outside.kdl\"\n");
                assert!(check(&profile(&config)).is_err(), "{newline:?}, {prefix}");
            }
        }
        assert!(check(&profile("// comment\r\ninclude \"./nested/local.kdl\"\r\n")).is_ok());
    }

    #[test]
    fn managed_fragment_must_be_reachable_once_without_cycles() {
        let target = Path::new("nested/local.kdl");
        let mut files = profile("include \"./nested/local.kdl\"\n");
        assert!(require_single_reachable(&files, target).is_ok());
        files.insert(PathBuf::from("config.kdl"), b"// no include\n".to_vec());
        assert!(require_single_reachable(&files, target).is_err());
        files.insert(
            PathBuf::from("config.kdl"),
            b"include \"./nested/local.kdl\"\ninclude \"./nested/local.kdl\"\n".to_vec(),
        );
        assert!(require_single_reachable(&files, target).is_err());
        files.insert(
            PathBuf::from("config.kdl"),
            b"include \"./nested/local.kdl\"\n".to_vec(),
        );
        files.insert(
            PathBuf::from("nested/local.kdl"),
            b"include \"./local.kdl\"\n".to_vec(),
        );
        assert!(require_single_reachable(&files, target).is_err());
        files.insert(
            PathBuf::from("nested/local.kdl"),
            b"// include \"./local.kdl\"\n".to_vec(),
        );
        assert!(require_single_reachable(&files, target).is_ok());
        files.insert(
            PathBuf::from("config.kdl"),
            b"input { include \"./nested/local.kdl\"; }\n".to_vec(),
        );
        assert!(require_single_reachable(&files, target).is_err());
    }
}
