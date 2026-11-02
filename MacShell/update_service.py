#!/usr/bin/env python3
"""On-demand release and Arch package checks; prepare, but never auto-install, MacShell."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

REPOSITORY = "frithTK/MacShell-niri"
REMOTE = "https://github.com/" + REPOSITORY + ".git"
TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


def version(value):
    match = TAG.fullmatch(value if value.startswith("v") else "v" + value)
    if not match:
        raise ValueError("invalid_version")
    return tuple(int(part) for part in match.groups())


def installed_version():
    here = Path(__file__).resolve().parent
    for path in (here / "VERSION", here.parent / "VERSION"):
        if path.is_file():
            value = path.read_text(encoding="utf-8").strip()
            version(value)
            return value.removeprefix("v")
    raise ValueError("version_unknown")


def run(args, timeout=30, env=None):
    process_env = os.environ.copy()
    process_env.update(GIT_TERMINAL_PROMPT="0", GH_PROMPT_DISABLED="1", LC_ALL="C")
    if env:
        process_env.update(env)
    return subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=timeout, env=process_env, check=False)


def latest_release():
    gh = shutil.which("gh")
    if gh:
        result = run([gh, "api", "repos/" + REPOSITORY + "/releases/latest"], timeout=30)
        payload = json.loads(result.stdout) if result.returncode == 0 else None
    else:
        payload = None
    if payload is None:
        request = urllib.request.Request("https://api.github.com/repos/" + REPOSITORY + "/releases/latest",
                                         headers={"Accept": "application/vnd.github+json", "User-Agent": "MacShell-Updater"})
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read(1024 * 1024))
    if not isinstance(payload, dict):
        raise ValueError("invalid_release")
    tag = payload.get("tag_name", "")
    if not isinstance(tag, str) or payload.get("draft") or payload.get("prerelease") or not TAG.fullmatch(tag):
        raise ValueError("invalid_release")
    return tag


def check_release():
    try:
        installed = installed_version()
        tag = latest_release()
        state = "available" if version(tag) > version(installed) else "ahead" if version(tag) < version(installed) else "current"
        return {"state": state,
                "installed": installed, "latest": tag[1:], "tag": tag}
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError):
        try:
            current = installed_version()
        except (OSError, ValueError):
            current = ""
        return {"state": "error", "installed": current, "error": "release_unavailable"}


def check_packages():
    checker = shutil.which("checkupdates")
    if not checker or not shutil.which("pacman"):
        return {"state": "unsupported"}
    try:
        with tempfile.TemporaryDirectory(prefix="macshell-checkupdates-") as directory:
            result = run([checker], timeout=150, env={"CHECKUPDATES_DB": str(Path(directory) / "db")})
        if result.returncode == 2:
            return {"state": "current", "count": 0, "packages": []}
        if result.returncode != 0:
            return {"state": "error", "error": "package_check_failed"}
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if any(" -> " not in line for line in lines):
            return {"state": "error", "error": "package_check_failed"}
        return {"state": "available" if lines else "current", "count": len(lines), "packages": lines[:200]}
    except (OSError, subprocess.SubprocessError):
        return {"state": "error", "error": "package_check_failed"}


def data_directory():
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "macshell-niri" / "updates"


def prepare(tag):
    if not TAG.fullmatch(tag) or version(tag) <= version(installed_version()):
        raise ValueError("invalid_release")
    if latest_release() != tag:
        raise ValueError("release_changed")
    git = shutil.which("git")
    if not git:
        raise RuntimeError("git_missing")
    base = data_directory()
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    if base.is_symlink() or not base.is_dir():
        raise RuntimeError("unsafe_directory")
    # Each preparation gets a unique directory; no existing checkout is overwritten.
    with tempfile.TemporaryDirectory(prefix="download-", dir=base) as temporary:
        checkout = Path(temporary) / "checkout"
        result = run([git, "-c", "core.hooksPath=/dev/null", "clone", "--quiet", "--depth=1", "--single-branch",
                      "--branch", tag, "--", REMOTE, str(checkout)], timeout=300)
        if result.returncode:
            raise RuntimeError("download_failed")
        head = run([git, "-C", str(checkout), "rev-parse", "HEAD"], timeout=10)
        tagged = run([git, "-C", str(checkout), "rev-parse", "refs/tags/" + tag + "^{commit}"], timeout=10)
        if head.returncode or tagged.returncode or head.stdout.strip() != tagged.stdout.strip():
            raise ValueError("release_mismatch")
        if (checkout / "VERSION").read_text(encoding="utf-8").strip() != tag[1:]:
            raise ValueError("release_mismatch")
        installer = checkout / "install.sh"
        if not installer.is_file() or installer.is_symlink():
            raise ValueError("release_mismatch")
        if latest_release() != tag:
            raise ValueError("release_changed")
        destination = base / (tag + "-" + uuid.uuid4().hex[:12])
        os.rename(checkout, destination)
    command = "bash " + shlex.quote(str(destination / "install.sh"))
    info = {"tag": tag, "command": command}
    # Do not follow or overwrite a pre-existing symlink at the state-file path.
    state = base / "prepared.json"
    if state.is_symlink():
        raise RuntimeError("unsafe_directory")
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=base, prefix=".prepared-", delete=False) as output:
        json.dump(info, output)
        temporary_name = output.name
    os.replace(temporary_name, state)
    return info


def prepared():
    try:
        base = data_directory()
        state = base / "prepared.json"
        if base.is_symlink() or state.is_symlink():
            return None
        info = json.loads(state.read_text(encoding="utf-8"))
        tag = info["tag"]
        if not TAG.fullmatch(tag) or version(tag) <= version(installed_version()):
            return None
        arguments = shlex.split(info["command"])
        if len(arguments) != 2 or arguments[0] != "bash":
            return None
        path = Path(arguments[1])
        if path.name != "install.sh" or path.parent.parent != base or path.parent.is_symlink() or not path.is_file() or path.is_symlink():
            return None
        return {"tag": tag, "command": info["command"]}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def launch_packages():
    kitty, sudo, pacman = (shutil.which(name) for name in ("kitty", "sudo", "pacman"))
    if not (kitty and sudo and pacman):
        raise RuntimeError("terminal_unavailable")
    subprocess.Popen([kitty, "--hold", "-e", sudo, pacman, "-Syu"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    try:
        if action == "status":
            answer = {"release": check_release(), "packages": check_packages(), "prepared": prepared(),
                      "clipboard": bool(shutil.which("wl-copy"))}
        elif action == "prepare" and len(sys.argv) == 3:
            answer = {"prepared": prepare(sys.argv[2])}
        elif action == "install-packages":
            launch_packages(); answer = {"launched": True}
        else:
            raise ValueError("invalid_request")
        print(json.dumps(answer, ensure_ascii=False))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError) as error:
        allowed = {"invalid_release", "release_changed", "git_missing", "download_failed", "release_mismatch", "unsafe_directory", "terminal_unavailable"}
        code = str(error) if str(error) in allowed else "operation_failed"
        print(json.dumps({"error": code}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
