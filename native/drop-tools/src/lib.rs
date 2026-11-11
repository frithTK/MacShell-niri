use image::{DynamicImage, ExtendedColorType, ImageEncoder};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use serde_json::{json, Value};
use std::env;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

pub const PROTOCOL: &str = "macshell-drop-tools 1";
pub const FILE_MAX: u64 = 40 * 1024 * 1024;
pub const DEFAULT_MAX_FILES: usize = 8;
const SNIFF: usize = 16;

#[derive(Clone, Debug)]
pub struct ToolEnv {
    pub pdftoppm: PathBuf,
    pub max_files: usize,
    pub max_bytes: u64,
}

impl ToolEnv {
    pub fn from_os() -> Self {
        let pdftoppm = env::var_os("MACSHELL_PDFTOPPM")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("pdftoppm"));
        Self {
            pdftoppm,
            max_files: DEFAULT_MAX_FILES,
            max_bytes: FILE_MAX,
        }
    }

    pub fn pdf_ready(&self) -> bool {
        tool_ok(&self.pdftoppm)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Image,
    Pdf,
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
            Self::Unsupported => "unsupported",
            Self::Missing => "missing",
            Self::Denied => "denied",
            Self::TooLarge => "too_large",
            Self::Invalid => "invalid",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Action {
    pub id: &'static str,
    pub available: bool,
    pub missing: &'static str,
}

impl Action {
    fn native(id: &'static str) -> Self {
        Self {
            id,
            available: true,
            missing: "",
        }
    }

    fn blocked(id: &'static str, missing: &'static str) -> Self {
        Self {
            id,
            available: false,
            missing,
        }
    }

    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "available": self.available,
            "missing": self.missing,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inspect {
    pub kind: Kind,
    pub path: String,
    pub name: String,
    pub size: u64,
    pub mime: String,
    pub actions: Vec<Action>,
}

impl Inspect {
    fn blank(kind: Kind, path: &str) -> Self {
        Self {
            kind,
            path: path.to_string(),
            name: file_name(path),
            size: 0,
            mime: String::new(),
            actions: Vec::new(),
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.kind.as_str(),
            "path": self.path,
            "name": self.name,
            "size": self.size,
            "mime": self.mime,
            "actions": self.actions.iter().map(Action::to_json).collect::<Vec<_>>(),
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

pub fn parse_file_arg(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() {
        return None;
    }
    let decoded = if let Some(rest) = value.strip_prefix("file://") {
        let path = if rest.starts_with('/') {
            rest
        } else {
            let slash = rest.find('/')?;
            &rest[slash..]
        };
        percent_decode(path)?
    } else {
        value.to_string()
    };
    valid_path(&decoded).then_some(decoded)
}

fn percent_decode(input: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(input.len());
    let raw = input.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        match raw[i] {
            b'%' if i + 2 < raw.len() => {
                let hi = from_hex(raw[i + 1])?;
                let lo = from_hex(raw[i + 2])?;
                bytes.push((hi << 4) | lo);
                i += 3;
            }
            byte => {
                bytes.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8(bytes).ok()
}

fn from_hex(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

pub fn resolve_op(kind: Kind, op: &str) -> Option<&'static str> {
    match (kind, op) {
        (Kind::Image, "png") => Some("png"),
        (Kind::Image, "jpeg") => Some("jpeg"),
        (Kind::Image, "pdf") => Some("pdf"),
        (Kind::Image, "rotate90") => Some("rotate90"),
        (Kind::Pdf, "png" | "pdf-png") => Some("pdf-png"),
        (Kind::Pdf, "jpeg" | "pdf-jpeg") => Some("pdf-jpeg"),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConvertArgs {
    pub op: String,
    pub notify: bool,
    pub paths: Vec<String>,
}

pub fn parse_convert_args(args: &[String]) -> Result<ConvertArgs, &'static str> {
    let mut op = String::new();
    let mut notify = false;
    let mut paths = Vec::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--notify" {
            notify = true;
        } else if arg == "--op" {
            index += 1;
            op = args.get(index).cloned().ok_or("missing_op")?;
        } else if let Some(value) = arg.strip_prefix("--op=") {
            op = value.to_string();
        } else if arg == "--" {
            for raw in &args[index + 1..] {
                if let Some(path) = parse_file_arg(raw) {
                    paths.push(path);
                }
            }
            break;
        } else if arg.starts_with('-') {
            return Err("unknown_flag");
        } else if let Some(path) = parse_file_arg(arg) {
            paths.push(path);
        }
        index += 1;
    }
    if !known_op(&op) {
        return Err("unknown_op");
    }
    if paths.is_empty() {
        return Err("missing_path");
    }
    Ok(ConvertArgs { op, notify, paths })
}

pub fn convert_from_args(args: &[String]) -> io::Result<i32> {
    let parsed = match parse_convert_args(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("macshell-drop-tools: {error}");
            if parsed_notify(args) {
                notify_convert(false, 0, 1, error);
            }
            return Ok(1);
        }
    };
    let env = ToolEnv::from_os();
    let payload = handle(
        "run",
        &json!({"op": parsed.op, "paths": parsed.paths}),
        &env,
        &AtomicBool::new(false),
    );
    let ok = payload.get("ok").and_then(Value::as_u64).unwrap_or(0);
    let failed = payload.get("failed").and_then(Value::as_u64).unwrap_or(0);
    let mut stdout = io::stdout();
    if let Some(results) = payload.get("results").and_then(Value::as_array) {
        for row in results {
            if let Some(dest) = row.get("dest").and_then(Value::as_str) {
                if !dest.is_empty() {
                    writeln!(stdout, "{dest}")?;
                }
            }
            if let Some(error) = row.get("error").and_then(Value::as_str) {
                if !error.is_empty() {
                    let path = row.get("path").and_then(Value::as_str).unwrap_or("");
                    eprintln!("macshell-drop-tools: {path}: {error}");
                }
            }
        }
    }
    stdout.flush()?;
    if parsed.notify {
        let summary = if failed == 0 {
            "done"
        } else if ok > 0 {
            "partial"
        } else {
            payload
                .get("results")
                .and_then(Value::as_array)
                .and_then(|rows| rows.first())
                .and_then(|row| row.get("error"))
                .and_then(Value::as_str)
                .unwrap_or("failed")
        };
        notify_convert(failed == 0, ok, failed, summary);
    }
    Ok(if failed == 0 { 0 } else { 1 })
}

fn parsed_notify(args: &[String]) -> bool {
    args.iter().any(|arg| arg == "--notify")
}

fn notify_convert(ok: bool, saved: u64, failed: u64, summary: &str) {
    let russian = env::var("LANG")
        .unwrap_or_default()
        .to_lowercase()
        .starts_with("ru");
    let title = if russian { "Конвертер" } else { "Convert" };
    let body = if ok {
        if russian {
            "Сохранено рядом с оригиналом"
        } else {
            "Saved next to the original"
        }
        .to_string()
    } else if saved > 0 {
        if russian {
            format!("Часть файлов преобразовать не удалось ({saved} ок, {failed} нет)")
        } else {
            format!("Some files could not be converted ({saved} ok, {failed} failed)")
        }
    } else if russian {
        notify_error_ru(summary).to_string()
    } else {
        notify_error_en(summary).to_string()
    };
    let _ = Command::new("notify-send")
        .args(["-a", "MacShell Convert", "-i", "image-x-generic", title, &body])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn notify_error_en(code: &str) -> &'static str {
    match code {
        "pdftoppm" => "PDF conversion needs pdftoppm",
        "unsupported" => "This file type cannot be converted",
        "missing" => "This file is not available",
        "denied" => "This file cannot be read",
        "too_large" => "This file is too large to convert",
        "invalid" | "missing_path" => "This location cannot be converted",
        "unknown_op" | "missing_op" | "unknown_flag" => "Unknown convert option",
        "decode" => "This file could not be decoded",
        "encode" => "Could not write the converted file",
        _ => "Conversion failed",
    }
}

fn notify_error_ru(code: &str) -> &'static str {
    match code {
        "pdftoppm" => "Для PDF нужен pdftoppm",
        "unsupported" => "Этот тип файла нельзя преобразовать",
        "missing" => "Файл недоступен",
        "denied" => "Файл нельзя прочитать",
        "too_large" => "Файл слишком большой для преобразования",
        "invalid" | "missing_path" => "Это расположение нельзя преобразовать",
        "unknown_op" | "missing_op" | "unknown_flag" => "Неизвестная команда преобразования",
        "decode" => "Файл не удалось прочитать",
        "encode" => "Не удалось записать результат",
        _ => "Преобразование не удалось",
    }
}

pub fn inspect(path: &str, env: &ToolEnv) -> Inspect {
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
    if result.size > env.max_bytes {
        result.kind = Kind::TooLarge;
        return result;
    }
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
    match classify(&sniff) {
        Class::Image(mime) => {
            result.kind = Kind::Image;
            result.mime = mime.to_string();
            result.actions = image_actions(mime);
        }
        Class::Pdf => {
            result.kind = Kind::Pdf;
            result.mime = "application/pdf".into();
            result.actions = pdf_actions(env.pdf_ready());
        }
        Class::Unsupported => result.kind = Kind::Unsupported,
    }
    result
}

pub fn handle(action: &str, data: &Value, env: &ToolEnv, cancel: &AtomicBool) -> Value {
    match action {
        "inspect" => {
            let path = data.get("path").and_then(Value::as_str).unwrap_or("");
            json!({"success": true, "inspect": inspect(path, env).to_json()})
        }
        "list" => list_payload(data, env),
        "run" => run_payload(data, env, cancel),
        "cancel" => json!({"success": true, "action": "cancel", "cancelled": true}),
        _ => json!({"success": false, "error": "Unknown action"}),
    }
}

pub fn run_payload(data: &Value, env: &ToolEnv, cancel: &AtomicBool) -> Value {
    let op = data.get("op").and_then(Value::as_str).unwrap_or("");
    if !known_op(op) {
        return json!({"success": false, "error": "unknown_op"});
    }
    let paths = request_paths(data);
    if paths.is_empty() {
        return json!({"success": false, "error": "missing_path"});
    }
    let mut results = Vec::new();
    let mut cancelled = false;
    for (index, path) in paths.iter().enumerate() {
        if index >= env.max_files {
            results.push(file_result(path, "", false, "limit"));
            continue;
        }
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            results.push(file_result(path, "", false, "cancelled"));
            continue;
        }
        match convert_one(path, op, env, cancel) {
            Ok(dest) => results.push(file_result(path, &dest, true, "")),
            Err("cancelled") => {
                cancelled = true;
                results.push(file_result(path, "", false, "cancelled"));
            }
            Err(error) => results.push(file_result(path, "", false, error)),
        }
    }
    let ok = results
        .iter()
        .filter(|row| row["success"] == true)
        .count();
    let failed = results.len() - ok;
    json!({
        "success": true,
        "cancelled": cancelled,
        "partial": ok > 0 && failed > 0,
        "ok": ok,
        "failed": failed,
        "results": results,
    })
}

fn list_payload(data: &Value, env: &ToolEnv) -> Value {
    let paths = request_paths(data);
    let mut files = Vec::new();
    let mut skipped = 0u64;
    for (index, path) in paths.iter().enumerate() {
        if index >= env.max_files {
            skipped += 1;
            continue;
        }
        files.push(inspect(path, env).to_json());
    }
    json!({"success": true, "files": files, "skipped": skipped})
}

fn request_paths(data: &Value) -> Vec<String> {
    if let Some(path) = data.get("path").and_then(Value::as_str) {
        if !path.is_empty() {
            return vec![path.to_string()];
        }
    }
    data.get("paths")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(Value::as_str)
                .filter(|path| !path.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn convert_one(path: &str, op: &str, env: &ToolEnv, cancel: &AtomicBool) -> Result<String, &'static str> {
    if cancel.load(Ordering::Relaxed) {
        return Err("cancelled");
    }
    let info = inspect(path, env);
    match info.kind {
        Kind::Invalid => return Err("invalid"),
        Kind::Missing => return Err("missing"),
        Kind::Denied => return Err("denied"),
        Kind::TooLarge => return Err("too_large"),
        Kind::Unsupported => return Err("unsupported"),
        Kind::Image | Kind::Pdf => {}
    }
    let op = resolve_op(info.kind, op).ok_or("unsupported")?;
    let action = info
        .actions
        .iter()
        .find(|row| row.id == op)
        .ok_or("unsupported")?;
    if !action.available {
        return Err(if action.missing.is_empty() {
            "unsupported"
        } else {
            action.missing
        });
    }
    let source = Path::new(path);
    match op {
        "png" | "jpeg" | "pdf" | "rotate90" => convert_image(source, op),
        "pdf-png" => render_pdf(source, env, false, "pdf-png", "png", cancel),
        "pdf-jpeg" => render_pdf(source, env, true, "pdf-jpeg", "jpg", cancel),
        _ => Err("unknown_op"),
    }
}

fn convert_image(source: &Path, op: &str) -> Result<String, &'static str> {
    let bytes = fs::read(source).map_err(|error| io_error(&error))?;
    let image = image::load_from_memory(&bytes).map_err(|_| "decode")?;
    let (tag, ext, payload) = match op {
        "png" => ("png", "png", encode_png(&image)?),
        "jpeg" => ("jpeg", "jpg", encode_jpeg(&image)?),
        "rotate90" => ("rotate90", "png", encode_png(&image.rotate90())?),
        "pdf" => {
            let jpeg = encode_jpeg(&image)?;
            (
                "pdf",
                "pdf",
                jpeg_as_pdf(&jpeg, image.width(), image.height()),
            )
        }
        _ => return Err("unknown_op"),
    };
    write_unique(source, tag, ext, &payload)
}

fn render_pdf(
    source: &Path,
    env: &ToolEnv,
    jpeg: bool,
    tag: &str,
    ext: &str,
    cancel: &AtomicBool,
) -> Result<String, &'static str> {
    if !env.pdf_ready() {
        return Err("pdftoppm");
    }
    if cancel.load(Ordering::Relaxed) {
        return Err("cancelled");
    }
    let dest = unique_dest(source, tag, ext)?;
    let parent = dest.parent().unwrap_or(Path::new("/"));
    let stem = dest
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("page");
    let prefix = parent.join(format!(".{stem}.macshell-page"));
    let flag = if jpeg { "-jpeg" } else { "-png" };
    let status = Command::new(&env.pdftoppm)
        .args([flag, "-f", "1", "-l", "1", "-singlefile"])
        .arg(source)
        .arg(&prefix)
        .status()
        .map_err(|_| "pdftoppm")?;
    let produced_png = appended(&prefix, "png");
    let produced_jpg = appended(&prefix, "jpg");
    let produced_jpeg = appended(&prefix, "jpeg");
    let produced = if jpeg {
        if produced_jpg.exists() {
            produced_jpg.clone()
        } else {
            produced_jpeg.clone()
        }
    } else {
        produced_png.clone()
    };
    let cleanup = || {
        let _ = fs::remove_file(&produced_png);
        let _ = fs::remove_file(&produced_jpg);
        let _ = fs::remove_file(&produced_jpeg);
    };
    if !status.success() || !produced.is_file() {
        cleanup();
        return Err("decode");
    }
    if let Err(error) = fs::rename(&produced, &dest) {
        cleanup();
        return Err(io_error(&error));
    }
    cleanup();
    Ok(dest.to_string_lossy().into_owned())
}

fn encode_png(image: &DynamicImage) -> Result<Vec<u8>, &'static str> {
    let rgba = image.to_rgba8();
    let mut buf = Vec::new();
    PngEncoder::new(&mut buf)
        .write_image(
            rgba.as_raw(),
            rgba.width(),
            rgba.height(),
            ExtendedColorType::Rgba8,
        )
        .map_err(|_| "encode")?;
    Ok(buf)
}

fn encode_jpeg(image: &DynamicImage) -> Result<Vec<u8>, &'static str> {
    let rgb = image.to_rgb8();
    let mut buf = Vec::new();
    JpegEncoder::new_with_quality(&mut buf, 85)
        .write_image(
            rgb.as_raw(),
            rgb.width(),
            rgb.height(),
            ExtendedColorType::Rgb8,
        )
        .map_err(|_| "encode")?;
    Ok(buf)
}

