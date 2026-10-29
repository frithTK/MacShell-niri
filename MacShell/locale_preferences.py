"""User locale preferences, also consumed before the graphical session is started.

The environment.d file is the single authoritative document. Metadata is stored
in comments, so systemd and MacShell cannot observe two independently saved files.
"""
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

HEADER = "# MacShell locale preferences v1"
REGIONAL = ("LC_NUMERIC", "LC_TIME", "LC_MONETARY", "LC_PAPER", "LC_NAME", "LC_ADDRESS",
            "LC_TELEPHONE", "LC_MEASUREMENT", "LC_IDENTIFICATION")
ALLOWED = {"LANG", "LANGUAGE", "LC_MESSAGES", *REGIONAL}
VALUE = re.compile(r"[a-zA-Z0-9_.@:\-]+")
DEFAULTS = dict(ui="system", session="system", region="system")


class LocaleError(ValueError):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code, self.detail = code, detail


def config_path():
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "environment.d/90-macshell-locale.conf"


def token(raw):
    return hashlib.sha256(raw).hexdigest() if raw is not None else "missing"


def parse(raw):
    if raw is None:
        return dict(DEFAULTS), {}
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise LocaleError("invalid") from error
    if not lines or lines[0] != HEADER:
        raise LocaleError("unowned_or_future")
    preferences, environment = {}, {}
    for line in lines[1:]:
        if not line.strip():
            continue
        if line.startswith("# "):
            name, separator, value = line[2:].partition("=")
            if not separator or name not in DEFAULTS or name in preferences or not VALUE.fullmatch(value):
                raise LocaleError("invalid")
            preferences[name] = value
        else:
            name, separator, value = line.partition("=")
            if not separator or name not in ALLOWED or name in environment or not VALUE.fullmatch(value):
                raise LocaleError("invalid")
            environment[name] = value
    if set(preferences) != set(DEFAULTS) or preferences["ui"] not in ("system", "en", "ru"):
        raise LocaleError("invalid")
    return preferences, environment


def installed_locales():
    result = subprocess.run(["locale", "-a"], capture_output=True, text=True, timeout=4, check=True)
    return sorted({value for value in result.stdout.splitlines() if VALUE.fullmatch(value)})


def serialize(preferences, locales):
    if not isinstance(preferences, dict) or set(preferences) != set(DEFAULTS):
        raise LocaleError("invalid_selection")
    if preferences["ui"] not in ("system", "en", "ru"):
        raise LocaleError("invalid_selection")
    for name in ("session", "region"):
        value = preferences[name]
        if not isinstance(value, str) or not VALUE.fullmatch(value):
            raise LocaleError("invalid_selection")
        if value != "system" and value not in locales:
            raise LocaleError("locale_missing", value)
    environment = {}
    if preferences["session"] != "system":
        value = preferences["session"]
        environment.update(LANG=value, LC_MESSAGES=value)
        # GNU gettext ignores LANGUAGE in C/POSIX. Other locales use the selected
        # primary language, then English. No input is evaluated as shell syntax.
        language = re.split(r"[_.@-]", value)[0]
        environment["LANGUAGE"] = language + (":en" if language != "en" else "")
    if preferences["region"] != "system":
        environment.update({key: preferences["region"] for key in REGIONAL})
    lines = [HEADER] + ["# " + key + "=" + preferences[key] for key in DEFAULTS]
    lines += [key + "=" + value for key, value in environment.items()]
    return ("\n".join(lines) + "\n").encode(), environment


class Preferences:
    def __init__(self, path=None, locales=None, environ=None):
        self.path = Path(path) if path else config_path()
        self.locales = installed_locales() if locales is None else locales
        self.environ = os.environ if environ is None else environ

    def raw(self):
        if self.path.is_symlink():
            raise LocaleError("symlink")
        try:
            if self.path.stat().st_size > 16384:
                raise LocaleError("invalid")
            return self.path.read_bytes()
        except FileNotFoundError:
            return None

    def load(self):
        raw = self.raw()
        preferences, environment = parse(raw)
        # A valid owned file must also match its metadata. Unknown hand-edited
        # assignments are never silently discarded by a subsequent save.
        # Missing locale packages must not prevent choosing a working replacement.
        known = set(self.locales) | {preferences["session"], preferences["region"]}
        _, generated = serialize(preferences, known) if raw is not None else (None, {})
        if environment != generated:
            raise LocaleError("invalid")
        current = {key: self.environ.get(key, "") for key in ("LANG", "LANGUAGE", "LC_MESSAGES", "LC_ALL", *REGIONAL)}
        pending = any(current[key] != value for key, value in environment.items())
        return dict(values=preferences, token=token(raw), locales=self.locales, current=current,
                    pending=pending, conflict=current["LC_ALL"], readOnly=False,
                    missing=sorted({value for key, value in preferences.items() if key != "ui" and value != "system" and value not in self.locales}))

    def save(self, values, expected_token):
        raw, environment = serialize(values, self.locales)
        if self.environ.get("LC_ALL") and (values["session"] != "system" or values["region"] != "system"):
            raise LocaleError("lc_all_conflict", self.environ["LC_ALL"])
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_path = self.path.with_suffix(".lock")
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            previous = self.raw()
            if token(previous) != expected_token:
                raise LocaleError("conflict")
            parse(previous)
            if previous == raw:
                return self.load()
            # Keep the exact previous document once. A failed atomic replacement
            # keeps both the old preferences and the environment intact.
            if previous is not None:
                self.atomic_write(self.path.with_suffix(".conf.previous"), previous)
            self.atomic_write(self.path, raw)
        return self.load()

    @staticmethod
    def atomic_write(path, raw):
        descriptor, temporary = tempfile.mkstemp(prefix=".macshell-locale-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)


def session_environment(path=None, environ=None):
    preferences = Preferences(path, environ=environ)
    raw = preferences.raw()
    selection, saved = parse(raw)
    if raw is None:
        return {}
    _, expected = serialize(selection, preferences.locales)
    if saved != expected:
        raise LocaleError("invalid")
    if expected and preferences.environ.get("LC_ALL"):
        raise LocaleError("lc_all_conflict", preferences.environ["LC_ALL"])
    return expected
