use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const PROTOCOL: &str = "macshell-cursor-pointer 1";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CursorImage {
    pub width: u32,
    pub height: u32,
    pub hot_x: u32,
    pub hot_y: u32,
    pub pixels: Vec<u8>,
}

pub fn nominal_size() -> u32 {
    if let Ok(raw) = std::env::var("XCURSOR_SIZE") {
        if let Ok(size) = raw.trim().parse::<u32>() {
            return size.clamp(16, 128);
        }
    }
    if let Some(size) = gsettings("cursor-size").and_then(|text| text.parse::<u32>().ok()) {
        return size.clamp(16, 128);
    }
    24
}

pub fn theme_name() -> String {
    if let Ok(theme) = std::env::var("XCURSOR_THEME") {
        let theme = theme.trim();
        if !theme.is_empty() {
            return theme.to_string();
        }
    }
    gsettings("cursor-theme").unwrap_or_else(|| "capitaine-cursors".to_string())
}

fn gsettings(key: &str) -> Option<String> {
    let output = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", key])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let text = text.trim().trim_matches(|ch| ch == '\'' || ch == '"');
    if text.is_empty() || text == "null" {
        None
    } else {
        Some(text.to_string())
    }
}

fn icon_roots() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let mut roots = Vec::new();
    if let Ok(extra) = std::env::var("XCURSOR_PATH") {
        roots.extend(
            extra
                .split(':')
                .filter(|part| !part.is_empty())
                .map(PathBuf::from),
        );
    }
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/share"));
    roots.push(data.join("icons"));
    roots.push(home.join(".icons"));
    roots.push(PathBuf::from("/usr/local/share/icons"));
    roots.push(PathBuf::from("/usr/share/icons"));
    roots
}

pub fn find_cursor(theme: &str, name: &str) -> Option<PathBuf> {
    find_cursor_seen(theme, name, &mut Vec::new())
}

fn find_cursor_seen(theme: &str, name: &str, seen: &mut Vec<String>) -> Option<PathBuf> {
    if seen.iter().any(|item| item == theme) {
        return None;
    }
    seen.push(theme.to_string());
    for root in icon_roots() {
        let path = root.join(theme).join("cursors").join(name);
        if path.is_file() {
            return Some(path);
        }
    }
    for root in icon_roots() {
        let index = root.join(theme).join("index.theme");
        let Ok(text) = fs::read_to_string(&index) else {
            continue;
        };
        for line in text.lines() {
            let Some(parents) = line.strip_prefix("Inherits=") else {
                continue;
            };
            for parent in parents.split(',') {
                if let Some(found) = find_cursor_seen(parent.trim(), name, seen) {
                    return Some(found);
                }
            }
        }
    }
    None
}

pub fn largest_image(data: &[u8]) -> Option<CursorImage> {
    if data.len() < 16 {
        return None;
    }
    let magic = u32::from_le_bytes(data[0..4].try_into().ok()?);
    let header = u32::from_le_bytes(data[4..8].try_into().ok()?) as usize;
    let count = u32::from_le_bytes(data[12..16].try_into().ok()?) as usize;
    if magic != 0x7275_6358 || header < 16 || header + count * 12 > data.len() {
        return None;
    }
    let mut best: Option<CursorImage> = None;
    for index in 0..count {
        let at = header + index * 12;
        let kind = u32::from_le_bytes(data[at..at + 4].try_into().ok()?);
        let position = u32::from_le_bytes(data[at + 8..at + 12].try_into().ok()?) as usize;
        if kind != 0xfffd_0002 || position + 36 > data.len() {
            continue;
        }
        let chunk = u32::from_le_bytes(data[position..position + 4].try_into().ok()?) as usize;
        let width = u32::from_le_bytes(data[position + 16..position + 20].try_into().ok()?);
        let height = u32::from_le_bytes(data[position + 20..position + 24].try_into().ok()?);
        let hot_x = u32::from_le_bytes(data[position + 24..position + 28].try_into().ok()?);
        let hot_y = u32::from_le_bytes(data[position + 28..position + 32].try_into().ok()?);
        let nbytes = (width as usize)
            .checked_mul(height as usize)?
            .checked_mul(4)?;
        let start = position.checked_add(chunk)?;
        if !(1..=512).contains(&width)
            || !(1..=512).contains(&height)
            || start + nbytes > data.len()
        {
            continue;
        }
        let pixels = data[start..start + nbytes].to_vec();
        let replace = best
            .as_ref()
            .is_none_or(|image| width * height > image.width * image.height);
        if replace {
            best = Some(CursorImage {
                width,
                height,
                hot_x,
                hot_y,
                pixels,
            });
        }
    }
    best
}

