mod parse;

use parse::Counters;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::Path;
use std::time::{Duration, Instant};

fn read(path: impl AsRef<Path>) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

fn clock(id: libc::clockid_t) -> io::Result<f64> {
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(id, &mut value) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(value.tv_sec as f64 + value.tv_nsec as f64 / 1_000_000_000.0)
}

fn default_interface(net: &Counters) -> String {
    let available: BTreeSet<_> = net
        .keys()
        .filter(|name| {
            *name != "lo"
                && Path::new("/sys/class/net")
                    .join(name)
                    .join("device")
                    .exists()
        })
        .cloned()
        .collect();
    for (_, name) in parse::routes(&read("/proc/net/route"), &read("/proc/net/ipv6_route")) {
        if available.contains(&name) {
            return name;
        }
    }
    available
        .into_iter()
        .find(|name| read(Path::new("/sys/class/net").join(name).join("operstate")).trim() == "up")
        .unwrap_or_default()
}

fn block_name(device: u64, names: &Counters) -> String {
    let path = format!(
        "/sys/dev/block/{}:{}",
        libc::major(device),
        libc::minor(device)
    );
    fs::canonicalize(path)
        .ok()
        .and_then(|path| path.file_name().map(|s| s.to_string_lossy().into_owned()))
        .filter(|name| names.contains_key(name))
        .unwrap_or_default()
}

fn single_btrfs_device(name: &str, root: &Path) -> bool {
    let Ok(entries) = fs::read_dir(root) else {
        return false;
    };
    for entry in entries.flatten() {
        if let Ok(devices) = fs::read_dir(entry.path().join("devices")) {
            let devices: Vec<_> = devices.flatten().map(|entry| entry.file_name()).collect();
            if devices.iter().any(|device| device == name) {
                return devices.len() == 1;
            }
        }
    }
    false
}

fn root_device(names: &Counters) -> String {
    let Ok(root) = fs::metadata("/") else {
        return String::new();
    };
    let name = block_name(root.dev(), names);
    if !name.is_empty() {
        return name;
    }
    let Some((filesystem, source)) = parse::root_mount(&read("/proc/self/mountinfo")) else {
        return String::new();
    };
    if !source.starts_with("/dev/") {
        return String::new();
    }
    let Ok(device) = fs::metadata(source) else {
        return String::new();
    };
    if !device.file_type().is_block_device() {
        return String::new();
    }
    let name = block_name(device.rdev(), names);
    if filesystem == "btrfs"
        && !name.is_empty()
        && !single_btrfs_device(&name, Path::new("/sys/fs/btrfs"))
    {
        return String::new();
    }
    name
}

fn capacity() -> Option<Value> {
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::statvfs(c"/".as_ptr(), stats.as_mut_ptr()) } != 0 {
        return None;
    }
    let stats = unsafe { stats.assume_init() };
    Some(
        json!({"total": stats.f_blocks.saturating_mul(stats.f_frsize), "free": stats.f_bavail.saturating_mul(stats.f_frsize)}),
    )
}

fn temperature() -> Option<f64> {
    let mut values = Vec::new();
    for hwmon in fs::read_dir("/sys/class/hwmon").ok()?.flatten() {
        let name = read(hwmon.path().join("name"));
        if !matches!(
            name.trim(),
            "coretemp" | "k10temp" | "zenpower" | "cpu_thermal"
        ) {
            continue;
        }
        if let Ok(entries) = fs::read_dir(hwmon.path()) {
            for entry in entries.flatten() {
                let filename = entry.file_name().to_string_lossy().into_owned();
                if filename.starts_with("temp") && filename.ends_with("_input") {
                    if let Ok(value) = read(entry.path()).trim().parse::<f64>() {
                        let value = value / 1000.;
                        if value > 0. && value < 130. {
                            values.push(value);
                        }
                    }
                }
            }
        }
    }
    values.into_iter().reduce(f64::max)
}

struct Previous {
    now: f64,
    sleep: f64,
    cpu: Counters,
    net: Counters,
    disk: Counters,
    iface: String,
    block: String,
}

fn has_gap(now: f64, boot: f64, cpus: &Counters, old: Option<&Previous>) -> bool {
    old.is_none_or(|p| {
        now - p.now > 15. || ((boot - now) - p.sleep).abs() > 0.5 || !cpus.keys().eq(p.cpu.keys())
    })
}
#[derive(Default)]
struct Sampler {
    previous: Option<Previous>,
    capacity: Option<Value>,
    capacity_at: Option<f64>,
}

