//! Linux rfkill handling for an explicit request to enable Bluetooth.
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;

const BLUETOOTH: u8 = 2;
const ADD: u8 = 0;
const DELETE: u8 = 1;
const CHANGE: u8 = 2;
const CHANGE_ALL: u8 = 3;
const EVENT_SIZE: usize = 8;
const MAX_EVENTS: usize = 4096;

trait Radio {
    fn read_event(&mut self) -> io::Result<Option<[u8; EVENT_SIZE]>>;
    fn unblock_bluetooth(&mut self) -> io::Result<()>;
}

struct KernelRadio(File);

impl Radio for KernelRadio {
    fn read_event(&mut self) -> io::Result<Option<[u8; EVENT_SIZE]>> {
        let mut event = [0; EVENT_SIZE];
        loop {
            match self.0.read(&mut event) {
                Ok(EVENT_SIZE) => return Ok(Some(event)),
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid rfkill event",
                    ))
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(None),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
    }

    fn unblock_bluetooth(&mut self) -> io::Result<()> {
        let mut device = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open("/dev/rfkill")?;
        // RFKILL_OP_CHANGE_ALL applies only to Bluetooth, never to WLAN.
        device.write_all(&[0, 0, 0, 0, BLUETOOTH, CHANGE_ALL, 0, 0])
    }
}

fn enable(radio: &mut impl Radio) -> Result<(), String> {
    let mut switches = BTreeMap::new();
    let mut finished = false;
    for _ in 0..MAX_EVENTS {
        let Some(event) = radio
            .read_event()
            .map_err(|_| "Could not read Bluetooth radio state.")?
        else {
            finished = true;
            break;
        };
        if event[4] != BLUETOOTH {
            continue;
        }
        let index = u32::from_ne_bytes(event[0..4].try_into().unwrap());
        match event[5] {
            ADD | CHANGE if event[6] <= 1 && event[7] <= 1 => {
                switches.insert(index, (event[6] != 0, event[7] != 0));
            }
            DELETE => {
                switches.remove(&index);
            }
            _ => return Err("Invalid Bluetooth radio state.".into()),
        }
    }
    if !finished {
        return Err("Could not determine Bluetooth radio state.".into());
    }
    if switches.values().any(|(_, hard)| *hard) {
        return Err("Bluetooth is blocked by a hardware switch or airplane mode.".into());
    }
    if switches.values().any(|(soft, _)| *soft) {
        radio
            .unblock_bluetooth()
            .map_err(|_| "Could not unblock Bluetooth. Check radio permissions and try again.")?;
    }
    Ok(())
}

pub fn unblock_bluetooth() -> Result<(), String> {
    let device = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open("/dev/rfkill");
    match device {
        Ok(device) => enable(&mut KernelRadio(device)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("Could not read Bluetooth radio state.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    #[derive(Default)]
    struct Fake {
        events: VecDeque<[u8; 8]>,
        writes: usize,
        deny: bool,
    }
    impl Radio for Fake {
        fn read_event(&mut self) -> io::Result<Option<[u8; 8]>> {
            Ok(self.events.pop_front())
        }
        fn unblock_bluetooth(&mut self) -> io::Result<()> {
            self.writes += 1;
            if self.deny {
                Err(io::ErrorKind::PermissionDenied.into())
            } else {
                Ok(())
            }
        }
    }
    fn event(index: u32, kind: u8, op: u8, soft: u8, hard: u8) -> [u8; 8] {
        let mut bytes = [0; 8];
        bytes[..4].copy_from_slice(&index.to_ne_bytes());
        bytes[4..].copy_from_slice(&[kind, op, soft, hard]);
        bytes
    }
    #[test]
    fn only_software_blocked_bluetooth_is_unblocked() {
        let mut fake = Fake {
            events: [event(1, 1, ADD, 1, 0), event(2, BLUETOOTH, ADD, 1, 0)].into(),
            ..Fake::default()
        };
        assert!(enable(&mut fake).is_ok());
        assert_eq!(fake.writes, 1);
    }
    #[test]
    fn unblocked_and_removed_switches_require_no_write() {
        let mut fake = Fake {
            events: [
                event(1, BLUETOOTH, ADD, 1, 0),
                event(1, BLUETOOTH, DELETE, 0, 0),
                event(2, BLUETOOTH, ADD, 0, 0),
            ]
            .into(),
            ..Fake::default()
        };
        assert!(enable(&mut fake).is_ok());
        assert_eq!(fake.writes, 0);
    }
    #[test]
    fn hardware_block_or_denied_write_is_reported() {
        let mut hard = Fake {
            events: [event(1, BLUETOOTH, ADD, 1, 1)].into(),
            ..Fake::default()
        };
        assert!(enable(&mut hard).unwrap_err().contains("hardware"));
        assert_eq!(hard.writes, 0);
        let mut denied = Fake {
            events: [event(1, BLUETOOTH, ADD, 1, 0)].into(),
            deny: true,
            ..Fake::default()
        };
        assert!(enable(&mut denied).unwrap_err().contains("permissions"));
    }
    #[test]
    fn invalid_or_unbounded_state_never_writes() {
        let mut invalid = Fake {
            events: [event(1, BLUETOOTH, ADD, 2, 0)].into(),
            ..Fake::default()
        };
        assert!(enable(&mut invalid).is_err());
        assert_eq!(invalid.writes, 0);
        let mut flood = Fake {
            events: vec![event(1, BLUETOOTH, ADD, 1, 0); MAX_EVENTS].into(),
            ..Fake::default()
        };
        assert!(enable(&mut flood).is_err());
        assert_eq!(flood.writes, 0);
    }
}