pub fn straight_rgba(image: &CursorImage) -> Vec<u8> {
    let mut raw = Vec::with_capacity((image.width * image.height * 4 + image.height) as usize);
    for y in 0..image.height {
        raw.push(0);
        let row = (y * image.width * 4) as usize;
        for x in 0..image.width {
            let pixel = u32::from_le_bytes(
                image.pixels[row + x as usize * 4..row + x as usize * 4 + 4]
                    .try_into()
                    .unwrap(),
            );
            let alpha = ((pixel >> 24) & 255) as u32;
            let mut red = (pixel >> 16) & 255;
            let mut green = (pixel >> 8) & 255;
            let mut blue = pixel & 255;
            if alpha == 0 {
                red = 0;
                green = 0;
                blue = 0;
            } else if alpha < 255 {
                red = (red * 255 + alpha / 2) / alpha;
                green = (green * 255 + alpha / 2) / alpha;
                blue = (blue * 255 + alpha / 2) / alpha;
            }
            raw.extend([red as u8, green as u8, blue as u8, alpha as u8]);
        }
    }
    raw
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for byte in data {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

fn adler32(data: &[u8]) -> u32 {
    let mut a = 1u32;
    let mut b = 0u32;
    for byte in data {
        a = (a + u32::from(*byte)) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn stored_zlib(data: &[u8]) -> Vec<u8> {
    let mut zlib = vec![0x78, 0x01];
    let mut offset = 0;
    while offset < data.len() || (data.is_empty() && zlib.len() == 2) {
        let end = (offset + 65535).min(data.len());
        let last = end == data.len();
        zlib.push(if last { 1 } else { 0 });
        let len = (end - offset) as u16;
        zlib.extend(len.to_le_bytes());
        zlib.extend((!len).to_le_bytes());
        zlib.extend(&data[offset..end]);
        offset = end;
        if data.is_empty() {
            break;
        }
    }
    zlib.extend(adler32(data).to_be_bytes());
    zlib
}

fn png_chunk(tag: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut chunk = (payload.len() as u32).to_be_bytes().to_vec();
    chunk.extend(tag);
    chunk.extend(payload);
    let crc = crc32(&chunk[4..]);
    chunk.extend(crc.to_be_bytes());
    chunk
}

pub fn png(width: u32, height: u32, raw: &[u8]) -> Vec<u8> {
    let mut file = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
    let mut ihdr = Vec::new();
    ihdr.extend(width.to_be_bytes());
    ihdr.extend(height.to_be_bytes());
    ihdr.extend([8, 6, 0, 0, 0]);
    file.extend(png_chunk(b"IHDR", &ihdr));
    file.extend(png_chunk(b"IDAT", &stored_zlib(raw)));
    file.extend(png_chunk(b"IEND", &[]));
    file
}

pub fn image_line(cache: &Path) -> io::Result<String> {
    let nominal = nominal_size();
    let Some(path) = find_cursor(&theme_name(), "left_ptr") else {
        return Ok(format!("image - 0 0 0 {nominal}"));
    };
    let data = fs::read(path)?;
    let Some(image) = largest_image(&data) else {
        return Ok(format!("image - 0 0 0 {nominal}"));
    };
    fs::create_dir_all(cache)?;
    let destination = cache.join("cursor-grow.png");
    let temporary = cache.join("cursor-grow.png.tmp");
    let encoded = png(image.width, image.height, &straight_rgba(&image));
    fs::write(&temporary, encoded)?;
    fs::rename(&temporary, &destination)?;
    let shown = destination.to_string_lossy();
    if shown.contains(' ') {
        return Ok(format!("image - 0 0 0 {nominal}"));
    }
    Ok(format!(
        "image {shown} {} {} {} {nominal}",
        image.hot_x, image.hot_y, image.width
    ))
}

pub fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".cache")
        })
}

struct BusMessage {
    kind: u8,
    reply_serial: Option<u32>,
    member: String,
    signature: String,
    body: Vec<u8>,
}

fn pad(buf: &mut Vec<u8>, align: usize) {
    while buf.len() % align != 0 {
        buf.push(0);
    }
}

fn write_string(buf: &mut Vec<u8>, text: &str) {
    pad(buf, 4);
    buf.extend((text.len() as u32).to_le_bytes());
    buf.extend(text.as_bytes());
    buf.push(0);
}

