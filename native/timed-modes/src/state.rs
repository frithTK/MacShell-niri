use serde_json::{json, Value};

pub fn until_evening(now: f64) -> Result<f64, &'static str> {
    if !now.is_finite() || now < libc::time_t::MIN as f64 || now > libc::time_t::MAX as f64 {
        return Err("Invalid local time");
    }
    let timestamp = now.floor() as libc::time_t;
    let mut local = std::mem::MaybeUninit::<libc::tm>::uninit();
    if unsafe { libc::localtime_r(&timestamp, local.as_mut_ptr()) }.is_null() {
        return Err("Local time unavailable");
    }
    let mut local = unsafe { local.assume_init() };
    if local.tm_hour >= 20 {
        local.tm_mday += 1;
    }
    local.tm_hour = 20;
    local.tm_min = 0;
    local.tm_sec = 0;
    local.tm_isdst = -1;
    let target = unsafe { libc::mktime(&mut local) };
    if target == -1 {
        return Err("Local deadline unavailable");
    }
    Ok(target as f64)
}

pub fn create(
    mode: &str,
    now: f64,
    boot_time: f64,
    boot: &str,
    session: &str,
) -> Result<Value, &'static str> {
    let mut result = json!({"mode": mode, "boot": boot, "session": session});
    match mode {
        "15" | "30" | "60" => {
            let duration = mode.parse::<f64>().unwrap() * 60.;
            result["utc"] = json!(now + duration);
            result["deadline"] = json!(boot_time + duration);
        }
        "evening" => result["utc"] = json!(until_evening(now)?),
        "off" | "manual" => {}
        _ => return Err("Invalid duration"),
    }
    Ok(result)
}

fn number(value: &Value, key: &str) -> Option<f64> {
    value.get(key)?.as_f64().filter(|value| value.is_finite())
}

pub fn remaining(value: &Value, now: f64, boot_time: f64, boot: &str) -> Option<f64> {
    match value.get("mode").and_then(Value::as_str) {
        Some("off") => Some(0.),
        Some("manual") => None,
        Some(mode) => {
            let left =
                if mode != "evening" && value.get("boot").and_then(Value::as_str) == Some(boot) {
                    number(value, "deadline").unwrap_or(0.) - boot_time
                } else {
                    number(value, "utc").unwrap_or(0.) - now
                };
            Some(left.max(0.))
        }
        None => Some(0.),
    }
}

pub fn restore(
    value: &Value,
    kind: &str,
    now: f64,
    boot_time: f64,
    boot: &str,
    session: &str,
) -> Value {
    let off = || create("off", now, boot_time, boot, session).unwrap();
    let Some(mode) = value.get("mode").and_then(Value::as_str) else {
        return off();
    };
    if !value.is_object() || !matches!(mode, "off" | "manual" | "15" | "30" | "60" | "evening") {
        return off();
    }
    if !matches!(mode, "off" | "manual")
        && (number(value, "utc").is_none()
            || (mode != "evening"
                && value.get("boot").and_then(Value::as_str) == Some(boot)
                && number(value, "deadline").is_none()))
    {
        return off();
    }
    if kind == "awake"
        && (session.is_empty()
            || value.get("session").and_then(Value::as_str) != Some(session)
            || value.get("boot").and_then(Value::as_str) != Some(boot))
    {
        return off();
    }
    let left = remaining(value, now, boot_time, boot);
    if left == Some(0.) {
        return off();
    }
    let mut result = value.clone();
    if let Some(left) = left {
        if mode != "evening" && value.get("boot").and_then(Value::as_str) != Some(boot) {
            result["deadline"] = json!(boot_time + left);
        }
    }
    result["boot"] = json!(boot);
    result["session"] = json!(session);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_uses_boottime_and_reseeds_after_reboot() {
        let value = create("60", 1000., 100., "boot", "session").unwrap();
        assert_eq!(remaining(&value, 99999999., 160., "boot"), Some(3540.));
        assert_eq!(remaining(&value, -999999., 3701., "boot"), Some(0.));
        let restored = restore(&value, "focus", 2000., 10., "boot2", "session2");
        assert_eq!(remaining(&restored, 2000., 10., "boot2"), Some(2600.));
        assert_eq!(
            restore(&value, "focus", 5000., 10., "boot2", "session2")["mode"],
            "off"
        );
    }

    #[test]
    fn awake_only_restores_for_the_same_confirmed_session() {
        let value = create("manual", 1000., 100., "boot", "session").unwrap();
        for (boot, session) in [("boot", ""), ("boot", "other"), ("other", "session")] {
            assert_eq!(
                restore(&value, "awake", 1000., 100., boot, session)["mode"],
                "off"
            );
        }
        assert_eq!(
            restore(&value, "awake", 1000., 100., "boot", "session")["mode"],
            "manual"
        );
        assert_eq!(
            restore(
                &json!({"mode":"manual"}),
                "awake",
                1000.,
                100.,
                "boot",
                "session"
            )["mode"],
            "off"
        );
    }

    #[test]
    fn rejects_invalid_deadlines_and_preserves_unknown_fields() {
        for value in [
            Value::Null,
            json!({}),
            json!({"mode":"garbage"}),
            json!({"mode":"60", "boot":"b", "utc":"oops", "deadline":99}),
            json!({"mode":"evening"}),
        ] {
            assert_eq!(restore(&value, "focus", 1., 1., "b", "s")["mode"], "off");
        }
        let value =
            json!({"mode":"60", "boot":"old", "session":"old", "utc":1000, "future":{"x":true}});
        assert_eq!(
            restore(&value, "focus", 1., 1., "b", "s")["future"]["x"],
            true
        );
    }

    #[test]
    fn local_evening_handles_spring_and_autumn_dst() {
        unsafe extern "C" {
            fn tzset();
        }
        let previous = std::env::var_os("TZ");
        std::env::set_var("TZ", "Europe/Berlin");
        unsafe {
            tzset();
        }
        let spring = until_evening(1774724400.).unwrap();
        let autumn = until_evening(1792864800.).unwrap();
        if let Some(value) = previous {
            std::env::set_var("TZ", value);
        } else {
            std::env::remove_var("TZ");
        }
        unsafe {
            tzset();
        }
        assert_eq!(spring, 1774807200.);
        assert_eq!(autumn, 1792954800.);
    }
}
