//! Open AirPlay receive ports for the current local network.
//!
//! A single phone address goes stale, and an IPv6-only exception still drops
//! IPv4. While UFW or firewalld is enforcing a default drop, enabling receive
//! allows TCP and UDP 7100–7102 from each real interface's own IPv4 prefix and
//! from IPv6 link-local (`fe80::/10`) on that interface. Rules are tagged
//! `MacShell AirPlay` so a later network can replace them. The privileged
//! apply path reads the live system itself and ignores helper environment
//! variables, so a caller cannot point it at a wider prefix than the machine
//! actually has.

use std::env;
use std::fs;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub const COMMENT: &str = "MacShell AirPlay";
const PORTS: &str = "7100:7102";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Backend {
    None,
    Ufw,
    Firewalld,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Cidr {
    addr: IpAddr,
    prefix: u8,
}

impl Cidr {
    fn parse(text: &str) -> Option<Self> {
        let (address, prefix) = match text.split_once('/') {
            Some((address, prefix)) => (address, prefix.parse::<u8>().ok()?),
            None => {
                let addr: IpAddr = text.parse().ok()?;
                let prefix = if addr.is_ipv4() { 32 } else { 128 };
                return Some(Self { addr, prefix });
            }
        };
        let addr: IpAddr = address.parse().ok()?;
        let max = if addr.is_ipv4() { 32 } else { 128 };
        (prefix <= max).then_some(Self { addr, prefix })
    }

    fn contains(&self, other: &Cidr) -> bool {
        if self.prefix > other.prefix || self.addr.is_ipv4() != other.addr.is_ipv4() {
            return false;
        }
        match (self.addr, other.addr) {
            (IpAddr::V4(left), IpAddr::V4(right)) => {
                let mask = v4_mask(self.prefix);
                (u32::from(left) & mask) == (u32::from(right) & mask)
            }
            (IpAddr::V6(left), IpAddr::V6(right)) => {
                let mask = v6_mask(self.prefix);
                (u128::from(left) & mask) == (u128::from(right) & mask)
            }
            _ => false,
        }
    }

    fn display(&self) -> String {
        format!("{}/{}", self.addr, self.prefix)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Opening {
    iface: String,
    source: Cidr,
}

#[derive(Clone, Debug)]
struct Rule {
    inbound: bool,
    iface: Option<String>,
    proto: String,
    ports_cover: bool,
    source: Option<Cidr>,
    accept: bool,
    comment: String,
}

struct View {
    backend: Backend,
    ip_json: String,
    ufw_v4: String,
    ufw_v6: String,
    firewalld_rules: String,
}

pub fn ensure() -> Result<(), String> {
    if !needs_apply(&read_view(true)) {
        return Ok(());
    }
    let exe = env::current_exe().map_err(|error| error.to_string())?;
    let pkexec = env::var_os("MACSHELL_PKEXEC")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("pkexec"));
    let output = Command::new(&pkexec)
        .arg(exe)
        .arg("--airplay-firewall")
        .stdin(Stdio::null())
        .output()
        .map_err(|_| "Authorization helper is not available.".to_string())?;
    if !output.status.success() {
        let text = String::from_utf8_lossy(&output.stderr);
        let text = text.trim();
        return Err(if text.is_empty() {
            "AirPlay receive needs ports 7100–7102 open to the local network. The firewall change was not authorized.".into()
        } else {
            format!(
                "AirPlay receive needs ports 7100–7102 open to the local network. {}",
                text.chars().take(180).collect::<String>()
            )
        });
    }
    if needs_apply(&read_view(true)) {
        return Err("The firewall still blocks AirPlay ports 7100–7102 from this network.".into());
    }
    Ok(())
}

/// Root-only entry. Recomputes the plan from the live system.
pub fn apply_system() -> Result<(), String> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("AirPlay firewall changes need an administrator.".into());
    }
    let view = read_view(false);
    match view.backend {
        Backend::None => Ok(()),
        Backend::Ufw => run(&ufw_commands(&view.ip_json, &view.ufw_v4, &view.ufw_v6)),
        Backend::Firewalld => {
            let openings = openings_from_ip_json(&view.ip_json);
            let missing = firewalld_missing(&openings, &view.firewalld_rules);
            let mut commands = Vec::new();
            for opening in missing {
                let zone = zone_of(&opening.iface);
                let family = if opening.source.addr.is_ipv4() {
                    "ipv4"
                } else {
                    "ipv6"
                };
                for proto in ["tcp", "udp"] {
                    let rule = rich_rule(family, &opening.source.display(), proto);
                    for flag in ["--add-rich-rule", "--permanent"] {
                        if flag == "--permanent" {
                            commands.push(vec![
                                "firewall-cmd".into(),
                                "--permanent".into(),
                                format!("--zone={zone}"),
                                format!("--add-rich-rule={rule}"),
                            ]);
                        } else {
                            commands.push(vec![
                                "firewall-cmd".into(),
                                format!("--zone={zone}"),
                                format!("--add-rich-rule={rule}"),
                            ]);
                        }
                    }
                }
            }
            run(&commands)
        }
    }
}

