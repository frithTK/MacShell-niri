//! Filesystem transaction backend for the MacShell installer.
mod build;
mod convert_menus;
mod guard;
mod install;
mod niri;
mod session;
use serde_json::{json, Value};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

fn cli(source: PathBuf, arguments: &[std::ffi::OsString]) -> io::Result<i32> {
    let flags: Vec<_> = arguments
        .iter()
        .map(|v| {
            v.to_str()
                .ok_or_else(|| io::Error::other("invalid argument"))
        })
        .collect::<io::Result<_>>()?;
    if flags.iter().any(|v| *v == "--help" || *v == "-h") {
        println!("Usage: install.sh [--check | --dry-run | --rollback] [--session | --activate] [--force] [--rust-bridge]");
        return Ok(0);
    }
    for flag in &flags {
        if ![
            "--check",
            "--dry-run",
            "--rollback",
            "--session",
            "--activate",
            "--force",
            "--rust-bridge",
        ]
        .contains(flag)
        {
            return Err(io::Error::other(format!("unknown option: {flag}")));
        }
    }
    let has = |s| flags.contains(&s);
    if ["--check", "--dry-run", "--rollback"]
        .iter()
        .filter(|s| has(s))
        .count()
        > 1
        || (has("--session") && has("--activate"))
        || (has("--rollback") && has("--rust-bridge"))
    {
        return Err(io::Error::other("incompatible options"));
    }
    let home =
        PathBuf::from(env::var_os("HOME").ok_or_else(|| io::Error::other("HOME is required"))?);
    let config = env::var_os("XDG_CONFIG_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".config"));
    let cache = env::var_os("XDG_CACHE_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".cache"));
    let data = env::var_os("XDG_DATA_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/share"))
        .join("macshell-niri");
    let bin = env::var_os("MACSHELL_BIN_DIR")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/bin"));
    let qs = env::var_os("MACSHELL_QS_BIN")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            let p = data.join("runtime/bin/qs");
            p.is_file().then_some(p)
        })
        .or_else(|| {
            env::split_paths(&env::var_os("PATH").unwrap_or_default())
                .map(|p| p.join("qs"))
                .find(|p| p.is_file())
        })
        .unwrap_or_else(|| PathBuf::from("qs"));
    let qs = if qs.is_absolute() {
        qs
    } else if qs.components().count() == 1 {
        env::split_paths(&env::var_os("PATH").unwrap_or_default())
            .map(|p| p.join(&qs))
            .find(|p| p.is_file())
            .unwrap_or(qs)
    } else {
        env::current_dir()?.join(qs)
    };
    let p = install::Paths {
        source,
        config,
        cache,
        data,
        bin,
        qs,
    };
    if has("--check") {
        return Ok(if install::doctor(&p) { 0 } else { 1 });
    }
    if has("--dry-run") {
        println!("Shell: {}\nLock: {}\nSettings: {}\nLaunchers: {}\nBackups: {}\nniri bridge and migrated system services: Rust (build from cached dependencies)", p.config.join("quickshell/MacShell-niri").display(), p.config.join("quickshell/MacLock-niri").display(), p.config.join("macshell-niri/settings").display(), p.bin.display(), p.data.join("backups").display());
        if has("--activate") || has("--session") {
            install::dry_run(&p)?;
        }
        return Ok(0);
    }
    if unsafe { libc::geteuid() } == 0 {
        return Err(io::Error::other("Run as your desktop user, without sudo."));
    }
    if has("--rollback") {
        println!(
            "Restored: {}",
            install::rollback(&p, has("--force"))?.display()
        );
    } else {
        let mode = if has("--session") {
            install::Mode::Session
        } else if has("--activate") {
            install::Mode::Activate
        } else {
            install::Mode::Plain
        };
        let session_mode = mode == install::Mode::Session;
        println!("Installed MacShell-niri and MacLock-niri.\nBackup: {}\nStart: {}\nRollback: bash install.sh --rollback", install::install(&p, mode)?.display(), p.bin.join("macshell-niri").display());
        if session_mode {
            println!("Original niri configuration and running desktop are unchanged.\nRegister the login option: sudo bash {}", p.data.join("session/register-session.sh").display());
        }
    }
    Ok(0)
}

fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(source)?;
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    if metadata.file_type().is_symlink() {
        symlink(fs::read_link(source)?, destination)?;
    } else if metadata.is_dir() {
        fs::create_dir(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            copy_tree(&entry.path(), &destination.join(entry.file_name()))?;
        }
        fs::set_permissions(
            destination,
            fs::Permissions::from_mode(metadata.mode() & 0o7777),
        )?;
    } else if metadata.is_file() {
        fs::copy(source, destination)?;
        fs::set_permissions(
            destination,
            fs::Permissions::from_mode(metadata.mode() & 0o7777),
        )?;
    } else {
        return Err(io::Error::other(format!(
            "unsupported file type: {}",
            source.display()
        )));
    }
    use std::os::unix::ffi::OsStrExt;
    let path =
        std::ffi::CString::new(destination.as_os_str().as_bytes()).map_err(io::Error::other)?;
    let times = [
        libc::timespec {
            tv_sec: metadata.atime(),
            tv_nsec: metadata.atime_nsec(),
        },
        libc::timespec {
            tv_sec: metadata.mtime(),
            tv_nsec: metadata.mtime_nsec(),
        },
    ];
    if unsafe {
        libc::utimensat(
            libc::AT_FDCWD,
            path.as_ptr(),
            times.as_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn remove(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn present(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn snapshot(data: &Path, paths: &[PathBuf]) -> io::Result<Value> {
    let backups = data.join("backups");
    fs::create_dir_all(&backups)?;
    let mut random = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
    let stamp: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let directory = backups.join(stamp);
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().mode(0o700).create(&directory)?;
    let mut entries = Vec::new();
    for (index, path) in paths.iter().enumerate() {
        let exists = present(path);
        let backup = directory.join("before").join(index.to_string());
        if exists {
            copy_tree(path, &backup)?;
        }
        entries.push(json!({"path": path.to_string_lossy(), "backup": backup.to_string_lossy(), "existed": exists}));
    }
    let previous = match fs::read_to_string(data.join("latest")) {
        Ok(value) => Some(value),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e),
    };
    let manifest = json!({"entries": entries, "niri_digest": null, "activated": false, "previous_shell": null, "previous_latest": previous});
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(directory.join("manifest.json"))?;
    serde_json::to_writer_pretty(&mut file, &manifest)?;
    file.flush()?;
    Ok(json!({"directory":directory.to_string_lossy(),"manifest":manifest}))
}

fn sha256(path: &Path) -> io::Result<Option<String>> {
    if !path.is_file() {
        return Ok(None);
    }
    let output = Command::new("sha256sum").arg("--").arg(path).output()?;
    if !output.status.success() {
        return Err(io::Error::other("sha256sum failed"));
    }
    let digest = output
        .stdout
        .split(|byte| byte.is_ascii_whitespace())
        .next()
        .unwrap_or_default();
    let digest = std::str::from_utf8(digest).map_err(io::Error::other)?;
    if digest.len() != 64 || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::other("invalid sha256sum output"));
    }
    Ok(Some(digest.to_ascii_lowercase()))
}

fn restore(
    data: &Path,
    directory: &Path,
    manifest: &Value,
    niri: &Path,
    force: bool,
) -> io::Result<()> {
    if let Some(expected) = manifest.get("niri_digest").and_then(Value::as_str) {
        if sha256(niri)?.as_deref() != Some(expected) && !force {
            return Err(io::Error::other(format!(
                "niri/config.kdl changed after installation. Inspect {} before --rollback --force.",
                directory.display()
            )));
        }
    }
    let entries = manifest
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| io::Error::other("invalid backup entries"))?;
    // Validate the entire manifest before changing any destination.
    let mut validated = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        let path = entry
            .get("path")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| io::Error::other("invalid destination"))?;
        let backup = entry
            .get("backup")
            .and_then(Value::as_str)
            .ok_or_else(|| io::Error::other("invalid backup"))?;
        let existed = entry
            .get("existed")
            .and_then(Value::as_bool)
            .ok_or_else(|| io::Error::other("invalid existence flag"))?;
        if Path::new(backup) != directory.join("before").join(index.to_string())
            || !Path::new(path).is_absolute()
        {
            return Err(io::Error::other("invalid backup path"));
        }
        if existed && !present(Path::new(backup)) {
            return Err(io::Error::other("backup is missing"));
        }
        validated.push((PathBuf::from(path), PathBuf::from(backup), existed));
    }
    for (index, (path, backup, existed)) in validated.iter().enumerate().rev() {
        if present(path) {
            let after = directory.join("after").join(index.to_string());
            remove(&after)?;
            copy_tree(path, &after)?;
            remove(path)?;
        }
        if *existed {
            copy_tree(backup, path)?;
        }
    }
    if let Some(previous) = manifest
        .get("previous_latest")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        fs::write(data.join("latest"), previous)?;
    } else {
        remove(&data.join("latest"))?;
    }
    Ok(())
}

