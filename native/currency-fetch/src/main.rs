use serde_json::{json, Map, Value};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const LIMIT: u64 = 256 * 1024;
const API: &str = "https://api.frankfurter.dev/v2/";

fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64 }
fn number(v: &Value) -> bool { v.as_f64().is_some_and(|n| n.is_finite() && n > 0.0 && n < 1e15) }
fn code(s: &str) -> bool { s.len() == 3 && s.bytes().all(|b| b.is_ascii_uppercase()) }

fn valid_date(s: &str, now_ms: i64) -> bool {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' || !b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit()) { return false; }
    let y: i32 = s[0..4].parse().unwrap_or(0);
    let m: usize = s[5..7].parse().unwrap_or(0);
    let d: u32 = s[8..10].parse().unwrap_or(0);
    if y < 1990 || !(1..=12).contains(&m) { return false; }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days = [31, if leap {29} else {28}, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if d == 0 || d > days[m-1] { return false; }
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = y - 1900; tm.tm_mon = m as i32 - 1; tm.tm_mday = d as i32;
    let seconds = unsafe { libc::timegm(&mut tm) };
    seconds >= 0 && seconds / 86400 <= now_ms / 86400000 + 1
}

fn validate(v: &Value, now_ms: i64) -> Result<Value, String> {
    let bad = || "Invalid currency snapshot".to_string();
    if v["version"].as_u64() != Some(1) || v["provider"] != "frankfurter-v2" || !number(&v["fetchedAt"]) || v["fetchedAt"].as_f64().unwrap() > (now_ms + 60000) as f64 { return Err(bad()); }
    let rates = v["rates"].as_object().ok_or_else(bad)?;
    let dates = v["dates"].as_object().ok_or_else(bad)?;
    let names = v["names"].as_object().ok_or_else(bad)?;
    if !(2..=300).contains(&rates.len()) || rates.get("USD").and_then(Value::as_f64) != Some(1.0) { return Err(bad()); }
    let mut selected_dates = Map::new(); let mut selected_names = Map::new();
    for (key, rate) in rates {
        let date = dates.get(key).and_then(Value::as_str).ok_or_else(bad)?;
        let name = names.get(key).and_then(Value::as_str).ok_or_else(bad)?;
        if !code(key) || !number(rate) || !valid_date(date, now_ms) || name.is_empty() || name.chars().count() > 100 || name.chars().any(|c| c < ' ' || "<>&".contains(c)) { return Err(bad()); }
        selected_dates.insert(key.clone(), json!(date)); selected_names.insert(key.clone(), json!(name));
    }
    Ok(json!({"version":1,"provider":"frankfurter-v2","fetchedAt":v["fetchedAt"],"rates":rates,"dates":selected_dates,"names":selected_names}))
}

fn snapshot(currencies: &Value, rows: &Value, now_ms: i64) -> Result<Value, String> {
    let bad = || "Invalid provider response".to_string();
    let currencies = currencies.as_array().ok_or_else(bad)?; let rows = rows.as_array().ok_or_else(bad)?;
    if !(2..=300).contains(&currencies.len()) || !(2..=300).contains(&rows.len()) { return Err(bad()); }
    let mut names = Map::new(); let mut rates = Map::new(); let mut dates = Map::new();
    for item in currencies { let c = item["iso_code"].as_str().ok_or_else(bad)?; if !code(c) || names.insert(c.into(), item["name"].clone()).is_some() { return Err(bad()); } }
    for item in rows { let c = item["quote"].as_str().ok_or_else(bad)?; if item["base"] != "USD" || !names.contains_key(c) || rates.insert(c.into(), item["rate"].clone()).is_some() { return Err(bad()); } dates.insert(c.into(), item["date"].clone()); }
    if rates.len() != names.len() { return Err(bad()); }
    validate(&json!({"version":1,"provider":"frankfurter-v2","fetchedAt":now_ms,"rates":rates,"dates":dates,"names":names}), now_ms)
}

fn load(path: &Path, now_ms: i64) -> Option<Value> {
    let mut bytes = Vec::new(); fs::File::open(path).ok()?.take(LIMIT + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > LIMIT { return None; }
    validate(&serde_json::from_slice::<Value>(&bytes).ok()?, now_ms).ok()
}

fn save(path: &Path, value: &Value) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    let mut stage = None;
    for i in 0..100 {
        let candidate = parent.join(format!(".currency-{}-{}", std::process::id(), i));
        match OpenOptions::new().write(true).create_new(true).mode(0o600).open(&candidate) {
            Ok(file) => { stage = Some((candidate, file)); break; },
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    let (tmp, mut file) = stage.ok_or_else(|| std::io::Error::new(std::io::ErrorKind::AlreadyExists, "no temporary filename available"))?;
    let result = (|| { serde_json::to_writer(&mut file, value)?; file.flush()?; file.sync_all()?; fs::rename(&tmp, path) })();
    if result.is_err() { let _ = fs::remove_file(tmp); }
    result
}

fn fetch(client: &reqwest::blocking::Client, url: &str) -> Result<Value, String> {
    let response = client.get(url).send().map_err(|e| e.to_string())?.error_for_status().map_err(|e| e.to_string())?;
    let mut bytes = Vec::new(); response.take(LIMIT + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.len() as u64 > LIMIT { return Err("Response too large".into()); }
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

fn emit(epoch: i64, mut value: Value) { value["epoch"] = json!(epoch); println!("{value}"); let _ = std::io::stdout().flush(); }

fn run(epoch: i64, refresh: bool, path: &Path, api: &str) {
    let now_ms = now(); let cached = load(path, now_ms);
    if let Some(ref value) = cached {
        emit(epoch, json!({"type":"cache","snapshot":value}));
        let age = now_ms as f64 - value["fetchedAt"].as_f64().unwrap();
        if !refresh && (0.0..3600000.0).contains(&age) { emit(epoch, json!({"type":"result","success":true,"cached":true,"snapshot":value})); return; }
    }
    let result = (|| {
        let client = reqwest::blocking::Client::builder().timeout(Duration::from_secs(8)).user_agent("MacShell-Calculator/1.0").build().map_err(|e| e.to_string())?;
        let currencies = fetch(&client, &format!("{api}currencies"))?;
        let rows = fetch(&client, &format!("{api}rates?base=USD"))?;
        let value = snapshot(&currencies, &rows, now())?;
        if let Some(old) = &cached { for (key, date) in value["dates"].as_object().unwrap() { if old["dates"].get(key).and_then(Value::as_str).is_some_and(|old_date| date.as_str().unwrap() < old_date) { return Err("Provider returned older rates".into()); } } }
        Ok::<_, String>(value)
    })();
    match result {
        Ok(value) => { let warning = if save(path, &value).is_err() { "Rates loaded, but the offline cache could not be saved." } else { "" }; emit(epoch, json!({"type":"result","success":true,"cached":false,"snapshot":value,"warning":warning})); },
        Err(_) => emit(epoch, json!({"type":"result","success":false,"error":"Could not update exchange rates. Check your connection."})),
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let first = args.next().unwrap_or_default();
    if first == "--protocol-version" { println!("macshell-currency-fetch 1"); return; }
    let epoch: i64 = match first.parse() { Ok(n) => n, Err(_) => { eprintln!("Expected epoch"); std::process::exit(2) } };
    let base = std::env::var_os("XDG_CACHE_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".cache"));
    let mut path = base.join("macshell-niri/currency-rates.json"); let mut refresh = false;
    while let Some(arg) = args.next() { match arg.as_str() { "--refresh" => refresh = true, "--cache" => if let Some(p) = args.next() { path = p.into(); } else { std::process::exit(2) }, _ => std::process::exit(2) } }
    let api = option_env!("MACSHELL_CURRENCY_TEST_API").unwrap_or(API);
    run(epoch, refresh, &path, api);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data() -> (Value, Value) {
        (json!([{"iso_code":"USD","name":"US Dollar"},{"iso_code":"EUR","name":"Euro"}]),
         json!([{"base":"USD","quote":"USD","rate":1,"date":"2026-01-01"},{"base":"USD","quote":"EUR","rate":0.8,"date":"2026-01-01"}]))
    }

    #[test]
    fn rejects_invalid_and_future_dates() {
        let time = 1767225600000;
        for date in ["2026-02-30", "2026-01-03", "1989-12-31", "2026-1-01"] { assert!(!valid_date(date, time), "{date}"); }
        assert!(valid_date("2026-01-02", time));
        assert!(valid_date("2024-02-29", time));
        assert!(!valid_date("2025-02-29", time));
    }

    #[test]
    fn rejects_bad_provider_data_and_invalid_cache() {
        let (names, rows) = data(); let time = 1767225600000;
        let valid = snapshot(&names, &rows, time).unwrap();
        assert!(validate(&valid, time).is_ok());
        for (key, value) in [("version", json!(true)), ("fetchedAt", json!(time + 120000)), ("provider", json!("wrong"))] {
            let mut v = valid.clone(); v[key] = value; assert!(validate(&v, time).is_err());
        }
        for value in [json!(0), json!(-1), json!(true), json!(1e15)] {
            let mut r = rows.clone(); r[1]["rate"] = value; assert!(snapshot(&names, &r, time).is_err());
        }
        let mut r = rows.clone(); r[1]["quote"] = json!("USD"); assert!(snapshot(&names, &r, time).is_err());
        let mut n = names.clone(); n[1]["name"] = json!("<bad>"); assert!(snapshot(&n, &rows, time).is_err());
    }
}
