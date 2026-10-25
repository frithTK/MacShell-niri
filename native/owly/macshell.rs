// MIT. Machine interface for MacShell, included in owly-cli's airdrop module.
// Owly's protocol and radio implementation remain in the pinned upstream tree.

#[derive(clap::Subcommand)]
pub enum MacshellCommand {
    Capabilities,
    Radio {
        #[arg(long, default_value_t = 600)]
        seconds: u32,
    },
    Browse {
        #[command(flatten)]
        on: On,
        #[arg(long, default_value_t = 10)]
        seconds: u64,
    },
    Send {
        #[command(flatten)]
        on: On,
        #[arg(long)]
        address: SocketAddrV6,
        #[arg(long)]
        flags: u32,
        #[arg(required = true)]
        files: Vec<PathBuf>,
    },
    Receive {
        #[command(flatten)]
        on: On,
        #[arg(long)]
        dir: PathBuf,
    },
}

fn ms_emit(value: serde_json::Value) {
    use std::io::Write;
    println!("{value}");
    let _ = io::stdout().flush();
}

pub async fn macshell(bus: Option<&str>, command: MacshellCommand) -> Result<ExitCode, String> {
    match command {
        MacshellCommand::Capabilities => {
            ms_emit(serde_json::json!({"event":"capabilities", "protocol":1}));
            Ok(ExitCode::SUCCESS)
        }
        MacshellCommand::Radio { seconds } => ms_radio(bus, seconds).await,
        MacshellCommand::Browse { on, seconds } => {
            ms_browse(bus, on, seconds).await.map_err(|e| e.to_string())
        }
        MacshellCommand::Send {
            on,
            address,
            flags,
            files,
        } => ms_send(on, address, flags, files)
            .await
            .map_err(|e| e.to_string()),
        MacshellCommand::Receive { on, dir } => {
            ms_receive(bus, on, dir).await.map_err(|e| e.to_string())
        }
    }
}

fn ms_check_radio_report(report: &serde_json::Value) -> Result<(), String> {
    if report["mode"].as_str() != Some("shared") {
        return Err("AirDrop would disconnect Wi-Fi and interrupt calls on this adapter. This mode is disabled.".into());
    }
    if report["hardware"].as_bool() != Some(true)
        || !report["missing"]
            .as_array()
            .is_some_and(|missing| missing.is_empty())
    {
        return Err("The AirDrop backend is not ready.".into());
    }
    Ok(())
}

async fn ms_radio(bus: Option<&str>, seconds: u32) -> Result<ExitCode, String> {
    use futures_util::StreamExt;
    use tokio::signal::unix::{SignalKind, signal};
    let connection = api::connect(bus).await.map_err(|e| e.to_string())?;
    let radio = api::radio(&connection).await.map_err(|e| e.to_string())?;
    let report = radio.probe().await.map_err(|e| e.to_string())?;
    let report = serde_json::from_str(&report).map_err(|e| e.to_string())?;
    ms_check_radio_report(&report)?;
    let mut changes = radio
        .receive_radio_state()
        .await
        .map_err(|e| e.to_string())?;
    let wifi = crate::wifi::active();
    let (lease, link) = radio
        .acquire(seconds.clamp(1, 600))
        .await
        .map_err(|e| e.to_string())?;
    let info = LinkInfo::from_dict(&link).ok_or("Owly returned an invalid link")?;
    ms_emit(serde_json::json!({"event":"radio_ready", "interface":info.interface}));
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => break,
            _ = term.recv() => break,
            changed = changes.next() => {
                let Some(changed) = changed else { break };
                if let Ok(args) = changed.args() {
                    if args.lease == lease && args.state == "idle" {
                        crate::wifi::restore(wifi).await;
                        ms_emit(serde_json::json!({"event":"radio_stopped", "reason":args.reason}));
                        return Ok(ExitCode::SUCCESS);
                    }
                }
            }
        }
    }
    let result = radio.release(lease).await;
    crate::wifi::restore(wifi).await;
    result.map_err(|e| e.to_string())?;
    ms_emit(serde_json::json!({"event":"radio_stopped"}));
    Ok(ExitCode::SUCCESS)
}