fn main() {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-installer-transaction 1");
        return;
    }
    if args.len() >= 2 && args[0] == "cli" {
        match cli(PathBuf::from(&args[1]), &args[2..]) {
            Ok(code) => std::process::exit(code),
            Err(error) => {
                eprintln!("macshell-installer: {error}");
                std::process::exit(1);
            }
        }
    }
    if args.len() >= 4 && args[0] == "guard-run" && args[2] == "--" {
        match guard::run(&args[1], &args[3], &args[4..]) {
            Ok(status) => {
                use std::os::unix::process::ExitStatusExt;
                std::process::exit(
                    status
                        .code()
                        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1)),
                );
            }
            Err(error) => {
                eprintln!("macshell-installer: {error}");
                std::process::exit(1);
            }
        }
    }
    let result = (|| -> io::Result<()> {
        if args.len() == 8 && (args[0] == "install-profile" || args[0] == "rollback-profile") {
            let paths: Vec<_> = args[1..7].iter().map(PathBuf::from).collect();
            if paths.iter().any(|p| !p.is_absolute()) {
                return Err(io::Error::other("paths must be absolute"));
            }
            let p = install::Paths {
                source: paths[0].clone(),
                config: paths[1].clone(),
                cache: paths[2].clone(),
                data: paths[3].clone(),
                bin: paths[4].clone(),
                qs: paths[5].clone(),
            };
            let directory = if args[0] == "install-profile" {
                if args[7] != "session" && args[7] != "plain" && args[7] != "activate" {
                    return Err(io::Error::other("invalid installation mode"));
                }
                install::install(
                    &p,
                    if args[7] == "session" {
                        install::Mode::Session
                    } else if args[7] == "activate" {
                        install::Mode::Activate
                    } else {
                        install::Mode::Plain
                    },
                )?
            } else {
                if args[7] != "safe" && args[7] != "force" {
                    return Err(io::Error::other("invalid rollback mode"));
                }
                install::rollback(&p, args[7] == "force")?
            };
            println!("{}", json!({"directory": directory.to_string_lossy()}));
        } else if args.len() == 6 && args[0] == "launchers" {
            let paths: Vec<_> = args[1..].iter().map(PathBuf::from).collect();
            if paths.iter().any(|p| !p.is_absolute()) {
                return Err(io::Error::other("paths must be absolute"));
            }
            session::launchers(&paths[0], &paths[1], &paths[2], &paths[3], &paths[4])?;
        } else if args.len() == 9 && args[0] == "session-files" {
            let paths: Vec<_> = args[1..].iter().map(PathBuf::from).collect();
            if paths.iter().any(|p| !p.is_absolute()) {
                return Err(io::Error::other("paths must be absolute"));
            }
            session::files(session::Paths {
                source: &paths[0],
                profile: &paths[1],
                bin: &paths[2],
                data: &paths[3],
                config: &paths[4],
                qs: &paths[5],
                locale: &paths[6],
                preflight: &paths[7],
            })?;
        } else if args.len() == 3 && args[0] == "build-components" {
            let source = Path::new(&args[1]);
            let target = Path::new(&args[2]);
            if !source.is_absolute() || !target.is_absolute() {
                return Err(io::Error::other("paths must be absolute"));
            }
            println!("{}", build::build(source, target)?);
        } else if args.len() == 6 && args[0] == "prepare-niri" {
            let paths: Vec<_> = args[1..].iter().map(PathBuf::from).collect();
            if paths.iter().any(|p| !p.is_absolute()) {
                return Err(io::Error::other("paths must be absolute"));
            }
            let previous_shell =
                niri::prepare(&paths[0], &paths[1], &paths[2], &paths[3], &paths[4])?;
            println!("{}", json!({"previous_shell": previous_shell}));
        } else if args.len() >= 2 && args[0] == "snapshot" {
            let data = Path::new(&args[1]);
            let paths: Vec<_> = args[2..].iter().map(PathBuf::from).collect();
            if paths
                .iter()
                .any(|p| !p.is_absolute() || p.to_str().is_none())
                || !data.is_absolute()
            {
                return Err(io::Error::other("paths must be absolute UTF-8"));
            }
            println!("{}", snapshot(data, &paths)?);
        } else if args.len() == 5 && args[0] == "restore" {
            let data = Path::new(&args[1]);
            let directory = Path::new(&args[2]);
            let niri = Path::new(&args[3]);
            if !data.is_absolute()
                || !directory.is_absolute()
                || !niri.is_absolute()
                || (args[4] != "safe" && args[4] != "force")
            {
                return Err(io::Error::other("invalid restore arguments"));
            }
            let manifest: Value =
                serde_json::from_reader(fs::File::open(directory.join("manifest.json"))?)?;
            restore(data, directory, &manifest, niri, args[4] == "force")?;
        } else {
            return Err(io::Error::other("Usage: macshell-installer snapshot DATA [PATH...] | restore DATA BACKUP NIRI force|safe"));
        }
        Ok(())
    })();
    if let Err(error) = result {
        eprintln!("macshell-installer: {error}");
        std::process::exit(1);
    }
}
