use std::io::{self, BufWriter, Write};
use std::time::Duration;

fn valid_boot_id(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| match i {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
}

fn boottime_ms() -> io::Result<u64> {
    let mut timestamp = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // CLOCK_BOOTTIME includes time spent suspended, unlike CLOCK_MONOTONIC.
    if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut timestamp) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let seconds = u64::try_from(timestamp.tv_sec)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "negative boot time"))?;
    Ok(seconds * 1_000 + timestamp.tv_nsec as u64 / 1_000_000)
}

fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-boot-clock 1");
        return Ok(());
    }
    if !args.is_empty() && args != ["--once"] {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected --once or no arguments",
        ));
    }
    let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    let boot_id = boot_id.trim();
    if !valid_boot_id(boot_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid boot ID",
        ));
    }
    let stdout = io::stdout();
    let mut output = BufWriter::new(stdout.lock());
    loop {
        writeln!(
            output,
            "{{\"bootId\":\"{}\",\"bootMs\":{}}}",
            boot_id,
            boottime_ms()?
        )?;
        output.flush()?;
        if !args.is_empty() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

fn main() {
    if let Err(error) = run() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-boot-clock: {error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_canonical_boot_ids() {
        assert!(valid_boot_id("12345678-abcd-4000-8000-123456789abc"));
        assert!(!valid_boot_id("12345678-ABCD-4000-8000-123456789abc"));
        assert!(!valid_boot_id("12345678abcd40008000123456789abc"));
        assert!(!valid_boot_id("12345678-abcd-4000-8000-123456789abg"));
    }

    #[test]
    fn boot_clock_advances() {
        let before = boottime_ms().unwrap();
        std::thread::sleep(Duration::from_millis(10));
        assert!(boottime_ms().unwrap() >= before + 1);
    }
}