fn needs_apply(view: &View) -> bool {
    match view.backend {
        Backend::None => false,
        Backend::Ufw => !ufw_commands(&view.ip_json, &view.ufw_v4, &view.ufw_v6).is_empty(),
        Backend::Firewalld => {
            !firewalld_missing(&openings_from_ip_json(&view.ip_json), &view.firewalld_rules)
                .is_empty()
        }
    }
}

fn read_view(trust_env: bool) -> View {
    let ufw = ufw_enabled(trust_env);
    let firewalld = !ufw && firewalld_active(trust_env);
    let backend = if ufw {
        Backend::Ufw
    } else if firewalld {
        Backend::Firewalld
    } else {
        Backend::None
    };
    if backend == Backend::None {
        return View {
            backend,
            ip_json: String::new(),
            ufw_v4: String::new(),
            ufw_v6: String::new(),
            firewalld_rules: String::new(),
        };
    }
    View {
        backend,
        ip_json: ip_json(trust_env),
        ufw_v4: if ufw {
            read_text(&ufw_path(
                trust_env,
                "MACSHELL_UFW_USER",
                "/etc/ufw/user.rules",
            ))
        } else {
            String::new()
        },
        ufw_v6: if ufw {
            read_text(&ufw_path(
                trust_env,
                "MACSHELL_UFW_USER6",
                "/etc/ufw/user6.rules",
            ))
        } else {
            String::new()
        },
        firewalld_rules: if firewalld {
            firewalld_rules(trust_env)
        } else {
            String::new()
        },
    }
}

fn ufw_enabled(trust_env: bool) -> bool {
    let path = if trust_env {
        env::var_os("MACSHELL_UFW_CONF")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/etc/ufw/ufw.conf"))
    } else {
        PathBuf::from("/etc/ufw/ufw.conf")
    };
    read_text(&path).lines().any(|line| {
        let Some((key, value)) = line.split_once('=') else {
            return false;
        };
        key.trim() == "ENABLED" && value.trim().eq_ignore_ascii_case("yes")
    })
}

