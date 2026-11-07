//! Test-only JSON-lines adapter for comparing pure decisions with Python.
use macshell_network_core::{choose_profile, security, validate_password, Profile};
use serde_json::{json, Value};
use std::io::{self, BufRead};

fn main() {
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let input: Value = serde_json::from_str(&line).expect("test request");
        let result = match input["action"].as_str().unwrap() {
            "new-profile" => {
                let ssid: Vec<u8> = input["ssid"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_u64().unwrap() as u8)
                    .collect();
                let input = macshell_network_core::new_profile::Input {
                    ssid: &ssid,
                    interface: input["interface"].as_str().unwrap(),
                    username: input["username"].as_str().unwrap(),
                    security: input["kind"].as_str().unwrap(),
                    uuid: input["uuid"].as_str().unwrap(),
                    password: input["password"].as_str().unwrap(),
                };
                match macshell_network_core::new_profile::prepare(input) {
                    Ok(plan) => {
                        json!({"ssid":plan.ssid, "display":plan.display_name, "interface":plan.interface,
                        "permission":plan.permission, "uuid":plan.uuid, "security":format!("{:?}",plan.security)})
                    }
                    Err(error) => json!({"error":error}),
                }
            }
            "security" => json!(security(
                input["flags"].as_u64().unwrap() as u32,
                input["wpa"].as_u64().unwrap() as u32,
                input["rsn"].as_u64().unwrap() as u32
            )),
            "password" => match validate_password(
                input["kind"].as_str().unwrap(),
                input["password"].as_str().unwrap(),
            ) {
                Ok(()) => json!(null),
                Err(error) => json!(error),
            },
            "profile" => {
                let rows = input["profiles"].as_array().unwrap();
                let bytes: Vec<Vec<u8>> = rows
                    .iter()
                    .map(|p| {
                        p["ssid"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|n| n.as_u64().unwrap() as u8)
                            .collect()
                    })
                    .collect();
                let profiles: Vec<Profile<'_>> = rows
                    .iter()
                    .zip(&bytes)
                    .map(|(p, ssid)| Profile {
                        path: p["path"].as_str().unwrap(),
                        ssid,
                        key_management: p["key"].as_str().unwrap(),
                        interface: p["interface"].as_str(),
                        timestamp: p["timestamp"].as_u64().unwrap(),
                        uuid: p["uuid"].as_str().unwrap(),
                    })
                    .collect();
                let ssid: Vec<u8> = input["ssid"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_u64().unwrap() as u8)
                    .collect();
                json!(choose_profile(
                    &profiles,
                    &ssid,
                    input["key"].as_str().unwrap(),
                    input["interface"].as_str().unwrap(),
                    input["active"].as_str().unwrap()
                )
                .unwrap_or(""))
            }
            _ => panic!("unknown test action"),
        };
        println!("{result}");
    }
}
