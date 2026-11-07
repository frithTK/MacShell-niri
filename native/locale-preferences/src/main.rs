use macshell_locale_preferences::{
    read_document, session_environment, Environment, LocaleError, REGIONAL,
};
use std::collections::BTreeSet;
use std::env;
use std::ffi::{CStr, OsStr};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn account_home() -> Option<PathBuf> {
    let mut size = 16_384;
    while size <= 1_048_576 {
        let mut bytes = vec![0; size];
        let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut out = std::ptr::null_mut();
        let status = unsafe {
            libc::getpwuid_r(
                libc::getuid(),
                entry.as_mut_ptr(),
                bytes.as_mut_ptr().cast(),
                bytes.len(),
                &mut out,
            )
        };
        if status == libc::ERANGE {
            size *= 2;
            continue;
        }
        if status != 0 || out.is_null() {
            return None;
        }
        let entry = unsafe { entry.assume_init() };
        if entry.pw_dir.is_null() {
            return None;
        }
        return Some(PathBuf::from(OsStr::from_bytes(
            unsafe { CStr::from_ptr(entry.pw_dir) }.to_bytes(),
        )));
    }
    None
}
fn config_path() -> Result<PathBuf, LocaleError> {
    let home = env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME")
                .map(|v| {
                    if v.is_empty() {
                        PathBuf::from("/")
                    } else {
                        PathBuf::from(v)
                    }
                })
                .or_else(account_home)
                .map(|v| v.join(".config"))
        })
        .ok_or_else(|| LocaleError::new("io_error"))?;
    Ok(home.join("environment.d/90-macshell-locale.conf"))
}
fn installed_locales() -> Result<BTreeSet<String>, LocaleError> {
    let mut child = Command::new("locale")
        .arg("-a")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| LocaleError::new("locale_query_failed"))?;
    let mut stdout = child.stdout.take().unwrap();
    let fd = stdout.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err(LocaleError::new("locale_query_failed"));
    }
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut bytes = Vec::new();
    let mut eof = false;
    let mut status = None;
    loop {
        let mut buf = [0u8; 8192];
        loop {
            match stdout.read(&mut buf) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(n) => {
                    bytes.extend_from_slice(&buf[..n]);
                    if bytes.len() > 1_048_576 {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(LocaleError::new("locale_query_failed"));
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(LocaleError::new("locale_query_failed"));
                }
            }
        }
        if status.is_none() {
            status = child
                .try_wait()
                .map_err(|_| LocaleError::new("locale_query_failed"))?;
        }
        if eof && status.is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(LocaleError::new("locale_query_failed"));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if !status.unwrap().success() {
        return Err(LocaleError::new("locale_query_failed"));
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| LocaleError::new("io_error"))?;
    Ok(macshell_locale_preferences::split_lines(text)
        .into_iter()
        .filter(|v| {
            !v.is_empty()
                && v.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"_.@:-".contains(&c))
        })
        .map(str::to_owned)
        .collect())
}
fn session() -> Result<(), LocaleError> {
    // Like the existing session helper, discover locales before reading the file.
    let locales = installed_locales()?;
    let raw = read_document(&config_path()?)?;
    let mut current = Environment::new();
    if let Some(value) = env::var_os("LC_ALL") {
        current.insert("LC_ALL".into(), value.to_string_lossy().into_owned());
    }
    let result = session_environment(raw.as_deref(), &locales, &current)?;
    for key in ["LANG", "LC_MESSAGES", "LANGUAGE"]
        .into_iter()
        .chain(REGIONAL)
    {
        if let Some(value) = result.get(key) {
            println!("{key}={value}");
        }
    }
    Ok(())
}
fn current_environment() -> Environment {
    let mut result = Environment::new();
    for key in ["LANG", "LANGUAGE", "LC_MESSAGES", "LC_ALL"]
        .into_iter()
        .chain(REGIONAL)
    {
        if let Some(value) = env::var_os(key) {
            result.insert(key.into(), value.to_string_lossy().into_owned());
        }
    }
    result
}
fn emit(
    output: &mut impl io::Write,
    mut message: serde_json::Value,
    generation: &Option<serde_json::Value>,
) -> io::Result<()> {
    if let Some(generation) = generation {
        message["generation"] = generation.clone();
    }
    serde_json::to_writer(&mut *output, &message)?;
    output.write_all(b"\n")?;
    output.flush()
}
fn command(
    request: &serde_json::Value,
    output: &mut impl io::Write,
    generation: &Option<serde_json::Value>,
) -> io::Result<()> {
    let result = (|| -> Result<serde_json::Value, LocaleError> {
        let locales = installed_locales()?;
        let current = current_environment();
        let path = config_path()?;
        match request.get("action").and_then(serde_json::Value::as_str) {
            Some("load") => macshell_locale_preferences::load(&path, &locales, &current),
            Some("save") => {
                let data = request
                    .get("data")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!({}));
                macshell_locale_preferences::save(
                    &path,
                    data.get("values").unwrap_or(&serde_json::Value::Null),
                    data.get("token").and_then(serde_json::Value::as_str),
                    &locales,
                    &current,
                )
            }
            _ => Err(LocaleError::new("invalid_selection")),
        }
    })();
    match result {
        Ok(mut state) => {
            state["type"] = serde_json::json!("state");
            emit(output, state, generation)?;
            emit(
                output,
                serde_json::json!({"type":"result","id":request.get("id"),"success":true}),
                generation,
            )
        }
        Err(error) => emit(
            output,
            serde_json::json!({"type":"result","id":request.get("id"),"success":false,"code":error.code,"detail":error.detail}),
            generation,
        ),
    }
}
fn serve() -> io::Result<()> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    let mut buffer = Vec::new();
    emit(
        &mut output,
        serde_json::json!({"type":"ready"}),
        &generation,
    )?;
    loop {
        let mut poll = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut poll, 1, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll.revents & libc::POLLNVAL != 0 {
            break;
        }
        if poll.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut bytes = [0u8; 65536];
            let count =
                unsafe { libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count <= 0 {
                break;
            }
            buffer.extend_from_slice(&bytes[..count as usize]);
            if buffer.len() > 1_048_576 {
                break;
            }
            while let Some(end) = buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<_> = buffer.drain(..=end).collect();
                if let Ok(request) = serde_json::from_slice::<serde_json::Value>(&line) {
                    let data = request
                        .get("data")
                        .cloned()
                        .unwrap_or_else(|| serde_json::json!({}));
                    if request.is_object()
                        && data.is_object()
                        && request.get("generation").is_some()
                    {
                        generation = request.get("generation").cloned();
                        command(&request, &mut output, &generation)?;
                        continue;
                    }
                }
                emit(
                    &mut output,
                    serde_json::json!({"type":"error","error":"Invalid service request"}),
                    &generation,
                )?;
            }
        }
    }
    Ok(())
}
fn main() {
    let args: Vec<_> = env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-locale-preferences 1");
        return;
    }
    if args == ["--session"] {
        if let Err(error) = session() {
            eprintln!("MacShell locale could not be applied: {}", error.code);
            std::process::exit(1);
        }
        return;
    }
    if !args.is_empty() {
        eprintln!("macshell-locale-preferences: unexpected argument");
        std::process::exit(2);
    }
    if let Err(error) = serve() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-locale-preferences: {error}");
            std::process::exit(1);
        }
    }
}
