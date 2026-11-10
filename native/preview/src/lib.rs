use serde_json::{json, Value};
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

pub const PROTOCOL: &str = "macshell-preview 1";

pub const IMAGE_MAX: u64 = 40 * 1024 * 1024;
pub const PDF_MAX: u64 = 40 * 1024 * 1024;
pub const TEXT_READ: usize = 256 * 1024;
const SNIFF: usize = 8192;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub image_max: u64,
    pub pdf_max: u64,
    pub text_read: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            image_max: IMAGE_MAX,
            pdf_max: PDF_MAX,
            text_read: TEXT_READ,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Image,
    Pdf,
    Text,
    Unsupported,
    Missing,
    Denied,
    TooLarge,
    Invalid,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Pdf => "pdf",
            Self::Text => "text",
            Self::Unsupported => "unsupported",
            Self::Missing => "missing",
            Self::Denied => "denied",
            Self::TooLarge => "too_large",
            Self::Invalid => "invalid",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inspect {
    pub kind: Kind,
    pub path: String,
    pub name: String,
    pub size: u64,
    pub mime: String,
    pub truncated: bool,
    pub text: String,
}

impl Inspect {
    fn blank(kind: Kind, path: &str) -> Self {
        Self {
            kind,
            path: path.to_string(),
            name: file_name(path),
            size: 0,
            mime: String::new(),
            truncated: false,
            text: String::new(),
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.kind.as_str(),
            "path": self.path,
            "name": self.name,
            "size": self.size,
            "mime": self.mime,
            "truncated": self.truncated,
            "text": self.text,
        })
    }
}

pub fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() < 4096
        && path.starts_with('/')
        && !path.contains('\0')
        && !path.contains('\n')
        && !path.contains('\r')
}

pub fn inspect(path: &str) -> Inspect {
    inspect_with(path, Limits::default())
}

pub fn inspect_with(path: &str, limits: Limits) -> Inspect {
    if !valid_path(path) {
        return Inspect::blank(Kind::Invalid, path);
    }
    let file_path = Path::new(path);
    let meta = match fs::metadata(file_path) {
        Ok(meta) => meta,
        Err(error) => return Inspect::blank(kind_from_io(&error), path),
    };
    if !meta.is_file() {
        return Inspect::blank(Kind::Missing, path);
    }
    let mut result = Inspect::blank(Kind::Unsupported, path);
    result.size = meta.len();
    let mut file = match File::open(file_path) {
        Ok(file) => file,
        Err(error) => {
            result.kind = kind_from_io(&error);
            return result;
        }
    };
    let sniff_len = SNIFF.min(result.size as usize);
    let mut sniff = vec![0u8; sniff_len];
    let read = match file.read(&mut sniff) {
        Ok(read) => read,
        Err(error) => {
            result.kind = kind_from_io(&error);
            return result;
        }
    };
    sniff.truncate(read);
    let class = classify(&sniff, file_path);
    match class {
        Class::Image(mime) => {
            if result.size > limits.image_max {
                result.kind = Kind::TooLarge;
            } else {
                result.kind = Kind::Image;
                result.mime = mime.to_string();
            }
        }
        Class::Pdf => {
            if result.size > limits.pdf_max {
                result.kind = Kind::TooLarge;
            } else {
                result.kind = Kind::Pdf;
                result.mime = "application/pdf".into();
            }
        }
        Class::Text => {
            let (text, truncated) = read_text(sniff, file, limits.text_read);
            result.kind = Kind::Text;
            result.mime = "text/plain".into();
            result.text = text;
            result.truncated = truncated;
        }
        Class::Unsupported => result.kind = Kind::Unsupported,
    }
    result
}