impl Sampler {
    fn sample(&mut self, interface: &str, device: &str) -> io::Result<Value> {
        let now = clock(libc::CLOCK_MONOTONIC)?;
        let boot = clock(libc::CLOCK_BOOTTIME)?;
        let mut cpus = parse::cpus(&read("/proc/stat"));
        let net = parse::networks(&read("/proc/net/dev"));
        let disk = parse::disks(&read("/proc/diskstats"));
        let iface = if interface.is_empty() {
            default_interface(&net)
        } else if net.contains_key(interface) {
            interface.into()
        } else {
            String::new()
        };
        let block = if device.is_empty() {
            root_device(&disk)
        } else if disk.contains_key(device) {
            device.into()
        } else {
            String::new()
        };
        let old = self.previous.as_ref();
        let gap = has_gap(now, boot, &cpus, old);
        let elapsed = old.map_or(0., |p| now - p.now);
        let mut cpu_values = serde_json::Map::new();
        for (key, value) in &cpus {
            let before = old.filter(|_| !gap).and_then(|p| p.cpu.get(key)).copied();
            cpu_values.insert(key.clone(), json!(parse::cpu_delta(before, *value)));
        }
        let overall = cpu_values.remove("cpu").unwrap_or(Value::Null);
        let net_before = old
            .filter(|p| !gap && p.iface == iface)
            .and_then(|p| p.net.get(&iface))
            .copied();
        let disk_before = old
            .filter(|p| !gap && p.block == block)
            .and_then(|p| p.disk.get(&block))
            .copied();
        let net_rate = parse::rates(net_before, net.get(&iface).copied(), elapsed);
        let disk_rate = parse::rates(disk_before, disk.get(&block).copied(), elapsed);
        if self.capacity_at.is_none_or(|p| now - p >= 30.) {
            self.capacity = capacity();
            self.capacity_at = Some(now);
        }
        let label = if !device.is_empty() && !block.is_empty() {
            "Selected block layer (manual)"
        } else if !device.is_empty() {
            "Selected block device is unavailable"
        } else if !block.is_empty() {
            "Root filesystem block layer"
        } else {
            "Select a block device (root mapping unavailable)"
        };
        let result = json!({"type":"sample", "time":boot, "gap":gap, "cpu":overall, "cores":cpu_values,
            "memory":parse::memory(&read("/proc/meminfo")), "interface":iface,
            "interfaces":net.keys().filter(|n| *n != "lo").collect::<Vec<_>>(), "network":net_rate,
            "device":block, "devices":disk.keys().filter(|n| !n.starts_with("loop") && !n.starts_with("ram")).collect::<Vec<_>>(),
            "disk":disk_rate, "diskLabel":label, "capacity":self.capacity, "temperature":temperature()});
        self.previous = Some(Previous {
            now,
            sleep: boot - now,
            cpu: std::mem::take(&mut cpus),
            net,
            disk,
            iface,
            block,
        });
        Ok(result)
    }
}

fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    let encoded = serde_json::to_vec(&value)?;
    output.write_all(&encoded)?;
    writeln!(output)?;
    output.flush()
}

fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-system-stats 1");
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut generation = None;
    let mut sampler = Sampler::default();
    let mut interval = 1u64;
    let mut interface = String::new();
    let mut device = String::new();
    let mut deadline = Instant::now();
    let mut buffer = Vec::new();
    emit(&mut out, json!({"type":"ready"}), &generation)?;
    loop {
        let timeout = deadline
            .saturating_duration_since(Instant::now())
            .as_millis()
            .min(i32::MAX as u128) as i32;
        let mut fd = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let polled = unsafe { libc::poll(&mut fd, 1, timeout) };
        if polled < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if fd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut input = [0u8; 65536];
            let size =
                unsafe { libc::read(libc::STDIN_FILENO, input.as_mut_ptr().cast(), input.len()) };
            if size <= 0 {
                break;
            }
            buffer.extend_from_slice(&input[..size as usize]);
            if buffer.len() > 1_048_576 {
                break;
            }
            while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<_> = buffer.drain(..=end).collect();
                let parsed = serde_json::from_slice::<Value>(&line);
                if let Ok(request) = parsed {
                    let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
                    if request.is_object()
                        && data.is_object()
                        && request.get("generation").is_some()
                    {
                        generation = request.get("generation").cloned();
                        if let Some(value) = data.get("interval") {
                            interval = value
                                .as_u64()
                                .filter(|n| [1, 2, 5].contains(n))
                                .unwrap_or(1);
                        }
                        if let Some(value) = data.get("interface").and_then(Value::as_str) {
                            interface = value.to_owned();
                        }
                        if let Some(value) = data.get("device").and_then(Value::as_str) {
                            device = value.to_owned();
                        }
                        sampler.previous = None;
                        deadline = Instant::now();
                        continue;
                    }
                }
                emit(
                    &mut out,
                    json!({"type":"error", "error":"Invalid service request"}),
                    &generation,
                )?;
            }
        }
        if Instant::now() >= deadline {
            emit(&mut out, sampler.sample(&interface, &device)?, &generation)?;
            deadline = Instant::now() + Duration::from_secs(interval);
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-system-stats: {error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resets_after_sleep_long_gap_and_cpu_hotplug() {
        let cpu = parse::cpus("cpu 1 2 3 4 5\ncpu0 1 2 3 4 5");
        let old = Previous {
            now: 100.,
            sleep: 0.,
            cpu: cpu.clone(),
            net: Counters::new(),
            disk: Counters::new(),
            iface: String::new(),
            block: String::new(),
        };
        assert!(has_gap(101., 101., &cpu, None));
        assert!(!has_gap(101., 101., &cpu, Some(&old)));
        assert!(has_gap(102., 162., &cpu, Some(&old)));
        assert!(has_gap(116., 116., &cpu, Some(&old)));
        assert!(has_gap(101., 101., &Counters::new(), Some(&old)));
    }

    #[test]
    fn btrfs_multiple_devices_are_not_misrepresented() {
        let path = std::env::temp_dir().join(format!("macshell-stats-test-{}", std::process::id()));
        let devices = path.join("filesystem/devices");
        fs::create_dir(&path).unwrap();
        fs::create_dir_all(&devices).unwrap();
        fs::write(devices.join("sda1"), "").unwrap();
        assert!(single_btrfs_device("sda1", &path));
        assert!(!single_btrfs_device("sdb1", &path));
        fs::write(devices.join("sdb1"), "").unwrap();
        assert!(!single_btrfs_device("sda1", &path));
        fs::remove_dir_all(path).unwrap();
    }
}
