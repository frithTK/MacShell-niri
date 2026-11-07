//! Private, operation-owned PNG storage for preview frames.
use crate::Frame;
use std::ffi::c_void;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

extern "C" {
    fn getrandom(buffer: *mut c_void, length: usize, flags: u32) -> isize;
}
pub struct Store {
    directory: PathBuf,
    serial: u64,
}
impl Store {
    /// Creates an exclusive 0700 directory under an existing runtime directory.
    pub fn new(parent: &Path) -> io::Result<Self> {
        if !parent.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid runtime directory",
            ));
        }
        let mut random = [0u8; 16];
        if unsafe { getrandom(random.as_mut_ptr().cast(), random.len(), 1) }
            != random.len() as isize
        {
            return Err(io::Error::other("Cannot create preview directory identity"));
        }
        let suffix: String = random.iter().map(|v| format!("{v:02x}")).collect();
        let directory = parent.join(format!("macshell-niri-{suffix}"));
        fs::DirBuilder::new().mode(0o700).create(&directory)?;
        Ok(Self {
            directory,
            serial: 0,
        })
    }
    /// Writes to a unique temporary path then atomically replaces one of three
    /// owned slots; no partially written PNG is published to the UI.
    pub fn write(&mut self, id: u64, frame: &Frame) -> io::Result<String> {
        if id == 0
            || !(1..=1024).contains(&frame.width)
            || !(1..=1024).contains(&frame.height)
            || frame.png.len() > 16 * 1024 * 1024
            || !frame.png.starts_with(b"\x89PNG\r\n\x1a\n")
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid preview frame",
            ));
        }
        let serial = self
            .serial
            .checked_add(1)
            .ok_or_else(|| io::Error::other("Preview sequence exhausted"))?;
        let slot = self.serial % 3;
        let temporary = self.directory.join(format!("{id}-{serial}.tmp"));
        let destination = self.directory.join(format!("{id}-{slot}.png"));
        let result: io::Result<()> = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&frame.png)?;
            drop(file);
            fs::rename(&temporary, &destination)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;
        self.serial = serial;
        Ok(file_url(&destination))
    }
    /// Remove only slots for the specified window in our private directory.
    pub fn remove(&self, id: u64) -> io::Result<()> {
        if id == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid window",
            ));
        }
        for slot in 0..3 {
            match fs::remove_file(self.directory.join(format!("{id}-{slot}.png"))) {
                Ok(()) => (),
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}
impl Drop for Store {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}
fn file_url(path: &Path) -> String {
    let mut result = String::from("file://");
    for b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(*b, b'/' | b'-' | b'_' | b'.' | b'~') {
            result.push(*b as char);
        } else {
            result.push_str(&format!("%{b:02X}"));
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn three_slots_are_private_and_cleanup_is_scoped() {
        let mut store = Store::new(&std::env::temp_dir()).unwrap();
        let dir = store.directory.clone();
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let frame = Frame {
            png: b"\x89PNG\r\n\x1a\nsynthetic".to_vec(),
            width: 1,
            height: 1,
        };
        for _ in 0..6 {
            assert!(store.write(7, &frame).unwrap().starts_with("file:///"));
        }
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 3);
        store.write(8, &frame).unwrap();
        store.remove(7).unwrap();
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        assert!(store.write(0, &frame).is_err());
        drop(store);
        assert!(!dir.exists());
    }
    #[test]
    fn url_encodes_spaces_and_non_ascii_bytes() {
        assert_eq!(
            file_url(Path::new("/tmp/hello world/тест.png")),
            "file:///tmp/hello%20world/%D1%82%D0%B5%D1%81%D1%82.png"
        );
    }
}
