use crate::niri::shell_quote;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const MIME: &str =
    "image/png;image/jpeg;image/gif;image/bmp;image/x-ms-bmp;application/pdf;";
const EXTENSIONS: &str = "png;jpg;jpeg;jpe;gif;bmp;pdf;";
const MARK_BEGIN: &str = "<!-- macshell-convert begin -->";
const MARK_END: &str = "<!-- macshell-convert end -->";

const ACTIONS: &[(&str, &str, &str, &str)] = &[
    ("png", "PNG", "PNG", "Save a PNG next to the original"),
    ("jpeg", "JPEG", "JPEG", "Save a JPEG next to the original"),
    ("pdf", "PDF", "PDF", "Save a one-page PDF next to the original"),
    (
        "rotate90",
        "Rotate 90",
        "Поворот 90°",
        "Save a copy rotated 90° next to the original",
    ),
];

pub fn install(bin: &Path, shell: &Path, data: &Path, config: &Path) -> io::Result<()> {
    let helper = shell.join("drop-tools.sh");
    let launcher = bin.join("macshell-convert");
    write_executable(
        &launcher,
        &format!(
            "#!/bin/sh\nset -eu\nexec {} --convert \"$@\"\n",
            shell_quote(path_text(&helper)?)
        ),
    )?;
    let user_data = data
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(data);
    install_kde(user_data, &helper)?;
    install_nemo(user_data, &helper)?;
    install_file_manager_actions(user_data, &helper)?;
    install_scripts(user_data.join("nautilus/scripts/Convert"), &helper)?;
    install_scripts(user_data.join("caja/scripts/Convert"), &helper)?;
    merge_thunar(&config.join("Thunar/uca.xml"), &helper)?;
    Ok(())
}

fn path_text(path: &Path) -> io::Result<&str> {
    path.to_str()
        .ok_or_else(|| io::Error::other("non-UTF-8 path"))
}

fn write_executable(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
}

fn write_text(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content)
}

fn desktop_exec(helper: &Path) -> io::Result<String> {
    Ok(quote_exec(path_text(helper)?))
}

fn quote_exec(value: &str) -> String {
    if value
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&c))
    {
        value.into()
    } else {
        format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
    }
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn install_kde(user_data: &Path, helper: &Path) -> io::Result<()> {
    let exec = desktop_exec(helper)?;
    let actions = ACTIONS
        .iter()
        .map(|(id, _, _, _)| format!("To{id}"))
        .collect::<Vec<_>>()
        .join(";");
    let mut body = format!(
        "[Desktop Entry]\nType=Service\nServiceTypes=KonqPopupMenu/Plugin\nMimeType={MIME}\nActions={actions}\nX-KDE-Priority=TopLevel\nX-KDE-Submenu=Convert\nX-KDE-Submenu[ru]=Преобразовать\nIcon=image-x-generic\n"
    );
    for (id, en, ru, comment) in ACTIONS {
        body.push_str(&format!(
            "\n[Desktop Action To{id}]\nName={en}\nName[ru]={ru}\nIcon=image-x-generic\nExec={exec} --convert --notify --op {id} %F\nComment={comment}\n"
        ));
    }
    for dir in ["kio/servicemenus", "kservices5/ServiceMenus"] {
        write_text(&user_data.join(dir).join("macshell-convert.desktop"), &body)?;
    }
    Ok(())
}

fn install_nemo(user_data: &Path, helper: &Path) -> io::Result<()> {
    let exec = desktop_exec(helper)?;
    let dir = user_data.join("nemo/actions");
    fs::create_dir_all(&dir)?;
    for (id, en, ru, comment) in ACTIONS {
        let body = format!(
            "[Nemo Action]\nActive=true\nName=Convert — {en}\nName[ru]=Преобразовать — {ru}\nComment={comment}\nExec={exec} --convert --notify --op {id} %F\nSelection=notnone\nExtensions={EXTENSIONS}\nMimetypes={MIME}\nQuote=double\nEscapeSpaces=true\n"
        );
        write_text(&dir.join(format!("macshell-convert-{id}.nemo_action")), &body)?;
    }
    Ok(())
}

fn install_file_manager_actions(user_data: &Path, helper: &Path) -> io::Result<()> {
    let exec = desktop_exec(helper)?;
    let dir = user_data.join("file-manager/actions");
    fs::create_dir_all(&dir)?;
    for (id, en, ru, comment) in ACTIONS {
        let body = format!(
            "[Desktop Entry]\nType=Action\nName=Convert — {en}\nName[ru]=Преобразовать — {ru}\nTooltip={comment}\nIcon=image-x-generic\nProfiles=profile-zero;\n\n[X-Action-Profile profile-zero]\nExec={exec} --convert --notify --op {id} %F\nMimeTypes={MIME}\nSelectionCount=>0\n"
        );
        write_text(&dir.join(format!("macshell-convert-{id}.desktop")), &body)?;
    }
    Ok(())
}

