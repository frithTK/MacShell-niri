//! Fresh identifiers for user-requested NetworkManager profiles.
use std::ffi::c_void;
use std::io::{self, Read};

extern "C" {
    fn getrandom(buffer: *mut c_void, length: usize, flags: u32) -> isize;
}
struct OsRandom;
impl Read for OsRandom {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        // GRND_NONBLOCK fails closed instead of blocking or using an
        // uninitialised source early in boot. read_exact retries EINTR.
        let count = unsafe { getrandom(output.as_mut_ptr().cast(), output.len(), 1) };
        if count < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(count as usize)
        }
    }
}

/// Generate a random UUIDv4 using the kernel CSPRNG. Failure is reported;
/// callers must not substitute a timestamp, counter or other predictable ID.
pub fn new_uuid() -> io::Result<String> {
    from_reader(&mut OsRandom)
}

fn from_reader(source: &mut impl Read) -> io::Result<String> {
    let mut bytes = [0u8; 16];
    source.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!("{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
        bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    #[test]
    fn formats_uuid_and_applies_v4_bits() {
        let mut input = Cursor::new([0xff; 16]);
        assert_eq!(
            from_reader(&mut input).unwrap(),
            "ffffffff-ffff-4fff-bfff-ffffffffffff"
        );
    }
    #[test]
    fn rejects_incomplete_entropy_without_fallback() {
        assert_eq!(
            from_reader(&mut Cursor::new([0u8; 15])).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }
    #[test]
    fn operating_system_source_produces_distinct_valid_identifiers() {
        let first = new_uuid().unwrap();
        let second = new_uuid().unwrap();
        assert_ne!(first, second);
        assert_eq!(first.len(), 36);
        assert_eq!(first.as_bytes()[14], b'4');
        assert!(matches!(first.as_bytes()[19], b'8' | b'9' | b'a' | b'b'));
        let plan = macshell_network_core::new_profile::prepare(
            macshell_network_core::new_profile::Input {
                ssid: b"synthetic",
                interface: "fake0",
                username: "tester",
                security: "open",
                uuid: &first,
                password: "",
            },
        )
        .unwrap();
        assert_eq!(plan.uuid, first);
    }
}
