#!/usr/bin/env python3
"""Check fingerprint controls with a fake reader and isolated settings."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--capture", type=Path)
args = parser.parse_args()
if args.capture:
    args.capture.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="macshell-biometric-native-") as directory:
    root = Path(directory)
    shell = root / "shell"
    shutil.copytree(project / "MacShell", shell)
    path = shell / "shell.qml"
    source = path.read_text().replace("import QtQuick\n", "import QtQuick\nimport QtTest\n", 1)
    path.write_text(source.replace("ShellRoot {", "ShellRoot {\n" + (project / "tests/biometric-native.qml").read_text(), 1))
    path = shell / "MacDock.qml"
    source = path.read_text().replace("    id: root\n", "    id: root\n    function testWindow() { return prefsWindow; }\n", 1)
    source = source.replace('property string userName: Quickshell.env("USER") || ""', 'property string userName: "Demo"')
    source = source.replace('if (text.trim() !== "") root.userName = text.trim()', 'root.userName = "Demo"')
    source = source.replace('source: "file://" + Quickshell.env("HOME") + "/.face"', 'source: ""')
    path.write_text(source)
    fixture = root / "fixture.json"
    fixture.write_text(json.dumps(["left-thumb", "right-thumb"]))
    (shell / "biometric_probe.py").write_text('import json,os\nfingers=json.load(open(os.environ["MACSHELL_BIOMETRIC_FIXTURE"]))\nprint(json.dumps({"status":"ok","devices":[{"path":"/fixture/0","name":"Demo fingerprint reader","enrollment":"ok","scanType":"swipe","fingers":fingers}]}))\n')
    (shell / "fingerprint_operation.py").write_text('''import json,os,select,sys,time
path=os.environ["MACSHELL_BIOMETRIC_FIXTURE"]
action,device,finger=sys.argv[1:]
assert device == "/fixture/0" and finger == "right-index-finger"
print(json.dumps({"type":"status","code":"scan","stage":1,"total":3}),flush=True)
print(json.dumps({"type":"finger-presence","present":True}),flush=True)
time.sleep(1.8)
print(json.dumps({"type":"finger-presence","present":False}),flush=True)
time.sleep(.4)
fingers=json.load(open(path))
if action == "enroll": fingers.append(finger); code="enroll-completed"
elif action == "delete": fingers.remove(finger); code="deleted"
else:
    marker=path+".verify"
    if os.path.exists(marker):
        ready,_,_=select.select([sys.stdin],[],[],5)
        if ready and sys.stdin.readline().strip() == "cancel":
            print(json.dumps({"type":"result","code":"cancelled","success":False}),flush=True)
            sys.exit(0)
    else:
        open(marker,"w").close()
    code="verify-match"
with open(path,"w") as file: json.dump(fingers,file)
print(json.dumps({"type":"result","code":code,"success":True}),flush=True)
''')
    for name in ("cache", "config", "home", "settings/macbar", "settings/macdock"):
        (root / name).mkdir(parents=True)
    (root / "settings/macbar/settings.json").write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False, ccEnabled=False,
        notificationsEnabled=False, clipHistory=False, uiSounds=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / "settings/macdock/settings.json").write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    environment = dict(os.environ, QT_QPA_PLATFORM="wayland", QT_QPA_PLATFORMTHEME="", QT_QUICK_CONTROLS_STYLE="Basic",
        XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"), MACSHELL_SETTINGS_HOME=str(root / "settings"),
        HOME=str(root / "home"), USER="Demo", NIRI_SOCKET=str(root / "no-session"),
        DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(root / "no-bus"), DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-bus"),
        PIPEWIRE_REMOTE="macshell-no-audio", MACSHELL_BIOMETRIC_FIXTURE=str(fixture), MACSHELL_BIOMETRIC_CAPTURE=str(args.capture.resolve()) if args.capture else "")
    result = subprocess.run([quickshell(), "-p", str(shell)], env=environment, capture_output=True, text=True, timeout=35)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-biometric-native.log').write_text(log)
    for line in log.splitlines():
        if re.search(r"BIOMETRIC|TypeError|ReferenceError|Binding loop|Unable to assign", line):
            print(line)
    if result.returncode or "MACSHELL_BIOMETRIC_NATIVE_PASS" not in log or re.search(r"TypeError|ReferenceError|Binding loop|Unable to assign", log):
        raise SystemExit(result.returncode or 1)