fn firewalld_active(trust_env: bool) -> bool {
    if trust_env {
        if let Ok(value) = env::var("MACSHELL_FIREWALLD") {
            return value == "active";
        }
    }
    Command::new("systemctl")
        .args(["is-active", "--quiet", "firewalld"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn ufw_path(trust_env: bool, key: &str, default: &str) -> PathBuf {
    if trust_env {
        if let Some(path) = env::var_os(key) {
            return PathBuf::from(path);
        }
    }
    PathBuf::from(default)
}

fn ip_json(trust_env: bool) -> String {
    if trust_env {
        if let Some(path) = env::var_os("MACSHELL_IP_JSON") {
            return read_text(&PathBuf::from(path));
        }
    }
    Command::new("ip")
        .args(["-json", "addr"])
        .stdin(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .unwrap_or_default()
}

fn firewalld_rules(trust_env: bool) -> String {
    if trust_env {
        if let Some(path) = env::var_os("MACSHELL_FIREWALLD_RULES") {
            return read_text(&PathBuf::from(path));
        }
    }
    Command::new("firewall-cmd")
        .arg("--list-all-zones")
        .stdin(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .unwrap_or_else(|| "\n".into())
}

fn read_text(path: &std::path::Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

fn run(commands: &[Vec<String>]) -> Result<(), String> {
    for args in commands {
        let Some(program) = args.first() else {
            continue;
        };
        let output = Command::new(program)
            .args(&args[1..])
            .stdin(Stdio::null())
            .output()
            .map_err(|error| error.to_string())?;
        let delete = args.get(1).map(String::as_str) == Some("delete");
        if !output.status.success() && !delete {
            let text = String::from_utf8_lossy(&output.stderr);
            let text = text.trim();
            return Err(if text.is_empty() {
                "The firewall did not accept the AirPlay network rule.".into()
            } else {
                text.chars().take(200).collect()
            });
        }
    }
    Ok(())
}

fn zone_of(iface: &str) -> String {
    let listed = Command::new("firewall-cmd")
        .arg(format!("--get-zone-of-interface={iface}"))
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .unwrap_or_default();
    let zone = listed.split_whitespace().next().unwrap_or("");
    if !zone.is_empty() && valid_token(zone) {
        return zone.to_string();
    }
    let default_zone = Command::new("firewall-cmd")
        .arg("--get-default-zone")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .unwrap_or_default();
    let zone = default_zone.trim();
    if valid_token(zone) {
        zone.to_string()
    } else {
        "public".into()
    }
}

fn valid_token(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 32
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
}

fn valid_iface(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 15
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
}

fn lan_interface(name: &str) -> bool {
    const SKIP: &[&str] = &["lo", "docker0", "awdl0", "podman0", "cni0"];
    if SKIP.contains(&name) || !valid_iface(name) {
        return false;
    }
    const PREFIXES: &[&str] = &[
        "docker",
        "br-",
        "veth",
        "virbr",
        "tun",
        "tap",
        "wg",
        "tailscale",
        "zt",
        "awdl",
        "ifb",
        "dummy",
        "vboxnet",
        "vmnet",
        "nm-",
        "flannel",
        "cni",
        "podman",
    ];
    !PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

fn openings_from_ip_json(text: &str) -> Vec<Opening> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return Vec::new();
    };
    let items = value.as_array().cloned().unwrap_or_else(|| vec![value]);
    let mut openings = Vec::new();
    for item in items {
        let Some(name) = item.get("ifname").and_then(|v| v.as_str()) else {
            continue;
        };
        if !lan_interface(name) {
            continue;
        }
        let up = item
            .get("flags")
            .and_then(|v| v.as_array())
            .is_some_and(|flags| flags.iter().any(|flag| flag.as_str() == Some("UP")))
            || item.get("operstate").and_then(|v| v.as_str()) == Some("UP");
        if !up {
            continue;
        }
        let Some(addresses) = item.get("addr_info").and_then(|v| v.as_array()) else {
            continue;
        };
        let mut link_local = false;
        for address in addresses {
            let family = address.get("family").and_then(|v| v.as_str()).unwrap_or("");
            let scope = address.get("scope").and_then(|v| v.as_str()).unwrap_or("");
            let local = address.get("local").and_then(|v| v.as_str()).unwrap_or("");
            let prefix = address
                .get("prefixlen")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u8;
            if family == "inet" && scope == "global" && (8..=30).contains(&prefix) {
                if let Ok(ip) = local.parse::<Ipv4Addr>() {
                    openings.push(Opening {
                        iface: name.to_string(),
                        source: Cidr {
                            addr: IpAddr::V4(Ipv4Addr::from(u32::from(ip) & v4_mask(prefix))),
                            prefix,
                        },
                    });
                }
            } else if family == "inet6" && scope == "link" {
                link_local = true;
            } else if family == "inet6" && scope == "global" && (16..=64).contains(&prefix) {
                if let Ok(ip) = local.parse::<Ipv6Addr>() {
                    openings.push(Opening {
                        iface: name.to_string(),
                        source: Cidr {
                            addr: IpAddr::V6(Ipv6Addr::from(u128::from(ip) & v6_mask(prefix))),
                            prefix,
                        },
                    });
                }
            }
        }
        if link_local {
            openings.push(Opening {
                iface: name.to_string(),
                source: Cidr::parse("fe80::/10").expect("link-local prefix"),
            });
        }
    }
    openings.sort_by(|a, b| (&a.iface, a.source.display()).cmp(&(&b.iface, b.source.display())));
    openings.dedup();
    openings
}

fn ufw_commands(ip_json: &str, v4: &str, v6: &str) -> Vec<Vec<String>> {
    let openings = openings_from_ip_json(ip_json);
    let mut rules = parse_ufw(v4);
    rules.extend(parse_ufw(v6));
    let mut commands = Vec::new();
    for rule in &rules {
        if rule.comment != COMMENT || !rule.accept || !rule.inbound {
            continue;
        }
        let (Some(iface), Some(source)) = (&rule.iface, &rule.source) else {
            continue;
        };
        if !valid_iface(iface) || (rule.proto != "tcp" && rule.proto != "udp") {
            continue;
        }
        let current = openings
            .iter()
            .any(|opening| &opening.iface == iface && opening.source == *source);
        if !current {
            commands.push(allow_args(true, iface, &rule.proto, &source.display()));
        }
    }
    for opening in &openings {
        for proto in ["tcp", "udp"] {
            if !covered(&rules, &opening.iface, proto, &opening.source) {
                commands.push(allow_args(
                    false,
                    &opening.iface,
                    proto,
                    &opening.source.display(),
                ));
            }
        }
    }
    commands
}

fn allow_args(delete: bool, iface: &str, proto: &str, source: &str) -> Vec<String> {
    let mut args = Vec::new();
    args.push("ufw".into());
    if delete {
        args.push("delete".into());
    }
    args.extend([
        "allow".into(),
        "in".into(),
        "on".into(),
        iface.into(),
        "proto".into(),
        proto.into(),
        "from".into(),
        source.into(),
        "to".into(),
        "any".into(),
        "port".into(),
        PORTS.into(),
    ]);
    if !delete {
        args.push("comment".into());
        args.push(COMMENT.into());
    }
    args
}

fn covered(rules: &[Rule], iface: &str, proto: &str, source: &Cidr) -> bool {
    rules.iter().any(|rule| {
        rule.accept
            && rule.inbound
            && rule.proto == proto
            && rule.ports_cover
            && rule
                .iface
                .as_deref()
                .map(|name| name == iface)
                .unwrap_or(true)
            && rule
                .source
                .as_ref()
                .map(|rule_source| rule_source.contains(source))
                .unwrap_or(true)
    })
}

fn parse_ufw(text: &str) -> Vec<Rule> {
    let mut rules = Vec::new();
    let mut comment = String::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(hex) = trimmed.split("comment=").nth(1) {
            comment = decode_hex(hex.split_whitespace().next().unwrap_or(""));
            continue;
        }
        if !trimmed.starts_with("-A ") {
            continue;
        }
        if let Some(rule) = parse_rule(trimmed, comment.clone()) {
            rules.push(rule);
        }
        comment.clear();
    }
    rules
}

fn parse_rule(line: &str, comment: String) -> Option<Rule> {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.first() != Some(&"-A") {
        return None;
    }
    let chain = tokens.get(1).copied().unwrap_or("");
    let inbound = chain == "ufw-user-input" || chain == "ufw6-user-input";
    let mut iface = None;
    let mut proto = String::new();
    let mut source = None;
    let mut action = "";
    let mut ports = String::new();
    let mut index = 2;
    while index < tokens.len() {
        let token = tokens[index];
        let value = tokens.get(index + 1).copied();
        match token {
            "-i" => {
                iface = value.map(str::to_string);
                index += 2;
            }
            "-p" => {
                proto = value.unwrap_or("").to_string();
                index += 2;
            }
            "-s" => {
                source = value.and_then(Cidr::parse);
                index += 2;
            }
            "-j" => {
                action = value.unwrap_or("");
                index += 2;
            }
            "--dport" | "--dports" => {
                if !ports.is_empty() {
                    ports.push(',');
                }
                ports.push_str(value.unwrap_or(""));
                index += 2;
            }
            _ => index += 1,
        }
    }
    Some(Rule {
        inbound,
        iface,
        proto,
        ports_cover: ports_cover(&ports),
        source,
        accept: action == "ACCEPT",
        comment,
    })
}

fn ports_cover(spec: &str) -> bool {
    if spec.is_empty() {
        return true;
    }
    let mut singles = Vec::new();
    for part in spec.split(',') {
        if let Some((start, end)) = part.split_once(':') {
            let (Ok(start), Ok(end)) = (start.parse::<u16>(), end.parse::<u16>()) else {
                continue;
            };
            if (start..=end).contains(&7100)
                && (start..=end).contains(&7101)
                && (start..=end).contains(&7102)
            {
                return true;
            }
        } else if let Ok(port) = part.parse::<u16>() {
            singles.push(port);
        }
    }
    [7100, 7101, 7102].iter().all(|port| singles.contains(port))
}

fn decode_hex(text: &str) -> String {
    if text.len() % 2 != 0 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return String::new();
    }
    let bytes = (0..text.len())
        .step_by(2)
        .filter_map(|index| u8::from_str_radix(&text[index..index + 2], 16).ok())
        .collect::<Vec<_>>();
    String::from_utf8(bytes).unwrap_or_default()
}

fn firewalld_missing(openings: &[Opening], listed: &str) -> Vec<Opening> {
    openings
        .iter()
        .filter(|opening| {
            let family = if opening.source.addr.is_ipv4() {
                "ipv4"
            } else {
                "ipv6"
            };
            ["tcp", "udp"].iter().any(|proto| {
                !listed
                    .lines()
                    .any(|line| rich_line_covers(line, family, &opening.source.display(), proto))
            })
        })
        .cloned()
        .collect()
}

fn rich_rule(family: &str, source: &str, proto: &str) -> String {
    format!(
        "rule family=\"{family}\" source address=\"{source}\" port port=\"7100-7102\" protocol=\"{proto}\" accept"
    )
}

fn rich_line_covers(line: &str, family: &str, source: &str, proto: &str) -> bool {
    let line = line.trim();
    line.contains("accept")
        && line.contains(family)
        && (line.contains("7100-7102") || line.contains("7100:7102"))
        && line.contains(&format!("protocol=\"{proto}\""))
        && (line.contains(&format!("address=\"{source}\""))
            || line.contains("address=\"0.0.0.0/0\"")
            || line.contains("address=\"::/0\"")
            || !line.contains("address="))
}

fn v4_mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    }
}

fn v6_mask(prefix: u8) -> u128 {
    if prefix == 0 {
        0
    } else {
        u128::MAX << (128 - prefix)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_ip() -> String {
        r#"[{"ifname":"wlan0","operstate":"UP","flags":["UP","LOWER_UP"],"addr_info":[
            {"family":"inet","local":"192.168.1.130","prefixlen":24,"scope":"global"},
            {"family":"inet6","local":"fe80::8a3:1348:3d10:602b","prefixlen":64,"scope":"link"}
        ]},{"ifname":"docker0","operstate":"UP","flags":["UP"],"addr_info":[
            {"family":"inet","local":"172.17.0.1","prefixlen":16,"scope":"global"}
        ]},{"ifname":"eth0","operstate":"DOWN","flags":["NO-CARRIER"],"addr_info":[
            {"family":"inet","local":"10.0.0.5","prefixlen":24,"scope":"global"}
        ]}]"#
            .into()
    }

    #[test]
    fn local_prefixes_skip_containers_down_links_and_single_phones() {
        let openings = openings_from_ip_json(&sample_ip());
        let shown: Vec<_> = openings
            .iter()
            .map(|opening| format!("{} {}", opening.iface, opening.source.display()))
            .collect();
        assert_eq!(
            shown,
            vec![
                "wlan0 192.168.1.0/24".to_string(),
                "wlan0 fe80::/10".to_string(),
            ]
        );
    }

    #[test]
    fn narrower_phone_rule_does_not_cover_the_link() {
        let rules = "### tuple ### allow tcp 7100:7102 ::/0 any fe80::3d:79b1:5b82:3a63 in_wlan0 comment=4d61635368656c6c20416972506c6179206950686f6e65
-A ufw6-user-input -i wlan0 -p tcp -m multiport --dports 7100:7102 -s fe80::3d:79b1:5b82:3a63 -j ACCEPT
### tuple ### allow udp 7100:7102 ::/0 any fe80::3d:79b1:5b82:3a63 in_wlan0 comment=4d61635368656c6c20416972506c6179206950686f6e65
-A ufw6-user-input -i wlan0 -p udp -m multiport --dports 7100:7102 -s fe80::3d:79b1:5b82:3a63 -j ACCEPT
";
        let commands = ufw_commands(&sample_ip(), "", rules);
        assert!(commands
            .iter()
            .any(|args| args[1] == "allow" && args[8] == "192.168.1.0/24" && args[6] == "tcp"));
        assert!(commands
            .iter()
            .any(|args| args[1] == "allow" && args[8] == "fe80::/10" && args[6] == "udp"));
        assert!(commands.iter().all(|args| args[1] != "delete"));
        assert_eq!(commands.iter().filter(|args| args[1] == "allow").count(), 4);
    }

    #[test]
    fn existing_local_rules_need_no_change_and_old_ours_are_replaced() {
        let current = "### tuple ### allow tcp 7100:7102 0.0.0.0/0 any 192.168.1.0/24 in_wlan0 comment=4d61635368656c6c20416972506c6179
-A ufw-user-input -i wlan0 -p tcp -m multiport --dports 7100:7102 -s 192.168.1.0/24 -j ACCEPT
### tuple ### allow udp 7100:7102 0.0.0.0/0 any 192.168.1.0/24 in_wlan0 comment=4d61635368656c6c20416972506c6179
-A ufw-user-input -i wlan0 -p udp -m multiport --dports 7100:7102 -s 192.168.1.0/24 -j ACCEPT
";
        let link = "### tuple ### allow tcp 7100:7102 ::/0 any fe80::/10 in_wlan0 comment=4d61635368656c6c20416972506c6179
-A ufw6-user-input -i wlan0 -p tcp -m multiport --dports 7100:7102 -s fe80::/10 -j ACCEPT
### tuple ### allow udp 7100:7102 ::/0 any fe80::/10 in_wlan0 comment=4d61635368656c6c20416972506c6179
-A ufw6-user-input -i wlan0 -p udp -m multiport --dports 7100:7102 -s fe80::/10 -j ACCEPT
### tuple ### allow tcp 7100:7102 0.0.0.0/0 any 10.1.0.0/22 in_wlan0 comment=4d61635368656c6c20416972506c6179
-A ufw-user-input -i wlan0 -p tcp -m multiport --dports 7100:7102 -s 10.1.0.0/22 -j ACCEPT
";
        let commands = ufw_commands(&sample_ip(), current, link);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0][1], "delete");
        assert_eq!(commands[0][9], "10.1.0.0/22");
    }

    #[test]
    fn anywhere_already_covers_and_a_wider_prefix_is_kept() {
        let rules = "-A ufw-user-input -p tcp -m multiport --dports 7000:7200 -j ACCEPT
-A ufw-user-input -p udp -m multiport --dports 7100,7101,7102 -j ACCEPT
";
        let link = "-A ufw6-user-input -p tcp -m multiport --dports 7100:7102 -j ACCEPT
-A ufw6-user-input -p udp --dport 7100:7102 -j ACCEPT
";
        assert!(ufw_commands(&sample_ip(), rules, link).is_empty());
    }

    #[test]
    fn firewalld_rich_rule_matches_the_local_prefix_only() {
        let openings = openings_from_ip_json(&sample_ip());
        let listed = format!(
            "{}\n{}",
            rich_rule("ipv4", "192.168.1.0/24", "tcp"),
            rich_rule("ipv6", "fe80::1/128", "tcp")
        );
        let missing = firewalld_missing(&openings, &listed);
        assert!(missing
            .iter()
            .any(|opening| opening.source.display() == "fe80::/10"));
        assert!(missing
            .iter()
            .any(|opening| opening.source.display() == "192.168.1.0/24"));
        let full = openings
            .iter()
            .flat_map(|opening| {
                let family = if opening.source.addr.is_ipv4() {
                    "ipv4"
                } else {
                    "ipv6"
                };
                ["tcp", "udp"].map(|proto| rich_rule(family, &opening.source.display(), proto))
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(firewalld_missing(&openings, &full).is_empty());
    }
}