fn write_field(buf: &mut Vec<u8>, code: u8, signature: &str, value: &[u8]) {
    pad(buf, 8);
    buf.push(code);
    buf.push(signature.len() as u8);
    buf.extend(signature.as_bytes());
    buf.push(0);
    buf.extend(value);
}

fn string_field(text: &str) -> Vec<u8> {
    let mut value = Vec::new();
    write_string(&mut value, text);
    value
}

fn encode_call(
    serial: u32,
    destination: &str,
    path: &str,
    interface: &str,
    member: &str,
    signature: &str,
    body: &[u8],
) -> Vec<u8> {
    let mut buf = vec![b'l', 1, 0, 1];
    buf.extend((body.len() as u32).to_le_bytes());
    buf.extend(serial.to_le_bytes());
    let length_at = buf.len();
    buf.extend(0u32.to_le_bytes());
    let data_at = buf.len();
    write_field(&mut buf, 6, "s", &string_field(destination));
    write_field(&mut buf, 1, "o", &string_field(path));
    write_field(&mut buf, 2, "s", &string_field(interface));
    write_field(&mut buf, 3, "s", &string_field(member));
    if !signature.is_empty() {
        let mut sig = vec![signature.len() as u8];
        sig.extend(signature.as_bytes());
        sig.push(0);
        write_field(&mut buf, 8, "g", &sig);
    }
    let data_len = (buf.len() - data_at) as u32;
    buf[length_at..length_at + 4].copy_from_slice(&data_len.to_le_bytes());
    pad(&mut buf, 8);
    buf.extend(body);
    buf
}

fn align_to(pos: usize, align: usize) -> usize {
    pos.div_ceil(align) * align
}

fn read_u32(buf: &[u8], pos: usize) -> io::Result<(u32, usize)> {
    let pos = align_to(pos, 4);
    let bytes = buf
        .get(pos..pos + 4)
        .ok_or_else(|| io::Error::other("short dbus value"))?;
    Ok((u32::from_le_bytes(bytes.try_into().unwrap()), pos + 4))
}

fn read_text(buf: &[u8], pos: usize, max: usize) -> io::Result<(String, usize)> {
    let (len, pos) = read_u32(buf, pos)?;
    if len as usize > max {
        return Err(io::Error::other("dbus text is too long"));
    }
    let end = pos + len as usize;
    let bytes = buf
        .get(pos..end)
        .ok_or_else(|| io::Error::other("short dbus text"))?;
    if buf.get(end) != Some(&0) {
        return Err(io::Error::other("dbus text is not terminated"));
    }
    Ok((String::from_utf8_lossy(bytes).into_owned(), end + 1))
}

fn decode_message(buf: &[u8]) -> io::Result<BusMessage> {
    if buf.len() < 16 || buf[0] != b'l' || buf[3] != 1 {
        return Err(io::Error::other("unsupported dbus message"));
    }
    let fields_len = u32::from_le_bytes(buf[12..16].try_into().unwrap()) as usize;
    if fields_len > 65_536 || 16 + fields_len > buf.len() {
        return Err(io::Error::other("dbus header is too large"));
    }
    let mut pos = 16;
    let end = 16 + fields_len;
    let mut reply_serial = None;
    let mut member = String::new();
    let mut signature = String::new();
    while pos < end {
        pos = align_to(pos, 8);
        if pos >= end {
            break;
        }
        let code = buf[pos];
        pos += 1;
        let sig_len = *buf
            .get(pos)
            .ok_or_else(|| io::Error::other("short dbus field"))? as usize;
        pos += 1;
        let sig = buf
            .get(pos..pos + sig_len)
            .ok_or_else(|| io::Error::other("short dbus signature"))?;
        pos += sig_len + 1;
        match sig {
            b"s" | b"o" => {
                let (text, next) = read_text(buf, pos, 4096)?;
                if code == 3 {
                    member = text;
                }
                pos = next;
            }
            b"g" => {
                let len = *buf
                    .get(pos)
                    .ok_or_else(|| io::Error::other("short signature"))?
                    as usize;
                pos += 1;
                let text = buf
                    .get(pos..pos + len)
                    .ok_or_else(|| io::Error::other("short signature"))?;
                if code == 8 {
                    signature = String::from_utf8_lossy(text).into_owned();
                }
                pos += len + 1;
            }
            b"u" => {
                let (value, next) = read_u32(buf, pos)?;
                if code == 5 {
                    reply_serial = Some(value);
                }
                pos = next;
            }
            _ => return Err(io::Error::other("unsupported dbus header")),
        }
    }
    let body_at = align_to(end, 8);
    let body = buf.get(body_at..).unwrap_or_default().to_vec();
    Ok(BusMessage {
        kind: buf[1],
        reply_serial,
        member,
        signature,
        body,
    })
}