#[cfg(test)]
mod ms_policy_tests {
    use super::ms_check_radio_report;
    use serde_json::json;

    #[test]
    fn ready_shared_radio_is_allowed() {
        assert!(
            ms_check_radio_report(&json!({"mode":"shared", "hardware":true, "missing":[]})).is_ok()
        );
    }

    #[test]
    fn disruptive_and_unknown_modes_are_rejected_before_acquire() {
        for mode in ["exclusive", "active-monitor", "unknown", ""] {
            assert!(
                ms_check_radio_report(&json!({"mode":mode, "hardware":true, "missing":[]}))
                    .is_err()
            );
        }
    }

    #[test]
    fn incomplete_reports_are_rejected() {
        for report in [
            json!({}),
            json!({"mode":"shared"}),
            json!({"mode":"shared", "hardware":false, "missing":[]}),
            json!({"mode":"shared", "hardware":true, "missing":[{"id":"radio"}]}),
        ] {
            assert!(ms_check_radio_report(&report).is_err());
        }
    }
}

fn ms_listed(receiver: &Listed) {
    ms_emit(
        serde_json::json!({"event":"device", "key":receiver.addr.to_string(),
        "name":receiver.name, "flags":receiver.flags}),
    );
}

async fn ms_browse(bus: Option<&str>, on: On, seconds: u64) -> io::Result<ExitCode> {
    let (iface, name) = on.resolve()?;
    let _advert = advertise(false).await;
    let sender = Sender::new(sender::Config::new(name, random_service_id()?))?;
    let limit = Duration::from_secs(seconds.clamp(1, 15));
    let mdns = browse_receivers(&iface, &sender, limit, |receiver| {
        ms_listed(receiver);
        false
    });
    // Some Apple devices don't answer mDNS reliably. Also try discovered AWDL
    // peers, using the same /Discover exchange as upstream's sender.
    let direct = async {
        let Ok(lease) = Lease::find(bus, &iface.name).await else {
            return;
        };
        let deadline = tokio::time::Instant::now() + limit;
        let mut seen = std::collections::HashSet::new();
        while tokio::time::Instant::now() < deadline {
            for mac in lease.peers().await {
                if !seen.insert(mac) {
                    continue;
                }
                let address = SocketAddrV6::new(mac.link_local(), AIRDROP_PORT, 0, iface.index);
                if let Ok(Ok(Some(receiver))) =
                    tokio::time::timeout(Duration::from_secs(2), sender.discover(address)).await
                {
                    ms_listed(&Listed {
                        instance: mac.to_string(),
                        name: receiver.computer_name,
                        addr: address,
                        flags: RECEIVER_FLAGS | SUPPORTS_DVZIP,
                    });
                }
            }
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
    };
    let (result, ()) = tokio::join!(mdns, direct);
    result?;
    ms_emit(serde_json::json!({"event":"scan_done"}));
    Ok(ExitCode::SUCCESS)
}

async fn ms_send(
    on: On,
    address: SocketAddrV6,
    flags: u32,
    files: Vec<PathBuf>,
) -> io::Result<ExitCode> {
    let (_, name) = on.resolve()?;
    let sender = Sender::new(sender::Config::new(name, random_service_id()?))?;
    let (events, mut updates) = tokio::sync::mpsc::unbounded_channel();
    let printer = tokio::spawn(async move {
        while let Some(event) = updates.recv().await {
            match event {
                Event::Accepted => ms_emit(serde_json::json!({"event":"accepted"})),
                Event::Progress(p) => {
                    ms_emit(serde_json::json!({"event":"progress", "sent":p.sent, "total":p.total}))
                }
            }
        }
    });
    let result = sender
        .send(address, &Payload::Files(files), flags, Some(events))
        .await;
    let _ = printer.await;
    let outcome = result?;
    let (event, reason, code) = match outcome {
        Outcome::Delivered => ("delivered", String::new(), 0),
        Outcome::Declined => ("declined", String::new(), 1),
        Outcome::Failed(reason) => ("failed", reason, 2),
    };
    ms_emit(serde_json::json!({"event":event, "reason":reason}));
    Ok(ExitCode::from(code))
}

async fn ms_receive(bus: Option<&str>, on: On, dir: PathBuf) -> io::Result<ExitCode> {
    let (iface, name) = on.resolve()?;
    let announce = Lease::find(bus, &iface.name)
        .await
        .ok()
        .and_then(|lease| lease.link.announce);
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .ok_or_else(|| io::Error::other("No state directory"))?
        .join("macshell-airdrop");
    let identity = Identity::load_or_generate(&state)?;
    let mut config = Config::new(name);
    config.model_name = "Linux".into();
    let address = SocketAddrV6::new(iface.addr, RECEIVE_PORT, 0, iface.index);
    let (receiver, mut events) =
        Receiver::bind(address, &identity, Options::new(config, dir)).await?;
    tokio::spawn(receiver.run());
    let service_id = random_service_id()?;
    let service = Service {
        instance: service_id.clone(),
        host: format!("owly-{service_id}"),
        port: RECEIVE_PORT,
        addr: iface.addr,
        flags: RECEIVER_FLAGS,
    };
    let _registration = Mdns::new(iface.index)
        .with_burst(burst(announce))
        .register(service)
        .await?;
    ms_emit(serde_json::json!({"event":"receiver_ready"}));
    let mut stdin = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    loop {
        let event = tokio::select! {
            event = events.recv() => event,
            _ = tokio::signal::ctrl_c() => return Ok(ExitCode::SUCCESS),
        };
        let Some(event) = event else {
            return Ok(ExitCode::SUCCESS);
        };
        match event {
            ReceiverEvent::Discovered { .. } => {}
            ReceiverEvent::Request(request) => {
                let id = request.id;
                let (files, urls) = match &request.ask.offer {
                    Offer::Files(files) => (
                        files
                            .iter()
                            .map(|file| serde_json::json!({"name":file.name, "size":file.size}))
                            .collect::<Vec<_>>(),
                        vec![],
                    ),
                    Offer::Urls(urls) => (vec![], urls.clone()),
                };
                ms_emit(
                    serde_json::json!({"event":"request", "id":id, "name":request.ask.sender_computer_name,
                    "files":files, "urls":urls}),
                );
                let deadline = tokio::time::Instant::now() + Duration::from_secs(14);
                let accepted = loop {
                    match tokio::time::timeout_at(deadline, stdin.next_line()).await {
                        Ok(Ok(Some(line))) => {
                            let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
                                continue;
                            };
                            if value["id"].as_u64() == Some(id) {
                                break value["accept"].as_bool() == Some(true);
                            }
                        }
                        _ => break false,
                    }
                };
                if accepted {
                    request.accept();
                } else {
                    request.decline();
                }
                ms_emit(serde_json::json!({"event":"answered", "id":id, "accepted":accepted}));
            }
            ReceiverEvent::Withdrawn { id } => {
                ms_emit(serde_json::json!({"event":"withdrawn", "id":id}))
            }
            ReceiverEvent::Urls { id, urls } => {
                ms_emit(serde_json::json!({"event":"received_urls", "id":id, "urls":urls}))
            }
            ReceiverEvent::Received { id, paths } => {
                ms_emit(serde_json::json!({"event":"received", "id":id, "paths":paths}))
            }
            ReceiverEvent::Failed { id, reason } => {
                ms_emit(serde_json::json!({"event":"receive_failed", "id":id, "reason":reason}))
            }
        }
    }
}
