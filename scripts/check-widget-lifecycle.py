#!/usr/bin/env python3
"""Real widget consumers/providers with fake network, media and logical output."""
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

with tempfile.TemporaryDirectory(prefix='macshell-widget-lifecycle-') as directory:
    root = Path(directory)
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell)
    shutil.copyfile(project / 'tests/widget-lifecycle.qml', shell / 'shell.qml')
    shutil.copyfile(project / 'tests/fixtures/widget_fetch.py', shell / 'widget_fetch.py')
    path = shell / 'MacWidgets.qml'
    source = path.read_text()
    start = source.index('    // ───────────── the desktop layer')
    end = source.index('    function resourceState()', start)
    assert source[start:end].count('    Variants {') == 1
    source = source[:start] + source[end:]
    start = source.index('    readonly property var player: {')
    end = source.index('    // MPRIS does not announce', start)
    source = source[:start] + '''    property int testPositionSignals: 0
    property alias testPlayer: fixturePlayer
    QtObject {
        id: fixturePlayer
        property string trackTitle: "Fixture track"
        property string trackArtist: "Demo"
        property string trackAlbum: "Album"
        property string trackArtUrl: ""
        property bool isPlaying: true
        property bool shuffleSupported: false
        property bool loopSupported: false
        property bool positionSupported: true
        property bool lengthSupported: true
        property bool canSeek: true
        property real position: 10
        property real length: 120
        onPositionChanged: root.testPositionSignals++
    }
    readonly property var player: fixturePlayer
''' + source[end:]
    path.write_text(source)
    for name in ('cache', 'config', 'runtime', 'settings/macwidgets', 'jobs'):
        (root / name).mkdir(parents=True)
    (root / 'runtime').chmod(0o700)
    for kind in ('weather', 'lyrics'):
        (root / ('jobs/' + kind + '.started.json')).write_text('{}')
    (root / 'jobs/weather.json').write_text('{}')
    values = dict(defaults=dict(tempUnit='C', locMode='city', cityName='Fixture', mode='auto',
                               styles={kind: 'liquid' for kind in ('weather', 'calendar', 'clock', 'player')}),
                  desktopOutput='main', outputs={'main': dict(identity=dict(connector='DP-1', serial='one'))},
                  bindings={'DP-1': 'main'}, widgets=[dict(id=key, type=kind, version=1, output='main', position=dict(column=column, row=0),
                      settings=dict(size=size, style=style)) for key, kind, column, size, style in [
                          ('a', 'clock', 0, 'small', 'light'), ('b', 'clock', 1, 'small', 'dark'),
                          ('c', 'calendar', 2, 'small', 'normal'), ('w', 'weather', 3, 'medium', 'normal'), ('p', 'player', 6, 'large', 'dark')]])
    (root / 'settings/macwidgets/settings.json').write_text(json.dumps(dict(version=1, revision=1, values=values)))
    environment = {key: value for key, value in os.environ.items() if key not in ('DISPLAY', 'WAYLAND_DISPLAY')}
    environment.update(QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic', QT_QUICK_BACKEND='software',
                       XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                       MACSHELL_SETTINGS_HOME=str(root / 'settings'), MACSHELL_WIDGET_TEST_JOBS=str(root / 'jobs'), NIRI_SOCKET=str(root / 'no-session'),
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    result = subprocess.run([quickshell(), '-p', str(shell)], env=environment, capture_output=True, text=True, timeout=45)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-widget-lifecycle.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR', 'Error', 'FAIL', 'PASS', 'Binding loop')):
            print(line)
    if result.returncode or 'MACSHELL_WIDGET_LIFECYCLE_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign|Failed to load configuration', log):
        raise SystemExit(result.returncode or 1)
    events = [json.loads(line) for line in (root / 'jobs/events.jsonl').read_text().splitlines()]
    assert any(event['event'] == 'cancelled' and event['kind'] == 'weather' for event in events)
    assert any(event['event'] == 'cancelled' and event['kind'] == 'lyrics' for event in events)
    for pid in {event['pid'] for event in events}:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise AssertionError('Request process survived the final consumer: ' + str(pid))
    print('All request worker PIDs exited; no network or user media was used.')
