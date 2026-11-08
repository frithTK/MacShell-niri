//! Conservative recognition of complete fragments produced by MacShell.
//! A generated-looking header alone is not evidence that no edits were added.

const INITIAL: &str = "// Input preferences remain unchanged until edited in MacShell.\n";

pub(crate) fn is_untouched(text: &str) -> bool {
    if text == INITIAL {
        return true;
    }
    parse_generated(text)
        .is_some_and(|values| crate::input_config(&values).is_ok_and(|generated| generated == text))
}

fn take<'a>(rest: &mut &'a str, prefix: &str, separator: &str) -> Option<&'a str> {
    *rest = rest.strip_prefix(prefix)?;
    let (value, tail) = rest.split_once(separator)?;
    *rest = tail;
    Some(value)
}

fn parse_generated(mut rest: &str) -> Option<serde_json::Value> {
    let rate: f64 = take(&mut rest, "// Generated only when input preferences change in MacShell.\ninput {\n    keyboard { repeat-rate ", "; repeat-delay ")?.parse().ok()?;
    let delay: f64 = take(&mut rest, "", "; }\n    mouse { accel-speed ")?
        .parse()
        .ok()?;
    let mouse: f64 = take(&mut rest, "", "; ")?.parse().ok()?;
    let mouse_natural = take(&mut rest, "", " }\n    touchpad {\n        ")?;
    let touch_natural = take(&mut rest, "", "\n        ")?;
    let tap = take(&mut rest, "", "\n        ")?;
    let dwt = take(&mut rest, "", "\n        scroll-factor ")?;
    let scroll: f64 = take(&mut rest, "", "\n    }\n}\n")?.parse().ok()?;
    if !rest.is_empty() {
        return None;
    }
    fn flag(value: &str, name: &str) -> Option<bool> {
        if value.is_empty() {
            Some(false)
        } else if value == name {
            Some(true)
        } else {
            None
        }
    }
    Some(serde_json::json!({
        "repeatRate": rate, "repeatDelay": delay, "mouseSens": mouse, "tpScroll": scroll,
        "mouseNatural": flag(mouse_natural, "natural-scroll;")?,
        "tpNatural": flag(touch_natural, "natural-scroll;")?,
        "tpTap": flag(tap, "tap;")?, "tpDwt": flag(dwt, "dwt;")?,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recognizes_only_exact_generated_fragments() {
        assert!(is_untouched(INITIAL));
        for flags in 0..16 {
            for mouse in [-1.0, -0.0, 0.0, 1.0] {
                let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":mouse,"tpScroll":0.7,"mouseNatural":flags & 1 != 0,"tpNatural":flags & 2 != 0,"tpTap":flags & 4 != 0,"tpDwt":flags & 8 != 0});
                let generated = crate::input_config(&values).unwrap();
                assert!(is_untouched(&generated), "{generated}");
                assert!(!is_untouched(&(generated.clone() + "// custom\n")));
                assert!(!is_untouched(
                    &generated.replace("input {", "input { // custom")
                ));
            }
        }
        assert!(!is_untouched(
            "// Input preferences remain unchanged until edited in MacShell.\n// custom\n"
        ));
    }
}
