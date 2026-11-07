//! Decisions over a synthetic or already-read PipeWire graph.
//! This module does not connect to PipeWire or start a recorder.
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub id: u32,
    pub name: String,
    /// Effective process id of the node or its owning PipeWire client.
    pub process_id: Option<u32>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub output: u32,
    pub input: u32,
    pub active: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Ready,
    Waiting,
    Wrong,
}

/// Decode the relevant portion of `pw-dump`. Refuse malformed graphs rather
/// than report a safe connection from incomplete or ambiguous data.
pub fn parse_graph(value: &Value) -> Result<(Vec<Node>, Vec<Link>), &'static str> {
    let objects = value.as_array().ok_or("Invalid PipeWire graph")?;
    if objects.len() > 100_000 {
        return Err("PipeWire graph is too large");
    }
    let mut clients = HashMap::new();
    let mut seen = HashSet::new();
    for object in objects {
        let id = object
            .get("id")
            .and_then(Value::as_u64)
            .and_then(|id| u32::try_from(id).ok())
            .ok_or("Invalid PipeWire object")?;
        if !seen.insert(id) {
            return Err("Duplicate PipeWire object");
        }
        clients.insert(id, &object["info"]["props"]);
    }
    fn number(v: &Value) -> Option<u32> {
        v.as_u64()
            .and_then(|v| u32::try_from(v).ok())
            .or_else(|| v.as_str().and_then(|v| v.parse().ok()))
    }
    let mut nodes = Vec::new();
    let mut links = Vec::new();
    for object in objects {
        let kind = object.get("type").and_then(Value::as_str).unwrap_or("");
        let id = object["id"]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or("Invalid PipeWire object")?;
        if kind.ends_with(":Node") {
            let props = &object["info"]["props"];
            let name = props.get("node.name").and_then(Value::as_str).unwrap_or("");
            let process = match props.get("application.process.id") {
                Some(pid) => number(pid),
                None => number(&props["client.id"])
                    .and_then(|id| clients.get(&id))
                    .and_then(|v| number(&v["application.process.id"])),
            };
            nodes.push(Node {
                id,
                name: name.to_owned(),
                process_id: process,
            });
        } else if kind.ends_with(":Link") {
            let info = &object["info"];
            let output = number(&info["output-node-id"]).ok_or("Invalid PipeWire link")?;
            let input = number(&info["input-node-id"]).ok_or("Invalid PipeWire link")?;
            links.push(Link {
                output,
                input,
                active: info["state"].as_str() == Some("active"),
            });
        }
    }
    Ok((nodes, links))
}

/// Check only links attached to the recorder process owned by this recording.
/// `routes` lists source/capture/playback/sink node names for loopback mixes.
/// A connection to the wrong source always takes precedence over waiting.
pub fn link_state(
    nodes: &[Node],
    links: &[Link],
    recorder_pid: u32,
    target: &str,
    routes: &[[&str; 4]],
) -> State {
    let targets: HashSet<_> = nodes
        .iter()
        .filter(|n| n.name == target)
        .map(|n| n.id)
        .collect();
    let recorders: HashSet<_> = nodes
        .iter()
        .filter(|n| {
            matches!(n.name.as_str(), "wf-recorder" | "wf-recorder3")
                && n.process_id == Some(recorder_pid)
        })
        .map(|n| n.id)
        .collect();
    let attached: Vec<_> = links
        .iter()
        .filter(|link| recorders.contains(&link.input))
        .collect();
    if attached.iter().any(|link| !targets.contains(&link.output)) {
        return State::Wrong;
    }
    if attached.is_empty() || attached.iter().any(|link| !link.active) {
        return State::Waiting;
    }
    let names: HashMap<_, _> = nodes
        .iter()
        .map(|node| (node.name.as_str(), node.id))
        .collect();
    for [source, capture, playback, sink] in routes {
        for (out, input) in [(*source, *capture), (*playback, *sink)] {
            let (Some(out), Some(input)) = (names.get(out), names.get(input)) else {
                return State::Waiting;
            };
            if !links
                .iter()
                .any(|link| link.output == *out && link.input == *input && link.active)
            {
                return State::Waiting;
            }
        }
    }
    State::Ready
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(id: u32, name: &str, pid: Option<u32>) -> Node {
        Node {
            id,
            name: name.into(),
            process_id: pid,
        }
    }
    fn link(output: u32, input: u32, active: bool) -> Link {
        Link {
            output,
            input,
            active,
        }
    }
    #[test]
    fn waits_for_this_process_and_rejects_wrong_source() {
        let nodes = vec![
            node(1, "selected", None),
            node(2, "other", None),
            node(3, "wf-recorder", Some(42)),
            node(4, "wf-recorder", Some(43)),
        ];
        assert_eq!(
            link_state(&nodes, &[link(1, 4, true)], 42, "selected", &[]),
            State::Waiting
        );
        assert_eq!(
            link_state(&nodes, &[link(1, 3, false)], 42, "selected", &[]),
            State::Waiting
        );
        assert_eq!(
            link_state(
                &nodes,
                &[link(1, 3, true), link(2, 3, false)],
                42,
                "selected",
                &[]
            ),
            State::Wrong
        );
        assert_eq!(
            link_state(
                &nodes,
                &[link(1, 3, true), link(2, 4, true)],
                42,
                "selected",
                &[]
            ),
            State::Ready
        );
    }
    #[test]
    fn mixed_audio_requires_both_loopback_routes() {
        let nodes = vec![
            node(1, "mix", None),
            node(2, "wf-recorder3", Some(42)),
            node(3, "source", None),
            node(4, "capture", None),
            node(5, "playback", None),
        ];
        let route = [["source", "capture", "playback", "mix"]];
        let mut links = vec![link(1, 2, true), link(3, 4, true)];
        assert_eq!(
            link_state(&nodes, &links, 42, "mix", &route),
            State::Waiting
        );
        links.push(link(5, 1, true));
        assert_eq!(link_state(&nodes, &links, 42, "mix", &route), State::Ready);
    }
    #[test]
    fn decode_client_process_and_invalid_graphs() {
        let graph = serde_json::json!([
            {"id": 20, "type":"PipeWire:Interface:Client", "info":{"props":{"application.process.id":"1234"}}},
            {"id": 21, "type":"PipeWire:Interface:Node", "info":{"props":{"node.name":"wf-recorder", "client.id":20}}},
            {"id": 22, "type":"PipeWire:Interface:Node", "info":{"props":{"node.name":"mic"}}},
            {"id": 23, "type":"PipeWire:Interface:Link", "info":{"output-node-id":22,"input-node-id":21,"state":"active"}}
        ]);
        let (nodes, links) = parse_graph(&graph).unwrap();
        assert_eq!(link_state(&nodes, &links, 1234, "mic", &[]), State::Ready);
        assert!(parse_graph(&serde_json::json!([{"id":1}, {"id":1}])).is_err());
        assert!(parse_graph(&serde_json::json!([{"id":1,"type":"x:Link","info":{}}])).is_err());
    }
}
