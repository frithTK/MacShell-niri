use serde_json::{json, Value};
use std::io::{Read, Write};
use std::time::Duration;

const LIMIT: u64 = 1024 * 1024;

struct Endpoints {
    geocode: String,
    location: String,
    fallback: String,
    forecast: String,
    lyrics_get: String,
    lyrics_search: String,
}

impl Endpoints {
    fn production() -> Self {
        if let Some(base) = option_env!("MACSHELL_WIDGET_TEST_API") {
            return Self { geocode: format!("{base}geocode"), location: format!("{base}location"), fallback: format!("{base}fallback"), forecast: format!("{base}forecast"), lyrics_get: format!("{base}get"), lyrics_search: format!("{base}search") };
        }
        Self { geocode: "https://geocoding-api.open-meteo.com/v1/search".into(), location: "https://ipwho.is/".into(), fallback: "https://ipapi.co/json/".into(), forecast: "https://api.open-meteo.com/v1/forecast".into(), lyrics_get: "https://lrclib.net/api/get".into(), lyrics_search: "https://lrclib.net/api/search".into() }
    }
}

fn fetch(client: &reqwest::blocking::Client, url: &str, query: &[(&str, &str)]) -> Result<Value, String> {
    let response = client.get(url).query(query).header("Accept", "application/json").send().map_err(|e| e.to_string())?.error_for_status().map_err(|e| e.to_string())?;
    let mut data = Vec::new();
    response.take(LIMIT + 1).read_to_end(&mut data).map_err(|e| e.to_string())?;
    if data.len() as u64 > LIMIT { return Err("Response too large".into()); }
    serde_json::from_slice(&data).map_err(|e| e.to_string())
}

fn coordinates(location: &Value) -> Result<(f64, f64), String> {
    fn parse(v: &Value) -> Option<f64> { v.as_f64().or_else(|| v.as_str()?.parse().ok()) }
    let lat = parse(&location["latitude"]).ok_or("Invalid coordinates")?;
    let lon = parse(&location["longitude"]).ok_or("Invalid coordinates")?;
    if !lat.is_finite() || !lon.is_finite() || !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) { return Err("Invalid coordinates".into()); }
    Ok((lat, lon))
}

fn weather(client: &reqwest::blocking::Client, endpoints: &Endpoints, mode: &str, city: &str, unit: &str) -> Result<Value, String> {
    let located = mode != "city" || city.trim().is_empty();
    let location = if located {
        match fetch(client, &endpoints.location, &[]).and_then(|v| { coordinates(&v)?; Ok(v) }) {
            Ok(v) => v,
            Err(_) => fetch(client, &endpoints.fallback, &[])?,
        }
    } else {
        let data = fetch(client, &endpoints.geocode, &[("name", city.trim()), ("count", "1"), ("language", "en"), ("format", "json")])?;
        data["results"].as_array().and_then(|v| v.first()).cloned().ok_or("Location not found")?
    };
    let (lat, lon) = coordinates(&location)?;
    let place = if located { ["city", "region", "country"].iter().filter_map(|key| location[*key].as_str()).find(|v| !v.is_empty()).unwrap_or("Current Location") } else { location["name"].as_str().ok_or("Missing location name")? };
    let latitude = lat.to_string(); let longitude = lon.to_string();
    let forecast = fetch(client, &endpoints.forecast, &[("latitude", &latitude), ("longitude", &longitude), ("current", "temperature_2m,weather_code,is_day"), ("hourly", "temperature_2m,weather_code,is_day"), ("daily", "temperature_2m_max,temperature_2m_min,weather_code"), ("temperature_unit", if unit == "F" { "fahrenheit" } else { "celsius" }), ("timezone", "auto"), ("forecast_days", "6")])?;
    Ok(json!({"forecast":forecast,"latitude":lat,"longitude":lon,"place":place,"located":located}))
}

fn lyrics(client: &reqwest::blocking::Client, endpoints: &Endpoints, title: &str, artist: &str, album: &str, duration: &str) -> Result<Value, String> {
    fetch(client, &endpoints.lyrics_get, &[("track_name", title), ("artist_name", artist), ("album_name", album), ("duration", duration)])
        .or_else(|_| fetch(client, &endpoints.lyrics_search, &[("q", &format!("{artist} {title}"))]))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|v| v == "--protocol-version") { println!("macshell-widget-fetch 1"); return; }
    let epoch = args.get(1).and_then(|v| v.parse::<i64>().ok());
    let Some(epoch) = epoch else { eprintln!("Expected request kind and epoch"); std::process::exit(2); };
    let kind = args.first().map(String::as_str).unwrap_or("");
    let result = reqwest::blocking::Client::builder().timeout(Duration::from_secs(8)).user_agent("macshell-widgets (quickshell)").build().map_err(|e| e.to_string()).and_then(|client| {
        let endpoints = Endpoints::production();
        match (kind, args.len()) {
            ("weather", 5) => weather(&client, &endpoints, &args[2], &args[3], &args[4]),
            ("lyrics", 6) => lyrics(&client, &endpoints, &args[2], &args[3], &args[4], &args[5]),
            _ => Err("Invalid request".into()),
        }
    });
    let message = match result { Ok(value) => json!({"epoch":epoch,"success":true,"result":value}), Err(_) => json!({"epoch":epoch,"success":false,"error":if kind == "weather" {"Weather unavailable."} else {"Lyrics unavailable."}}) };
    println!("{message}"); let _ = std::io::stdout().flush();
}