fn jpeg_as_pdf(jpeg: &[u8], width: u32, height: u32) -> Vec<u8> {
    let w = width.max(1);
    let h = height.max(1);
    let mut out = Vec::new();
    let mut offsets = [0u32; 6];
    out.extend_from_slice(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
    offsets[1] = out.len() as u32;
    out.extend_from_slice(b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    offsets[2] = out.len() as u32;
    out.extend_from_slice(b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
    offsets[3] = out.len() as u32;
    out.extend(
        format!(
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n"
        )
        .into_bytes(),
    );
    offsets[4] = out.len() as u32;
    out.extend(
        format!(
            "4 0 obj\n<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {} >>\nstream\n",
            jpeg.len()
        )
        .into_bytes(),
    );
    out.extend_from_slice(jpeg);
    out.extend_from_slice(b"\nendstream\nendobj\n");
    let content = format!("q {w} 0 0 {h} 0 0 cm /Im0 Do Q\n");
    offsets[5] = out.len() as u32;
    out.extend(
        format!(
            "5 0 obj\n<< /Length {} >>\nstream\n{}endstream\nendobj\n",
            content.len(),
            content
        )
        .into_bytes(),
    );
    let xref_at = out.len();
    let mut xref = String::from("xref\n0 6\n0000000000 65535 f \n");
    for offset in offsets.iter().skip(1) {
        xref.push_str(&format!("{offset:010} 00000 n \n"));
    }
    out.extend_from_slice(xref.as_bytes());
    out.extend(
        format!("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n").into_bytes(),
    );
    out
}

fn write_unique(source: &Path, tag: &str, ext: &str, bytes: &[u8]) -> Result<String, &'static str> {
    let dest = unique_dest(source, tag, ext)?;
    let tmp = dest.with_extension(format!(
        "{}.part",
        dest.extension().and_then(|value| value.to_str()).unwrap_or("tmp")
    ));
    if let Err(error) = fs::write(&tmp, bytes) {
        let _ = fs::remove_file(&tmp);
        return Err(io_error(&error));
    }
    if let Err(error) = fs::rename(&tmp, &dest) {
        let _ = fs::remove_file(&tmp);
        return Err(io_error(&error));
    }
    Ok(dest.to_string_lossy().into_owned())
}

fn appended(path: &Path, ext: &str) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "page".into());
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(format!("{name}.{ext}")),
        _ => PathBuf::from(format!("{name}.{ext}")),
    }
}

