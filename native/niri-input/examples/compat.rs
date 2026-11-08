use serde_json::{json, Value};
use std::io::{self, BufRead};

fn main() {
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let result = (|| -> Result<String, String> {
            let request: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
            match request["action"].as_str() {
                Some("config") => macshell_niri_input::input_config(&request["values"]),
                Some("strip") => macshell_niri_input::without_input_preferences(
                    request["text"].as_str().ok_or("missing text")?,
                ),
                Some("plan") => {
                    use std::{
                        collections::BTreeMap,
                        path::{Path, PathBuf},
                    };
                    let files = BTreeMap::from([
                        (PathBuf::from("config.kdl"), b"// config\n".to_vec()),
                        (
                            PathBuf::from("input.kdl"),
                            request["text"]
                                .as_str()
                                .ok_or("missing text")?
                                .as_bytes()
                                .to_vec(),
                        ),
                    ]);
                    macshell_niri_input::plan_profile(
                        files,
                        Path::new("input.kdl"),
                        &request["values"],
                    )?;
                    Ok("accepted".into())
                }
                _ => Err("unknown action".into()),
            }
        })();
        println!(
            "{}",
            match result {
                Ok(value) => json!({"value": value}),
                Err(error) => json!({"error": error}),
            }
        );
    }
}