fn install_scripts(dir: PathBuf, helper: &Path) -> io::Result<()> {
    fs::create_dir_all(&dir)?;
    let quoted = shell_quote(path_text(helper)?);
    for (id, en, _, _) in ACTIONS {
        write_executable(
            &dir.join(*en),
            &format!("#!/bin/sh\nset -eu\nexec {quoted} --convert --notify --op {id} \"$@\"\n"),
        )?;
    }
    Ok(())
}

fn merge_thunar(path: &Path, helper: &Path) -> io::Result<()> {
    let quoted = xml_escape(&desktop_exec(helper)?);
    let mut block = String::from(MARK_BEGIN);
    block.push('\n');
    for (id, en, _, comment) in ACTIONS {
        block.push_str(&format!(
            "<action>\n\t<icon>image-x-generic</icon>\n\t<name>Convert — {en}</name>\n\t<unique-id>macshell-convert-{id}</unique-id>\n\t<command>{quoted} --convert --notify --op {id} %F</command>\n\t<description>{}</description>\n\t<patterns>*</patterns>\n\t<image-files/>\n\t<other-files/>\n</action>\n",
            xml_escape(comment)
        ));
    }
    block.push_str(MARK_END);
    let existing = if path.is_file() {
        fs::read_to_string(path)?
    } else {
        String::new()
    };
    let stripped = strip_marked(&existing);
    let merged = if stripped.contains("</actions>") {
        stripped.replacen("</actions>", &format!("{block}\n</actions>"), 1)
    } else if stripped.trim().is_empty() {
        format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<actions>\n{block}\n</actions>\n")
    } else {
        format!("{stripped}\n{block}\n")
    };
    write_text(path, &merged)
}

fn strip_marked(source: &str) -> String {
    let Some(start) = source.find(MARK_BEGIN) else {
        return source.to_string();
    };
    let rest = &source[start..];
    let end = rest
        .find(MARK_END)
        .map(|index| start + index + MARK_END.len())
        .unwrap_or(source.len());
    let mut out = String::new();
    out.push_str(&source[..start]);
    out.push_str(source[end..].trim_start_matches('\n'));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "macshell-convert-menus-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn writes_submenu_files_and_keeps_existing_thunar_actions() {
        let fixture = Fixture::new();
        let root = &fixture.0;
        let bin = root.join("bin");
        let shell = root.join("shell");
        let data = root.join("share/macshell-niri");
        let config = root.join("config");
        fs::create_dir_all(&shell).unwrap();
        fs::write(shell.join("drop-tools.sh"), "#!/bin/sh\n").unwrap();
        fs::create_dir_all(config.join("Thunar")).unwrap();
        fs::write(
            config.join("Thunar/uca.xml"),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<actions>\n<action>\n\t<name>User</name>\n\t<unique-id>keep-me</unique-id>\n</action>\n</actions>\n",
        )
        .unwrap();
        install(&bin, &shell, &data, &config).unwrap();
        let launcher = fs::read_to_string(bin.join("macshell-convert")).unwrap();
        assert!(launcher.contains("drop-tools.sh --convert"));
        let kde = fs::read_to_string(root.join("share/kio/servicemenus/macshell-convert.desktop")).unwrap();
        assert!(kde.contains("X-KDE-Submenu=Convert"));
        assert!(kde.contains("X-KDE-Submenu[ru]=Преобразовать"));
        assert!(kde.contains("--op png %F"));
        assert!(kde.contains("--op rotate90 %F"));
        assert!(root
            .join("share/kservices5/ServiceMenus/macshell-convert.desktop")
            .is_file());
        let nemo = fs::read_to_string(
            root.join("share/nemo/actions/macshell-convert-png.nemo_action"),
        )
        .unwrap();
        assert!(nemo.contains("Name=Convert — PNG"));
        assert!(nemo.contains("Name[ru]=Преобразовать — PNG"));
        let script = root.join("share/nautilus/scripts/Convert/PNG");
        assert_eq!(
            fs::metadata(&script).unwrap().permissions().mode() & 0o111,
            0o111
        );
        assert!(fs::read_to_string(&script)
            .unwrap()
            .contains("--op png"));
        assert!(root.join("share/caja/scripts/Convert/JPEG").is_file());
        assert!(root
            .join("share/file-manager/actions/macshell-convert-pdf.desktop")
            .is_file());
        let thunar = fs::read_to_string(config.join("Thunar/uca.xml")).unwrap();
        assert!(thunar.contains("<unique-id>keep-me</unique-id>"));
        assert!(thunar.contains("macshell-convert-jpeg"));
        assert!(thunar.contains("Convert — Rotate 90"));
        install(&bin, &shell, &data, &config).unwrap();
        let again = fs::read_to_string(config.join("Thunar/uca.xml")).unwrap();
        assert_eq!(
            again.matches("<unique-id>macshell-convert-png</unique-id>").count(),
            1
        );
        assert!(again.contains("<unique-id>keep-me</unique-id>"));
    }
}
