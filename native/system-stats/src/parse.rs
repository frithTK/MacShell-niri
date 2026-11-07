use std::collections::BTreeMap;

pub type Counters = BTreeMap<String, (u64, u64)>;

pub fn cpus(text: &str) -> Counters {
    let mut result = Counters::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let Some(name) = parts.next() else { continue };
        let Some(suffix) = name.strip_prefix("cpu") else {
            continue;
        };
        if !suffix.bytes().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let values: Option<Vec<u64>> = parts.take(8).map(|n| n.parse().ok()).collect();
        if let Some(values) = values {
            if values.len() >= 4 {
                result.insert(
                    name.into(),
                    (values.iter().sum(), values[3] + values.get(4).unwrap_or(&0)),
                );
            }
        }
    }
    result
}

pub fn cpu_delta(before: Option<(u64, u64)>, after: (u64, u64)) -> Option<f64> {
    let (total, idle) = before?;
    if after.0 <= total || after.1 < idle {
        return None;
    }
    let total = (after.0 - total) as f64;
    let idle = (after.1 - idle) as f64;
    Some(((100.0 * (total - idle) / total).clamp(0.0, 100.0) * 10.0).round() / 10.0)
}

pub fn memory(text: &str) -> serde_json::Value {
    let mut values = BTreeMap::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        if let (Some(key), Some(value)) = (fields.next(), fields.next()) {
            if let Ok(value) = value.parse::<u64>() {
                values.insert(key.trim_end_matches(':'), value.saturating_mul(1024));
            }
        }
    }
    let get = |name| values.get(name).copied().unwrap_or(0u64);
    serde_json::json!({"total": get("MemTotal"), "used": get("MemTotal").saturating_sub(get("MemAvailable")),
        "swapTotal": get("SwapTotal"), "swapUsed": get("SwapTotal").saturating_sub(get("SwapFree"))})
}

pub fn networks(text: &str) -> Counters {
    let mut result = Counters::new();
    for line in text.lines().skip(2) {
        if let Some((name, data)) = line.split_once(':') {
            let fields: Vec<_> = data.split_whitespace().collect();
            if fields.len() >= 16 {
                if let (Ok(rx), Ok(tx)) = (fields[0].parse(), fields[8].parse()) {
                    result.insert(name.trim().into(), (rx, tx));
                }
            }
        }
    }
    result
}

pub fn disks(text: &str) -> Counters {
    let mut result = Counters::new();
    for line in text.lines() {
        let f: Vec<_> = line.split_whitespace().collect();
        if f.len() >= 14 {
            if let (Ok(read), Ok(write)) = (f[5].parse::<u64>(), f[9].parse::<u64>()) {
                result.insert(
                    f[2].into(),
                    (read.saturating_mul(512), write.saturating_mul(512)),
                );
            }
        }
    }
    result
}

pub fn rates(
    before: Option<(u64, u64)>,
    after: Option<(u64, u64)>,
    elapsed: f64,
) -> Option<[f64; 2]> {
    let (before, after) = (before?, after?);
    if elapsed <= 0.0 || after.0 < before.0 || after.1 < before.1 {
        return None;
    }
    Some([
        (after.0 - before.0) as f64 / elapsed,
        (after.1 - before.1) as f64 / elapsed,
    ])
}

pub fn routes(route4: &str, route6: &str) -> Vec<(u64, String)> {
    let mut candidates = Vec::new();
    for line in route4.lines().skip(1) {
        let f: Vec<_> = line.split_whitespace().collect();
        if f.len() > 7 && f[1] == "00000000" && u32::from_str_radix(f[3], 16).unwrap_or(0) & 1 != 0
        {
            if let Ok(metric) = f[6].parse() {
                candidates.push((metric, f[0].into()));
            }
        }
    }
    for line in route6.lines() {
        let f: Vec<_> = line.split_whitespace().collect();
        if f.len() >= 10
            && f[0] == "00000000000000000000000000000000"
            && f[1] == "00"
            && u32::from_str_radix(f[8], 16).unwrap_or(0) & 1 != 0
        {
            if let Ok(metric) = u64::from_str_radix(f[5], 16) {
                candidates.push((metric, f[f.len() - 1].into()));
            }
        }
    }
    candidates.sort();
    candidates
}

fn unescape_mount(value: &str) -> String {
    let mut bytes = Vec::new();
    let source = value.as_bytes();
    let mut pos = 0;
    while pos < source.len() {
        if source[pos] == b'\\'
            && pos + 3 < source.len()
            && source[pos + 1] <= b'3'
            && source[pos + 1..pos + 4]
                .iter()
                .all(|c| (b'0'..=b'7').contains(c))
        {
            bytes.push(
                (source[pos + 1] - b'0') * 64
                    + (source[pos + 2] - b'0') * 8
                    + (source[pos + 3] - b'0'),
            );
            pos += 4;
        } else {
            bytes.push(source[pos]);
            pos += 1;
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

pub fn root_mount(text: &str) -> Option<(String, String)> {
    let mut roots = Vec::new();
    for line in text.lines() {
        if let Some((left, right)) = line.split_once(" - ") {
            let before: Vec<_> = left.split_whitespace().collect();
            let after: Vec<_> = right.split_whitespace().collect();
            if before.len() >= 6 && before[4] == "/" && after.len() >= 2 {
                roots.push((after[0].to_string(), unescape_mount(after[1])));
            }
        }
    }
    if roots.len() == 1 {
        roots.pop()
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn counters_and_reset() {
        assert_eq!(cpus("cpu 10 2 3 40 5 6 7 8 100 100")["cpu"], (81, 45));
        assert_eq!(cpu_delta(Some((100, 30)), (200, 70)), Some(60.));
        assert_eq!(cpu_delta(Some((200, 30)), (100, 50)), None);
        assert_eq!(
            memory("MemTotal: 1000 kB\nMemAvailable: 400 kB")["used"],
            614400
        );
        assert_eq!(
            networks("h\nh\neth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0")["eth0"],
            (100, 200)
        );
        assert_eq!(
            disks("259 0 nvme0n1 0 0 10 0 0 0 20 0 0 0 0")["nvme0n1"],
            (5120, 10240)
        );
        assert_eq!(rates(Some((10, 20)), Some((30, 80)), 2.), Some([10., 30.]));
        assert_eq!(rates(Some((10, 20)), Some((0, 80)), 2.), None);
    }
    #[test]
    fn mount_and_routes_do_not_guess() {
        let line = "54 32 0:37 /@ / rw shared:1 - btrfs /dev/mapper/crypt\\040root rw";
        assert_eq!(
            root_mount(line),
            Some(("btrfs".into(), "/dev/mapper/crypt root".into()))
        );
        assert_eq!(root_mount(&format!("{line}\n{line}")), None);
        let route = format!(
            "{} 00 {} 00 {} 00000064 00000000 00000000 00000001 eth0",
            "0".repeat(32),
            "0".repeat(32),
            "0".repeat(32)
        );
        assert_eq!(routes("", &route), vec![(100, "eth0".into())]);
    }
}