fn unique_dest(source: &Path, tag: &str, ext: &str) -> Result<PathBuf, &'static str> {
    let parent = source.parent().filter(|path| !path.as_os_str().is_empty()).unwrap_or(Path::new("/"));
    let stem = source
        .file_stem()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("file");
    for index in 0..100 {
        let name = if index == 0 {
            format!("{stem}-{tag}.{ext}")
        } else {
            format!("{stem}-{tag}-{index}.{ext}")
        };
        let dest = parent.join(name);
        if !dest.exists() {
            return Ok(dest);
        }
    }
    Err("name_conflict")
}

fn image_actions(mime: &str) -> Vec<Action> {
    let convertible = matches!(
        mime,
        "image/png" | "image/jpeg" | "image/gif" | "image/bmp"
    );
    let missing = if convertible { "" } else { "unsupported" };
    ["png", "jpeg", "pdf", "rotate90"]
        .into_iter()
        .map(|id| {
            if convertible {
                Action::native(id)
            } else {
                Action::blocked(id, missing)
            }
        })
        .collect()
}

fn pdf_actions(ready: bool) -> Vec<Action> {
    let missing = if ready { "" } else { "pdftoppm" };
    ["pdf-png", "pdf-jpeg"]
        .into_iter()
        .map(|id| {
            if ready {
                Action::native(id)
            } else {
                Action::blocked(id, missing)
            }
        })
        .collect()
}

