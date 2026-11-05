#!/usr/bin/env python3
"""Exercise Spotlight mouse and keyboard selection in a disposable shell."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

probe = '''
                TestEvent { id: spotlightEvents }
                Timer {
                    interval: 180; repeat: true; running: win.modelData === Quickshell.screens[0]
                    property int step: 0
                    property int initialDelay: 0
                    property bool movedAway: false
                    property var savedRow: null
                    property string expectedTitle: ""
                    function check(ok, reason) { if (!ok) { console.error("SPOTLIGHT_NATIVE_FAIL: " + reason); Qt.exit(1); throw new Error(reason); } }
                    function windowState(title, extra) {
                        var windows = [{id: 999, app_id: "spotlight-test", title: title}];
                        if (extra) windows.push({id: 998, app_id: "spotlight-test", title: "a second window"});
                        Niri.accept({connected: true, state: {windows: windows, monitors: [], keyboard: {}, workspaces: [], overview: false}});
                    }
                    onTriggered: {
                        if (step === 0) {
                            ui.openPop("spot", 0);
                            spInput.text = "a";
                            windowState("a test window");
                            step++; return;
                        }
                        if (step === 1) {
                            if (initialDelay++ < 6) return;
                            if (!movedAway) {
                                spotlightEvents.mouseMove(spInput, 10, spInput.height / 2, 0, Qt.NoButton, Qt.NoModifier);
                                movedAway = true; return;
                            }
                            check(resPanel.items.length >= 3, "search results available");
                            var row = spotlightRows.itemAt(1);
                            check(row && row.modelData && row.modelData.run, "second result available");
                            spotlightEvents.mouseMove(row, row.width / 2, row.height / 2, 0, Qt.NoButton, Qt.NoModifier);
                            step++; return;
                        }
                        if (step === 2) {
                            check(ui.spSel === 1, "mouse hover selects second result");
                            savedRow = spotlightRows.itemAt(1);
                            expectedTitle = savedRow.modelData.title;
                            check(resPanel.pointerSelection, "hover switches to immediate selection");
                            spotlightEvents.mousePress(savedRow, savedRow.width / 2, savedRow.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                            windowState("a changed window", true);
                            check(spotlightRows.itemAt(1) === savedRow, "result survives adding a window");
                            windowState("a changed window", false);
                            step++; return;
                        }
                        if (step === 3) {
                            check(spotlightRows.itemAt(1) === savedRow, "result survives window updates during mouse press");
                            spotlightEvents.mouseRelease(savedRow, savedRow.width / 2, savedRow.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                            check(ui.pop === "" && root.spotlightTestRuns === 1 && root.spotlightTestTitle === expectedTitle, "click activates second result");
                            step++; return;
                        }
                        if (step === 4) {
                            ui.openPop("spot", 0); spInput.text = "a"; step++; return;
                        }
                        if (step === 5) {
                            var expectedIndex = (Math.min(ui.spSel, ui.spResults.length - 1) + 1) % ui.spResults.length;
                            ui.spMove(1); check(ui.spSel === expectedIndex && !resPanel.pointerSelection, "keyboard moves selection: index=" + ui.spSel + " pointer=" + resPanel.pointerSelection + " results=" + ui.spResults.length);
                            expectedTitle = ui.spResults[expectedIndex].title;
                            ui.spEnter(); check(ui.pop === "" && root.spotlightTestRuns === 2 && root.spotlightTestTitle === expectedTitle, "keyboard activates result");
                            step++; return;
                        }
                        if (step === 6) {
                            ui.openPop("spot", 0); spInput.text = "a"; initialDelay = 0; step++; return;
                        }
                        if (step === 7) {
                            if (initialDelay++ < 6) return;
                            var target = spotlightRows.itemAt(1);
                            spotlightEvents.mousePress(target, target.width / 2, target.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                            var changed = ui.spResults.slice();
                            changed[1] = {title: "different result", sub: "", icon: "", glyph: "", run: function() { root.spotlightTestRuns++; }};
                            ui.spResults = changed;
                            spotlightEvents.mouseRelease(target, target.width / 2, target.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
                            check(ui.pop === "spot" && root.spotlightTestRuns === 2, "changed result is not activated by an old press");
                            console.log("SPOTLIGHT_NATIVE_PASS: hover, click during window updates, changed result, and keyboard selection"); Qt.quit();
                        }
                    }
                }
'''
with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    for name in ('cache', 'config', 'settings', 'runtime'):
        (temp / name).mkdir()
    (temp / 'runtime').chmod(0o700)
    display = os.environ.get('WAYLAND_DISPLAY', '')
    if display and not display.startswith('/'):
        display = str(Path(os.environ['XDG_RUNTIME_DIR']) / display)
    shutil.copytree(project / 'MacShell', temp / 'shell')
    path = temp / 'shell/MacBar.qml'
    text = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtTest\n', 1)
    text = text.replace('    function appRunner(e) { return function () { launchApp(e); }; }',
                        '    property int spotlightTestRuns: 0\n    property string spotlightTestTitle: \"\"\n    function appRunner(e) { return function () { spotlightTestRuns++; spotlightTestTitle = e.name; }; }', 1)
    text = text.replace('                property string pop: ""', probe + '\n                property string pop: ""', 1)
    text = text.replace('                                model: resultRows\n', '                                id: spotlightRows\n                                model: resultRows\n', 1)
    path.write_text(text)
    env = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
               XDG_CACHE_HOME=str(temp / 'cache'), XDG_CONFIG_HOME=str(temp / 'config'),
               XDG_RUNTIME_DIR=str(temp / 'runtime'), WAYLAND_DISPLAY=display,
               MACSHELL_SETTINGS_HOME=str(temp / 'settings'), NIRI_SOCKET=str(temp / 'no-session'),
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(temp / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(temp / 'no-bus'))
    try:
        result = subprocess.run([quickshell(), '-p', str(temp / 'shell')], env=env, capture_output=True, text=True, timeout=20)
        log = result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        log = (error.stdout or b'').decode(errors='replace') + (error.stderr or b'').decode(errors='replace')
        print(log)
        raise SystemExit('Spotlight native UI probe timed out')
    if result.returncode or 'SPOTLIGHT_NATIVE_PASS' not in log:
        print(log)
        raise SystemExit(result.returncode or 1)
    for line in log.splitlines():
        if 'SPOTLIGHT_NATIVE_PASS' in line:
            print(line)