pub fn handle(action: &str, data: &Value) -> Value {
    match action {
        "inspect" => {
            let path = data.get("path").and_then(Value::as_str).unwrap_or("");
            json!({"success": true, "inspect": inspect(path).to_json()})
        }
        _ => json!({"success": false, "error": "Unknown action"}),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Class {
    Image(&'static str),
    Pdf,
    Text,
    Unsupported,
}

fn kind_from_io(error: &io::Error) -> Kind {
    match error.kind() {
        io::ErrorKind::NotFound => Kind::Missing,
        io::ErrorKind::PermissionDenied => Kind::Denied,
        _ => Kind::Missing,
    }
}

fn file_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| path.to_string())
}

fn extension(path: &Path) -> String {
    path.extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

fn classify(sniff: &[u8], path: &Path) -> Class {
    if let Some(mime) = image_mime(sniff) {
        return Class::Image(mime);
    }
    if sniff.starts_with(b"%PDF") {
        return Class::Pdf;
    }
    if looks_like_svg(sniff) {
        return Class::Image("image/svg+xml");
    }
    match extension(path).as_str() {
        "png" => Class::Image("image/png"),
        "jpg" | "jpeg" => Class::Image("image/jpeg"),
        "gif" => Class::Image("image/gif"),
        "webp" => Class::Image("image/webp"),
        "bmp" => Class::Image("image/bmp"),
        "svg" => Class::Image("image/svg+xml"),
        "ico" => Class::Image("image/x-icon"),
        "pdf" => Class::Pdf,
        ext if is_text_ext(ext) && is_text(sniff) => Class::Text,
        _ if is_text(sniff) => Class::Text,
        _ => Class::Unsupported,
    }
}

fn image_mime(sniff: &[u8]) -> Option<&'static str> {
    if sniff.len() >= 8 && sniff.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if sniff.len() >= 3 && sniff.starts_with(b"\xff\xd8\xff") {
        return Some("image/jpeg");
    }
    if sniff.starts_with(b"GIF87a") || sniff.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if sniff.len() >= 12 && sniff.starts_with(b"RIFF") && &sniff[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if sniff.starts_with(b"BM") {
        return Some("image/bmp");
    }
    if sniff.len() >= 4 && sniff.starts_with(b"\x00\x00\x01\x00") {
        return Some("image/x-icon");
    }
    None
}

fn looks_like_svg(sniff: &[u8]) -> bool {
    let start = match std::str::from_utf8(sniff) {
        Ok(text) => text,
        Err(error) if error.error_len().is_none() => {
            std::str::from_utf8(&sniff[..error.valid_up_to()]).unwrap_or("")
        }
        Err(_) => return false,
    };
    let trimmed = start.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    lower.starts_with("<svg") || (lower.starts_with("<?xml") && lower.contains("<svg"))
}

fn is_text_ext(ext: &str) -> bool {
    matches!(
        ext,
        "txt"
            | "md"
            | "markdown"
            | "json"
            | "xml"
            | "csv"
            | "log"
            | "html"
            | "htm"
            | "css"
            | "js"
            | "ts"
            | "rs"
            | "qml"
            | "py"
            | "toml"
            | "ini"
            | "cfg"
            | "conf"
            | "sh"
            | "bash"
            | "zsh"
            | "fish"
            | "yaml"
            | "yml"
            | "rst"
            | "org"
    )
}

fn is_text(sniff: &[u8]) -> bool {
    if sniff.contains(&0) {
        return false;
    }
    match std::str::from_utf8(sniff) {
        Ok(_) => true,
        Err(error) => error.error_len().is_none(),
    }
}

fn read_text(sniff: Vec<u8>, file: File, limit: usize) -> (String, bool) {
    let mut bytes = sniff;
    if bytes.len() < limit {
        let mut rest = Vec::new();
        let mut limited = file.take((limit - bytes.len()) as u64 + 1);
        let _ = limited.read_to_end(&mut rest);
        bytes.extend(rest);
    }
    let bom = bytes.starts_with(&[0xEF, 0xBB, 0xBF]);
    let body = if bom { &bytes[3..] } else { bytes.as_slice() };
    let truncated = body.len() > limit;
    let slice = if truncated { &body[..limit] } else { body };
    let (text, cut) = utf8_prefix(slice);
    (text, truncated || cut)
}

fn utf8_prefix(bytes: &[u8]) -> (String, bool) {
    match std::str::from_utf8(bytes) {
        Ok(text) => (text.to_string(), false),
        Err(error) => {
            let valid = error.valid_up_to();
            (
                std::str::from_utf8(&bytes[..valid])
                    .unwrap_or("")
                    .to_string(),
                true,
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static SEQ: AtomicU64 = AtomicU64::new(0);

    struct Temp(std::path::PathBuf);
    impl Temp {
        fn new(name: &str) -> Self {
            let n = SEQ.fetch_add(1, Ordering::Relaxed);
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "macshell-preview-{}-{}-{}-{name}",
                std::process::id(),
                now,
                n
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn write(path: &Path, bytes: &[u8]) {
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn rejects_relative_and_injected_paths() {
        assert_eq!(inspect("notes.txt").kind, Kind::Invalid);
        assert_eq!(inspect("/tmp/bad\npath").kind, Kind::Invalid);
        assert_eq!(inspect("").kind, Kind::Invalid);
        assert_eq!(inspect("file:///tmp/notes.txt").kind, Kind::Invalid);
        assert_eq!(handle("inspect", &json!({"path": "x"}))["inspect"]["kind"], "invalid");
        assert_eq!(handle("nope", &json!({}))["success"], false);
    }

    #[test]
    fn missing_and_directory_are_unavailable() {
        let dir = Temp::new("missing");
        let gone = dir.path().join("nope.txt");
        assert_eq!(inspect(gone.to_str().unwrap()).kind, Kind::Missing);
        assert_eq!(inspect(dir.path().to_str().unwrap()).kind, Kind::Missing);
    }

    #[test]
    fn classifies_images_pdf_and_text() {
        let dir = Temp::new("kinds");
        let png = dir.path().join("photo.png");
        let mut png_bytes = b"\x89PNG\r\n\x1a\n".to_vec();
        png_bytes.extend_from_slice(&[0u8; 16]);
        write(&png, &png_bytes);
        let pdf = dir.path().join("doc.pdf");
        write(&pdf, b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
        let text = dir.path().join("notes \u{444}\u{430}\u{439}\u{43b}.txt");
        write(&text, "hello \u{444}\u{430}\u{439}\u{43b}\n".as_bytes());
        let jpeg = dir.path().join("shot.jpg");
        write(&jpeg, b"\xff\xd8\xff\xe0\x00\x10JFIF");
        let svg = dir.path().join("mark.svg");
        write(&svg, b"<svg xmlns='http://www.w3.org/2000/svg'></svg>");

        let image = inspect(png.to_str().unwrap());
        assert_eq!(image.kind, Kind::Image);
        assert_eq!(image.mime, "image/png");
        assert_eq!(image.name, "photo.png");

        let doc = inspect(pdf.to_str().unwrap());
        assert_eq!(doc.kind, Kind::Pdf);
        assert_eq!(doc.mime, "application/pdf");

        let notes = inspect(text.to_str().unwrap());
        assert_eq!(notes.kind, Kind::Text);
        assert!(notes.text.contains("hello"));
        assert!(notes.text.contains("\u{444}"));
        assert_eq!(notes.truncated, false);

        assert_eq!(inspect(jpeg.to_str().unwrap()).mime, "image/jpeg");
        assert_eq!(inspect(svg.to_str().unwrap()).mime, "image/svg+xml");
    }

    #[test]
    fn utf8_text_without_extension_is_plain_text() {
        let dir = Temp::new("plain");
        let path = dir.path().join("README");
        write(&path, "plain notes".as_bytes());
        let result = inspect(path.to_str().unwrap());
        assert_eq!(result.kind, Kind::Text);
        assert_eq!(result.text, "plain notes");
    }

    #[test]
    fn binary_without_magic_is_unsupported() {
        let dir = Temp::new("bin");
        let path = dir.path().join("blob.bin");
        write(&path, b"\x00\x01\x02\xffbinary");
        assert_eq!(inspect(path.to_str().unwrap()).kind, Kind::Unsupported);
    }

    #[test]
    fn truncates_large_text_without_reading_the_rest() {
        let dir = Temp::new("trunc");
        let path = dir.path().join("long.txt");
        write(&path, "abcdefghijklmnop".as_bytes());
        let result = inspect_with(
            path.to_str().unwrap(),
            Limits {
                image_max: IMAGE_MAX,
                pdf_max: PDF_MAX,
                text_read: 8,
            },
        );
        assert_eq!(result.kind, Kind::Text);
        assert_eq!(result.text, "abcdefgh");
        assert_eq!(result.truncated, true);
        assert_eq!(result.size, 16);
    }

    #[test]
    fn oversized_image_is_too_large() {
        let dir = Temp::new("huge");
        let path = dir.path().join("big.png");
        let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
        bytes.extend_from_slice(&[1u8; 20]);
        write(&path, &bytes);
        let result = inspect_with(
            path.to_str().unwrap(),
            Limits {
                image_max: 16,
                pdf_max: PDF_MAX,
                text_read: TEXT_READ,
            },
        );
        assert_eq!(result.kind, Kind::TooLarge);
        assert!(result.size > 16);
    }

    #[test]
    fn permission_denied_is_reported() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let dir = Temp::new("deny");
        let path = dir.path().join("secret.txt");
        write(&path, b"hidden");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
        let result = inspect(path.to_str().unwrap());
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o644));
        assert_eq!(result.kind, Kind::Denied);
    }

    #[test]
    fn protocol_constant_matches_installer() {
        assert_eq!(PROTOCOL, "macshell-preview 1");
        let payload = handle("inspect", &json!({"path": "/no/such/file"}));
        assert_eq!(payload["success"], true);
        assert_eq!(payload["inspect"]["kind"], "missing");
    }
}