fn known_op(op: &str) -> bool {
    matches!(
        op,
        "png" | "jpeg" | "pdf" | "rotate90" | "pdf-png" | "pdf-jpeg"
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Class {
    Image(&'static str),
    Pdf,
    Unsupported,
}

fn classify(sniff: &[u8]) -> Class {
    if sniff.len() >= 8 && sniff.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Class::Image("image/png");
    }
    if sniff.len() >= 3 && sniff.starts_with(b"\xff\xd8\xff") {
        return Class::Image("image/jpeg");
    }
    if sniff.starts_with(b"GIF87a") || sniff.starts_with(b"GIF89a") {
        return Class::Image("image/gif");
    }
    if sniff.len() >= 12 && sniff.starts_with(b"RIFF") && &sniff[8..12] == b"WEBP" {
        return Class::Image("image/webp");
    }
    if sniff.starts_with(b"BM") {
        return Class::Image("image/bmp");
    }
    if sniff.starts_with(b"%PDF") {
        return Class::Pdf;
    }
    Class::Unsupported
}

fn kind_from_io(error: &std::io::Error) -> Kind {
    match error.kind() {
        std::io::ErrorKind::NotFound => Kind::Missing,
        std::io::ErrorKind::PermissionDenied => Kind::Denied,
        _ => Kind::Missing,
    }
}

fn io_error(error: &std::io::Error) -> &'static str {
    match error.kind() {
        std::io::ErrorKind::PermissionDenied => "denied",
        std::io::ErrorKind::NotFound => "missing",
        _ => "failed",
    }
}

fn file_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| path.to_string())
}