pub fn pointer_xy(body: &[u8]) -> io::Result<(f64, f64)> {
    let (len, mut pos) = read_u32(body, 0)?;
    pos += len as usize;
    if pos > body.len() {
        return Err(io::Error::other("pointer reply is short"));
    }
    pos = align_to(pos, 8);
    let x = body
        .get(pos..pos + 8)
        .ok_or_else(|| io::Error::other("pointer x is missing"))?;
    pos = align_to(pos + 8, 8);
    let y = body
        .get(pos..pos + 8)
        .ok_or_else(|| io::Error::other("pointer y is missing"))?;
    Ok((
        f64::from_le_bytes(x.try_into().unwrap()),
        f64::from_le_bytes(y.try_into().unwrap()),
    ))
}

fn uid() -> io::Result<u32> {
    let status = fs::read_to_string("/proc/self/status")?;
    for line in status.lines() {
        let Some(rest) = line.strip_prefix("Uid:") else {
            continue;
        };
        let first = rest.split_whitespace().next().unwrap_or("");
        return first
            .parse()
            .map_err(|_| io::Error::other("uid is not a number"));
    }
    Err(io::Error::other("uid is unavailable"))
}

fn hex_uid(uid: u32) -> String {
    uid.to_string()
        .bytes()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn connect_bus() -> io::Result<std::os::unix::net::UnixStream> {
    let address = std::env::var("DBUS_SESSION_BUS_ADDRESS")
        .map_err(|_| io::Error::other("session bus is unavailable"))?;
    let first = address.split(',').next().unwrap_or("");
    if let Some(path) = first.strip_prefix("unix:path=") {
        return std::os::unix::net::UnixStream::connect(path);
    }
    if let Some(name) = first.strip_prefix("unix:abstract=") {
        let addr = <std::os::unix::net::SocketAddr as std::os::linux::net::SocketAddrExt>::from_abstract_name(name.as_bytes())?;
        return std::os::unix::net::UnixStream::connect_addr(&addr);
    }
    Err(io::Error::other("session bus address is unsupported"))
}

fn read_line(stream: &mut std::os::unix::net::UnixStream) -> io::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        stream.read_exact(&mut byte)?;
        if byte[0] == b'\n' {
            break;
        }
        if line.len() > 512 {
            return Err(io::Error::other("dbus greeting is too long"));
        }
        if byte[0] != b'\r' {
            line.push(byte[0]);
        }
    }
    Ok(String::from_utf8_lossy(&line).into_owned())
}

fn authenticate(stream: &mut std::os::unix::net::UnixStream) -> io::Result<()> {
    stream.write_all(&[0])?;
    let auth = format!("AUTH EXTERNAL {}\r\n", hex_uid(uid()?));
    stream.write_all(auth.as_bytes())?;
    let reply = read_line(stream)?;
    if !reply.starts_with("OK") {
        return Err(io::Error::other("dbus authentication failed"));
    }
    stream.write_all(b"BEGIN\r\n")?;
    Ok(())
}

fn read_message(stream: &mut std::os::unix::net::UnixStream) -> io::Result<BusMessage> {
    let mut head = [0u8; 16];
    stream.read_exact(&mut head)?;
    let body_len = u32::from_le_bytes(head[4..8].try_into().unwrap()) as usize;
    let fields_len = u32::from_le_bytes(head[12..16].try_into().unwrap()) as usize;
    if body_len > 262_144 || fields_len > 65_536 {
        return Err(io::Error::other("dbus message is too large"));
    }
    let header = align_to(16 + fields_len, 8);
    let mut buf = vec![0u8; header + body_len];
    buf[..16].copy_from_slice(&head);
    stream.read_exact(&mut buf[16..])?;
    decode_message(&buf)
}

fn call(
    stream: &mut std::os::unix::net::UnixStream,
    serial: u32,
    destination: &str,
    path: &str,
    interface: &str,
    member: &str,
    signature: &str,
    body: &[u8],
) -> io::Result<BusMessage> {
    stream.write_all(&encode_call(
        serial,
        destination,
        path,
        interface,
        member,
        signature,
        body,
    ))?;
    loop {
        let message = read_message(stream)?;
        if message.reply_serial == Some(serial) {
            return Ok(message);
        }
    }
}

