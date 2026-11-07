//! Synthetic graph compatibility harness; no PipeWire connection.
use macshell_recording_core::audio::{link_state, parse_graph, State};
use serde_json::Value;
use std::io::{self, BufRead};

fn main() {
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let result = (|| {
            let input: Value = serde_json::from_str(&line).ok()?;
            let pid = u32::try_from(input["pid"].as_u64()?).ok()?;
            let target = input["target"].as_str()?;
            let routes = input["routes"]
                .as_array()?
                .iter()
                .map(|route| {
                    let r = route.as_array()?;
                    if r.len() != 4 {
                        return None;
                    }
                    Some([
                        r[0].as_str()?,
                        r[1].as_str()?,
                        r[2].as_str()?,
                        r[3].as_str()?,
                    ])
                })
                .collect::<Option<Vec<_>>>()?;
            let (nodes, links) = parse_graph(&input["objects"]).ok()?;
            Some(match link_state(&nodes, &links, pid, target, &routes) {
                State::Ready => "ready",
                State::Waiting => "waiting",
                State::Wrong => "wrong",
            })
        })();
        println!("{}", result.unwrap_or("error"));
    }
}