fn file_result(path: &str, dest: &str, success: bool, error: &str) -> Value {
    json!({
        "path": path,
        "dest": dest,
        "success": success,
        "error": error,
    })
}

fn tool_ok(program: &Path) -> bool {
    if program.as_os_str().is_empty() {
        return false;
    }
    let has_sep = program
        .components()
        .nth(1)
        .is_some()
        || program.is_absolute();
    if has_sep {
        return is_exec(program);
    }
    let Some(paths) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&paths).any(|dir| is_exec(&dir.join(program)))
}

fn is_exec(path: &Path) -> bool {
    match fs::metadata(path) {
        Ok(meta) => meta.is_file() && meta.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage};
    use std::sync::atomic::AtomicBool;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Temp(PathBuf);

    impl Temp {
        fn new(name: &str) -> Self {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = env::temp_dir().join(format!("macshell-drop-tools-{name}-{stamp}"));
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

    fn env_with(pdftoppm: PathBuf) -> ToolEnv {
        ToolEnv {
            pdftoppm,
            max_files: DEFAULT_MAX_FILES,
            max_bytes: FILE_MAX,
        }
    }

    fn idle() -> AtomicBool {
        AtomicBool::new(false)
    }

    fn save_png(path: &Path, r: u8, g: u8, b: u8) {
        RgbImage::from_pixel(2, 2, Rgb([r, g, b]))
            .save(path)
            .unwrap();
    }

    fn save_jpeg(path: &Path) {
        let image = DynamicImage::ImageRgb8(RgbImage::from_pixel(2, 2, Rgb([10, 20, 30])));
        fs::write(path, encode_jpeg(&image).unwrap()).unwrap();
    }

    fn fake_pdftoppm(dir: &Path, png: &Path, jpeg: &Path) -> PathBuf {
        let script = dir.join("pdftoppm");
        let body = format!(
            "#!/bin/sh\njpeg=0\nprefix=\"\"\nfor a in \"$@\"; do\n  [ \"$a\" = \"-jpeg\" ] && jpeg=1\n  prefix=\"$a\"\ndone\nif [ \"$jpeg\" = 1 ]; then cp \"{}\" \"$prefix.jpg\"; else cp \"{}\" \"$prefix.png\"; fi\n",
            jpeg.display(),
            png.display()
        );
        fs::write(&script, body).unwrap();
        let mut perm = fs::metadata(&script).unwrap().permissions();
        perm.set_mode(0o755);
        fs::set_permissions(&script, perm).unwrap();
        script
    }

    #[test]
    fn sniffs_jpeg_without_extension() {
        let dir = Temp::new("sniff");
        let path = dir.path().join("shot.bin");
        save_jpeg(&path);
        let info = inspect(path.to_str().unwrap(), &env_with(PathBuf::from("/missing")));
        assert_eq!(info.kind, Kind::Image);
        assert_eq!(info.mime, "image/jpeg");
        assert!(info.actions.iter().any(|row| row.id == "png" && row.available));
    }

    #[test]
    fn converts_png_to_jpeg_beside_original() {
        let dir = Temp::new("jpeg");
        let source = dir.path().join("photo.png");
        save_png(&source, 255, 0, 0);
        let original = fs::read(&source).unwrap();
        let payload = handle(
            "run",
            &json!({"path": source.to_str().unwrap(), "op": "png"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        // converting png→png still writes a new sibling
        assert_eq!(payload["ok"], 1);
        let dest = payload["results"][0]["dest"].as_str().unwrap();
        assert!(dest.ends_with("/photo-png.png"));
        assert_ne!(fs::read(dest).unwrap(), original);
        assert_eq!(fs::read(&source).unwrap(), original);

        let jpeg = handle(
            "run",
            &json!({"path": source.to_str().unwrap(), "op": "jpeg"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        let jpeg_dest = PathBuf::from(jpeg["results"][0]["dest"].as_str().unwrap());
        let bytes = fs::read(&jpeg_dest).unwrap();
        assert!(bytes.starts_with(b"\xff\xd8\xff"));
        assert_eq!(fs::read(&source).unwrap(), original);
    }

    #[test]
    fn wraps_image_as_pdf_and_rotates() {
        let dir = Temp::new("pdf");
        let source = dir.path().join("mark.png");
        save_png(&source, 0, 255, 0);
        let pdf = handle(
            "run",
            &json!({"path": source.to_str().unwrap(), "op": "pdf"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        let dest = PathBuf::from(pdf["results"][0]["dest"].as_str().unwrap());
        let bytes = fs::read(&dest).unwrap();
        assert!(bytes.starts_with(b"%PDF-1.4"));
        assert!(bytes.windows(10).any(|chunk| chunk == b"/DCTDecode"));

        let rotated = handle(
            "run",
            &json!({"path": source.to_str().unwrap(), "op": "rotate90"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        let rotated_path = PathBuf::from(rotated["results"][0]["dest"].as_str().unwrap());
        assert!(rotated_path
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("mark-rotate90"));
        let image = image::open(&rotated_path).unwrap();
        assert_eq!(image.width(), 2);
        assert_eq!(image.height(), 2);
    }

    #[test]
    fn name_conflict_gets_a_numeric_suffix() {
        let dir = Temp::new("conflict");
        let source = dir.path().join("photo.png");
        save_png(&source, 1, 2, 3);
        fs::write(dir.path().join("photo-png.png"), b"taken").unwrap();
        let payload = handle(
            "run",
            &json!({"path": source.to_str().unwrap(), "op": "png"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        assert_eq!(payload["results"][0]["dest"], json!(dir.path().join("photo-png-1.png").to_str().unwrap()));
        assert_eq!(fs::read(dir.path().join("photo-png.png")).unwrap(), b"taken");
    }

    #[test]
    fn corrupt_jpeg_reports_decode() {
        let dir = Temp::new("bad");
        let path = dir.path().join("broken.jpg");
        fs::write(&path, b"\xff\xd8\xff\xe0not-a-jpeg").unwrap();
        let payload = handle(
            "run",
            &json!({"path": path.to_str().unwrap(), "op": "png"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        assert_eq!(payload["ok"], 0);
        assert_eq!(payload["results"][0]["error"], "decode");
        assert!(path.exists());
    }

    #[test]
    fn cancel_stops_remaining_files() {
        let dir = Temp::new("cancel");
        let first = dir.path().join("a.png");
        let second = dir.path().join("b.png");
        save_png(&first, 9, 9, 9);
        save_png(&second, 8, 8, 8);
        let cancel = AtomicBool::new(true);
        let payload = handle(
            "run",
            &json!({"paths": [first.to_str().unwrap(), second.to_str().unwrap()], "op": "png"}),
            &env_with(PathBuf::from("/missing")),
            &cancel,
        );
        assert_eq!(payload["cancelled"], true);
        assert_eq!(payload["ok"], 0);
        assert_eq!(payload["results"][0]["error"], "cancelled");
        assert!(!dir.path().join("a-png.png").exists());
    }

    #[test]
    fn pdf_actions_require_pdftoppm_and_render_first_page() {
        let dir = Temp::new("pdf-tool");
        let pdf = dir.path().join("doc.pdf");
        fs::write(&pdf, b"%PDF-1.4\n1 0 obj<<>>endobj\n").unwrap();
        let missing = inspect(pdf.to_str().unwrap(), &env_with(PathBuf::from("/no/pdftoppm")));
        assert_eq!(missing.kind, Kind::Pdf);
        assert!(missing
            .actions
            .iter()
            .all(|row| !row.available && row.missing == "pdftoppm"));

        let png = dir.path().join("page.png");
        let jpeg = dir.path().join("page.jpg");
        save_png(&png, 4, 5, 6);
        save_jpeg(&jpeg);
        let tool = fake_pdftoppm(dir.path(), &png, &jpeg);
        let env = env_with(tool);
        let ready = inspect(pdf.to_str().unwrap(), &env);
        assert!(ready.actions.iter().all(|row| row.available));
        let payload = handle(
            "run",
            &json!({"path": pdf.to_str().unwrap(), "op": "pdf-png"}),
            &env,
            &idle(),
        );
        assert_eq!(payload["ok"], 1);
        let dest = PathBuf::from(payload["results"][0]["dest"].as_str().unwrap());
        assert!(dest.file_name().unwrap().to_str().unwrap().starts_with("doc-pdf-png"));
        assert!(image::open(&dest).is_ok());
        assert!(pdf.exists());

        let aliased = handle(
            "run",
            &json!({"path": pdf.to_str().unwrap(), "op": "png"}),
            &env,
            &idle(),
        );
        assert_eq!(aliased["ok"], 1);
        let aliased_dest = PathBuf::from(aliased["results"][0]["dest"].as_str().unwrap());
        assert!(aliased_dest
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("doc-pdf-png"));
    }

    #[test]
    fn cli_paths_decode_file_uris_and_map_pdf_ops() {
        assert_eq!(
            parse_file_arg("file:///tmp/Notes%201.png").as_deref(),
            Some("/tmp/Notes 1.png")
        );
        assert_eq!(parse_file_arg("/tmp/файл.jpg").as_deref(), Some("/tmp/файл.jpg"));
        assert_eq!(parse_file_arg("relative.png"), None);
        assert_eq!(resolve_op(Kind::Pdf, "jpeg"), Some("pdf-jpeg"));
        assert_eq!(resolve_op(Kind::Image, "png"), Some("png"));
        assert_eq!(resolve_op(Kind::Pdf, "rotate90"), None);
        let parsed = parse_convert_args(&[
            "--notify".into(),
            "--op".into(),
            "png".into(),
            "file:///tmp/a.png".into(),
            "/tmp/b.jpg".into(),
        ])
        .unwrap();
        assert_eq!(parsed.op, "png");
        assert!(parsed.notify);
        assert_eq!(parsed.paths, vec!["/tmp/a.png", "/tmp/b.jpg"]);
        assert_eq!(
            parse_convert_args(&["--op".into(), "webp".into(), "/tmp/a.png".into()]),
            Err("unknown_op")
        );

        let dir = Temp::new("cli");
        let source = dir.path().join("shot.png");
        save_png(&source, 3, 4, 5);
        let code = convert_from_args(&[
            "--op".into(),
            "jpeg".into(),
            source.to_str().unwrap().into(),
        ])
        .unwrap();
        assert_eq!(code, 0);
        assert!(dir.path().join("shot-jpeg.jpg").is_file());
    }

    #[test]
    fn batch_reports_partial_success() {
        let dir = Temp::new("batch");
        let good = dir.path().join("ok.png");
        let bad = dir.path().join("nope.bin");
        save_png(&good, 1, 1, 1);
        fs::write(&bad, b"\x00\x01\x02").unwrap();
        let payload = handle(
            "run",
            &json!({"paths": [good.to_str().unwrap(), bad.to_str().unwrap()], "op": "png"}),
            &env_with(PathBuf::from("/missing")),
            &idle(),
        );
        assert_eq!(payload["partial"], true);
        assert_eq!(payload["ok"], 1);
        assert_eq!(payload["failed"], 1);
        assert_eq!(payload["results"][1]["error"], "unsupported");
    }

    #[test]
    fn protocol_constant_matches_installer() {
        assert_eq!(PROTOCOL, "macshell-drop-tools 1");
        let payload = handle("inspect", &json!({"path": "/no/such"}), &env_with(PathBuf::from("/x")), &idle());
        assert_eq!(payload["inspect"]["kind"], "missing");
    }
}
