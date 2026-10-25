#!/usr/bin/env python3
"""Optional real-Wayland geometry check with isolated preferences and D-Bus.

Opens short-lived temporary panels; does not change devices.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell
probe='''
                TestEvent { id: nativeEvents }
                Timer {
                    id: nativeProbe; interval: 140; repeat: true; running: win.modelData === Quickshell.screens[0]
                    property int phase: -1
                    property int step: 0
                    property int elapsed: 0
                    function check(value, reason) { if (!value) { console.error("M1_NATIVE_FAIL: " + reason); Qt.exit(1); } }
                    onTriggered: {
                        elapsed++;
                        if (elapsed > 80) { check(false, "timeout"); return; }
                        if (!root.barLayout.ready || root.barLayout.pending) return;
                        if (phase < 0) {
                            root.barHeight = 35; root.kbLayouts = [{code: "en", name: "English"}, {code: "ru", name: "Russian"}];
                            phase = 0;
                        }
                        var zones = ["left", "center", "right"];
                        if (phase === 3) {
                            if (step === 0) { barBg.width = 400; step = 1; return; }
                            if (step === 1) {
                                var compact = ui.childAnchor(appSlot, "app");
                                check(appSlot.placement.mode > 0, "compact application menu");
                                nativeEvents.mouseClick(compact, compact.width / 2, compact.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                                check(ui.pop === "appmenus", "compact chooser opens"); step = 2; return;
                            }
                            var file = overflowList.itemAtIndex(1);
                            check(file, "compact File entry");
                            nativeEvents.mouseClick(file, file.width / 2, file.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                            check(ui.pop === "file", "compact File menu remains accessible");
                            console.log("MACSHELL_M1_NATIVE_UI_PASS: 33 menu clicks across three zones at 125% bar scale, plus compact menu navigation");
                            Qt.quit(); return;
                        }
                        if (step === 0) {
                            var next = BarLayout.clone(root.barLayout.values);
                            next.common.forEach(item => { item.zone = zones[phase]; item.enabled = true; });
                            root.barLayout.save(next, root.barLayout.token); step = 1; return;
                        }
                        var cases = [[ui.childAnchor(appleSlot, "apple"), "apple", Qt.LeftButton], [ui.childAnchor(appSlot, "app"), "app", Qt.LeftButton], [statsBar, "stats", Qt.LeftButton], [btBtn, "bt", Qt.LeftButton], [volBtn, "vol", Qt.LeftButton], [kbBtn, "kb", Qt.RightButton], [batteryButton, "battery", Qt.LeftButton], [bellBtn, "notif", Qt.LeftButton], [wifiBtn, "wifi", Qt.LeftButton], [ccBtn, "cc", Qt.LeftButton], [clockBtn, "cal", Qt.LeftButton]];
                        if (step <= cases.length) {
                            var test = cases[step - 1], button = test[0];
                            check(button && button.visible && button.width > 0, test[1] + " visibility");
                            nativeEvents.mouseClick(button, button.width / 2, button.height / 2, test[2], Qt.NoModifier, 0);
                            check(ui.pop === test[1], test[1] + " click in " + zones[phase] + ": " + ui.pop);
                            var point = button.mapToItem(ui, (test[1] === "apple" || test[1] === "app") ? 0 : button.width / 2, 0);
                            check(Math.abs(ui.menuX - point.x) < 1, test[1] + " anchor in " + zones[phase]);
                            ui.pop = ""; step++; return;
                        }
                        phase++; step = 0;
                        if (phase >= zones.length) {
                            var next = BarLayout.clone(root.barLayout.values);
                            next.common = next.common.filter(item => item.type === "appMenus" || item.type === "clock");
                            next.common.forEach(item => item.zone = "left");
                            root.barLayout.save(next, root.barLayout.token);
                        }
                    }
                }
'''
with tempfile.TemporaryDirectory() as directory:
    root=Path(directory)
    for name in ('runtime','cache','config','settings'):
        (root/name).mkdir()
    (root/'runtime').chmod(0o700)
    shutil.copytree(project/'MacShell',root/'shell')
    path=root/'shell/MacBar.qml'
    text=path.read_text().replace('import QtQuick\n','import QtQuick\nimport QtTest\n',1).replace('readonly property bool hasBattery: batteryControl.present','readonly property bool hasBattery: true')
    text=text.replace('                property string pop: ""',probe+'\n                property string pop: ""',1)
    path.write_text(text)
    # Local Qt key/mouse events target only this temporary instance. All helper
    # configuration, D-Bus and niri connections are isolated from the desktop.
    environment=dict(os.environ,QT_QPA_PLATFORM='wayland',QT_QPA_PLATFORMTHEME='',QT_QUICK_CONTROLS_STYLE='Basic',XDG_CACHE_HOME=str(root/'cache'),XDG_CONFIG_HOME=str(root/'config'), MACSHELL_SETTINGS_HOME=str(root/'settings'), NIRI_SOCKET=str(root/'no-session'), DBUS_SESSION_BUS_ADDRESS='unix:path='+str(root/'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(root/'no-bus'))
    try:
        result = subprocess.run([quickshell(), '-p', str(root/'shell')], env=environment, capture_output=True, text=True, timeout=35)
        log = result.stdout + result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        log = (error.stdout or b'').decode(errors='replace') + (error.stderr or b'').decode(errors='replace')
        code = 1
        print('Native UI probe timed out.')
    Path('/tmp/macshell-m1-native-ui.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR','Error','FAIL','PASS','unavailable','Binding loop')): print(line)
    if code or 'MACSHELL_M1_NATIVE_UI_PASS' not in log:
        raise SystemExit(code or 1)