pub fn watch(output: &mut impl Write, once: bool) -> io::Result<()> {
    writeln!(output, "{}", image_line(&cache_dir())?)?;
    output.flush()?;
    let mut stream = connect_bus()?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    authenticate(&mut stream)?;
    let hello = call(
        &mut stream,
        1,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
        "",
        &[],
    )?;
    if hello.kind != 2 {
        return Err(io::Error::other("dbus hello failed"));
    }
    let rule = "type='signal',interface='org.freedesktop.a11y.PointerLocator',member='PointerPositionChanged',path='/org/freedesktop/a11y/Manager'";
    let mut body = Vec::new();
    write_string(&mut body, rule);
    let matched = call(
        &mut stream,
        2,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "AddMatch",
        "s",
        &body,
    )?;
    if matched.kind != 2 {
        return Err(io::Error::other("dbus match failed"));
    }
    let mut serial = 3u32;
    let mut last = Instant::now() - Duration::from_millis(16);
    if once {
        query_pointer(output, &mut stream, serial)?;
        return Ok(());
    }
    stream.set_read_timeout(None)?;
    loop {
        let message = read_message(&mut stream)?;
        if message.kind != 4 || message.member != "PointerPositionChanged" {
            continue;
        }
        if last.elapsed() < Duration::from_millis(16) {
            continue;
        }
        last = Instant::now();
        serial = serial.wrapping_add(1).max(3);
        if query_pointer(output, &mut stream, serial).is_err() {
            continue;
        }
    }
}

fn query_pointer(
    output: &mut impl Write,
    stream: &mut std::os::unix::net::UnixStream,
    serial: u32,
) -> io::Result<()> {
    let reply = call(
        stream,
        serial,
        "org.freedesktop.a11y.Manager",
        "/org/freedesktop/a11y/Manager",
        "org.freedesktop.a11y.PointerLocator",
        "QueryPointer",
        "",
        &[],
    )?;
    if reply.kind != 2 || reply.signature != "a{sv}dd" {
        return Err(io::Error::other("pointer position is unavailable"));
    }
    let (x, y) = pointer_xy(&reply.body)?;
    writeln!(output, "move {x:.2} {y:.2}")?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_largest_cursor_image_and_straightens_alpha() {
        let mut data = vec![0u8; 28 + 36 + 4];
        data[0..4].copy_from_slice(&0x7275_6358u32.to_le_bytes());
        data[4..8].copy_from_slice(&16u32.to_le_bytes());
        data[12..16].copy_from_slice(&1u32.to_le_bytes());
        data[16..20].copy_from_slice(&0xfffd_0002u32.to_le_bytes());
        data[24..28].copy_from_slice(&28u32.to_le_bytes());
        data[28..32].copy_from_slice(&36u32.to_le_bytes());
        data[44..48].copy_from_slice(&1u32.to_le_bytes());
        data[48..52].copy_from_slice(&1u32.to_le_bytes());
        data[64..68].copy_from_slice(&0x8040_0000u32.to_le_bytes());
        let image = largest_image(&data).unwrap();
        assert_eq!((image.width, image.hot_x), (1, 0));
        let raw = straight_rgba(&image);
        assert_eq!(raw, vec![0, 128, 0, 0, 128]);
    }

    #[test]
    fn png_round_trips_a_stored_pixel() {
        let file = png(1, 1, &[0, 9, 8, 7, 6]);
        assert_eq!(&file[..8], b"\x89PNG\r\n\x1a\n");
        let idat = file.windows(4).position(|tag| tag == b"IDAT").unwrap();
        let payload_len = u32::from_be_bytes(file[idat - 4..idat].try_into().unwrap()) as usize;
        let zlib = &file[idat + 4..idat + 4 + payload_len];
        assert_eq!(&zlib[..2], &[0x78, 0x01]);
        assert_eq!(zlib[2], 1);
        assert_eq!(&zlib[7..12], &[0, 9, 8, 7, 6]);
    }

    #[test]
    fn encoded_calls_decode_and_pointer_body_skips_the_dictionary() {
        let bytes = encode_call(
            7,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
            "",
            &[],
        );
        let message = decode_message(&bytes).unwrap();
        assert_eq!(message.member, "Hello");
        assert_eq!(message.kind, 1);
        let mut body = vec![8, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0];
        body.extend(1.5f64.to_le_bytes());
        body.extend(2.25f64.to_le_bytes());
        assert_eq!(pointer_xy(&body).unwrap(), (1.5, 2.25));
    }

    #[test]
    fn external_auth_encodes_the_decimal_uid() {
        assert_eq!(hex_uid(1000), "31303030");
    }
}
