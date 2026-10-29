#!/usr/bin/env python3
"""Real compositor input checks using guarded surfaces and fake media only."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--list-protocols', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='macshell-widget-input-') as directory:
    root = Path(directory)
    binary = root / 'input-client'
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
    subprocess.run(['cc', '-std=gnu11', '-O2', str(project / 'tests/native/widget-input-client.c'), '-o', str(binary), *flags], check=True)
    protocol = subprocess.run([str(binary), '--list'], capture_output=True, text=True)
    if args.list_protocols:
        print(protocol.stdout, end='')
        raise SystemExit(protocol.returncode)
    if protocol.returncode:
        raise SystemExit('The native input check needs wlr-virtual-pointer v2.')
    output = json.loads(subprocess.check_output(['niri', 'msg', '-j', 'focused-output'], text=True))
    if not output:
        raise SystemExit('No focused test output.')
    logical = output.get('logical') or {}
    if logical.get('width', 0) < 900 or logical.get('height', 0) < 800:
        raise SystemExit('The native input probe needs at least 900×800 logical pixels.')
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell)
    shutil.copyfile(project / 'tests/widget-input-native.qml', shell / 'shell.qml')
    path = shell / 'MacWidgets.qml'
    source = path.read_text()
    source = source.replace('WlrLayershell.namespace: "macwidgets"', 'WlrLayershell.namespace: "macshell-widget-input-front"')
    source = source.replace('root.editing ? WlrLayer.Overlay : WlrLayer.Bottom', 'root.editing ? WlrLayer.Overlay : WlrLayer.Overlay')
    source = source.replace('anchors { left: true; right: true; top: true; bottom: true }',
                            'anchors { left: true; top: true }\n            margins {left: 80; top: 80}\n            implicitWidth: 800; implicitHeight: 700')
    start = source.index('    readonly property var player: {')
    end = source.index('    // MPRIS does not announce', start)
    source = source[:start] + """    property int testPlayCount: 0
    property bool testPlayerAvailable: true
    QtObject {
        id: probePlayer
        property string trackTitle: "Probe track"
        property string trackArtist: "Demo"
        property string trackAlbum: ""
        property string trackArtUrl: ""
        property bool isPlaying: false
        property bool canTogglePlaying: true
        property bool canGoNext: false
        property bool canGoPrevious: false
        property bool shuffleSupported: false
        property bool loopSupported: false
        property bool positionSupported: false
        property bool lengthSupported: false
        property bool canSeek: false
        function togglePlaying() { root.testPlayCount++; }
    }
    readonly property var player: testPlayerAvailable ? probePlayer : null
""" + source[end:]
    path.write_text(source)
    for name in ('cache', 'config', 'settings/macwidgets'):
        (root / name).mkdir(parents=True)
    widgets = [dict(id='p' + str(i), type='player', version=1, output='main',
                    position=dict(column=i % 3, row=i // 3), settings=dict(size='small', style='dark')) for i in range(5)]
    widgets.append(dict(id='clock', type='clock', version=1, output='main', position=dict(column=2, row=1), settings=dict(size='small', style='dark')))
    values = dict(defaults=dict(tempUnit='C', locMode='auto', cityName='', mode='auto', styles={kind: 'liquid' for kind in ('weather', 'calendar', 'clock', 'player')}),
                  desktopOutput='main', outputs={'main': dict(identity=dict(connector=output['name'], make='Demo', model='Probe', serial='probe'))},
                  bindings={output['name']: 'main'}, widgets=widgets)
    (root / 'settings/macwidgets/settings.json').write_text(json.dumps(dict(version=1, revision=1, values=values)))
    environment = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                       XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
                       NIRI_SOCKET=str(root / 'no-session'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                       DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), MACSHELL_INPUT_PROBE_OUTPUT=output['name'], WAYLAND_DEBUG='client')
    qs = quickshell()
    log_path = Path('/tmp/macshell-widget-input-native.log')
    log_stream = log_path.open('w')
    process = subprocess.Popen([qs, '-p', str(shell)], env=environment, stdout=log_stream, stderr=subprocess.STDOUT, start_new_session=True)
    class ProbeNotReady(Exception):
        pass
    def call(method, *arguments):
        if process.poll() is not None:
            raise RuntimeError('The widget input probe exited early; see ' + str(log_path))
        result = subprocess.run([qs, '-p', str(shell), 'ipc', 'call', 'probe', method, *map(str, arguments)],
                                env=environment, text=True, capture_output=True, timeout=3)
        if result.returncode:
            if method == 'state': raise ProbeNotReady()
            raise RuntimeError('Probe IPC ' + method + ': ' + (result.stderr or result.stdout).strip())
        return result.stdout.strip()
    def state():
        return json.loads(call('state'))
    def wait(predicate, label, timeout=5):
        deadline = time.monotonic() + timeout
        last = {}
        while time.monotonic() < deadline:
            try:
                last = state()
                if predicate(last):
                    return last
            except (ProbeNotReady, json.JSONDecodeError):
                pass
            time.sleep(.05)
        raise RuntimeError(label + ': ' + json.dumps(last, ensure_ascii=False))
    def pointer(point, button='left', target=None):
        current = wait(lambda s: s['ready'] and not s['pending'], 'guarded surfaces ready')
        points = [point] + ([target] if target else [])
        # The permanently mapped back panel catches every hole in the front.
        # No pointer request is sent outside this owned 800×700 area.
        for value in points:
            if not (1 <= value['x'] <= 798 and 1 <= value['y'] <= 698):
                raise RuntimeError('Input request outside the owned probe surfaces')
        command = [str(binary), 'drag' if target else 'click', output['name'], str(round(point['x'] + 80)), str(round(point['y'] + 80)),
                   str(current['width']), str(current['height']), button]
        if target:
            command += [str(round(target['x'] + 80)), str(round(target['y'] + 80))]
        subprocess.run(command + ['owned-probe'], check=True, env=environment, timeout=3, capture_output=True)
    try:
        initial = wait(lambda s: s['ready'] and not s['pending'] and s['targets'] == 5 and len(s['points']) == 5, 'five live Player input targets', 8)
        call('focus'); wait(lambda s: s['priorActive'], 'prior window focus')
        time.sleep(.15)
        for index in range(5):
            pointer(state()['points']['p' + str(index)])
            wait(lambda s: s['plays'] == index + 1 and s['priorActive'], 'Player action without keyboard focus theft')
        current = state(); behind = current['behind']
        pointer(dict(x=720, y=660))
        wait(lambda s: s['behind'] == behind + 1, 'gap click passes through')
        clock = next(row for row in state()['rows'] if row['wid'] == 'clock')
        pointer(dict(x=clock['wx'] + 80, y=clock['wy'] + 80))
        wait(lambda s: s['behind'] == behind + 2, 'passive Clock passes through')
        point = state()['points']['p4']; call('setCardVisible', 'p4', 'false')
        wait(lambda s: s['targets'] == 4, 'hidden target removed'); time.sleep(.08)
        pointer(point); wait(lambda s: s['behind'] == behind + 3, 'hidden target has no stale native mask')
        call('setCardVisible', 'p4', 'true'); wait(lambda s: s['targets'] == 5, 'shown target returns')
        call('scale', 'p4', 1.2); time.sleep(.25)
        pointer(state()['points']['p4']); wait(lambda s: s['plays'] == 6, 'scaled target hit region')
        call('scale', 'p4', 1); time.sleep(.25)
        call('media', 'false'); wait(lambda s: s['targets'] == 0, 'unavailable Player releases input'); time.sleep(.08)
        behind = state()['behind']; pointer(point)
        wait(lambda s: s['behind'] == behind + 1, 'unavailable Player passes through')
        call('media', 'true'); wait(lambda s: s['targets'] == 5, 'available Player restores input')
        call('cover', 'true', 'true')
        wait(lambda s: s['targets'] == 0 and s['resources']['activeViews'] == 0 and not s['resources']['clock']['running'], 'known fullscreen releases input and display sources')
        time.sleep(.08); behind = state()['behind']; pointer(point)
        wait(lambda s: s['behind'] == behind + 1, 'culled Player passes through without a stale native mask')
        call('cover', 'true', 'false')
        wait(lambda s: s['targets'] == 5 and s['resources']['clock']['running'], 'unknown geometry keeps widgets and input active')
        call('cover', 'false', 'false')
        old_point = state()['points']['p0']; call('move', 'p0', 0, 2)
        wait(lambda s: not s['pending'] and s['points']['p0']['y'] > old_point['y'] + 300, 'moved card')
        time.sleep(.08); behind = state()['behind']; pointer(old_point)
        wait(lambda s: s['behind'] == behind + 1, 'old moved region cleared')
        pointer(state()['points']['p0']); wait(lambda s: s['plays'] == 7, 'new moved region accepts action')
        call('focus'); wait(lambda s: s['priorActive'], 'focus before editing')
        call('editing', 'true'); wait(lambda s: s['editing'] and s['editorActive'], 'explicit editor keyboard focus')
        pointer(state()['points']['p4']); wait(lambda s: s['selected'] == 'p4' and s['plays'] == 7, 'Edit has priority over playback')
        pointer(state()['points']['p4'], 'right'); wait(lambda s: s['selected'] == 'p4' and s['editorActive'], 'right-click selects and focuses controls')
        row = next(row for row in state()['rows'] if row['wid'] == 'p4')
        pointer(dict(x=row['wx'] + 80, y=row['wy'] + 80), target=dict(x=row['wx'] + 80, y=row['wy'] + 282))
        wait(lambda s: not s['pending'] and s['selected'] == '' and next(item for item in s['saved'] if item['id'] == 'p4')['position']['row'] == 2, 'real drag and stale selection closure')
        assert state()['plays'] == 7
        pointer(state()['points']['p3'], 'right'); wait(lambda s: s['selected'] == 'p3', 'select before external move')
        call('move', 'p3', 0, 0); wait(lambda s: not s['pending'] and s['selected'] == '', 'moving selected card clears actions')
        pointer(state()['points']['p2'], 'right'); wait(lambda s: s['selected'] == 'p2', 'select before delete')
        call('remove', 'p2'); wait(lambda s: not s['pending'] and s['selected'] == '' and len(s['rows']) == 5, 'deleting selected card clears actions')
        call('action', 'widgetEditUndo')
        wait(lambda s: not s['pending'] and len(s['rows']) == 6 and 'p2' in s['points'], 'native Undo restores the exact card')
        pointer(state()['points']['p2'], 'right'); wait(lambda s: s['selected'] == 'p2' and s['editorActive'], 'select before duplicate')
        call('action', 'widgetEditDuplicate')
        copied = wait(lambda s: not s['pending'] and len(s['rows']) == 7 and len(s['points']) == 6, 'native duplicate creates a sixth independent Player')
        copy_id = next(row['wid'] for row in copied['rows'] if row['wid'] not in {'p0', 'p1', 'p2', 'p3', 'p4', 'clock'})
        # The guarded probe surface is 800px wide; put the new card inside it.
        call('move', copy_id, 1, 1); wait(lambda s: not s['pending'] and next(row for row in s['saved'] if row['id'] == copy_id)['position'] == {'column': 1, 'row': 1}, 'duplicate in guarded surface')
        call('sendEscape'); wait(lambda s: not s['editing'] and s['targets'] == 6, 'all six independent input regions after Duplicate and Undo')
        call('editing', 'true'); wait(lambda s: s['editorActive'], 'editor before cleanup')
        call('remove', copy_id); wait(lambda s: not s['pending'] and len(s['rows']) == 6, 'remove only the duplicate')
        pointer(state()['points']['p2'], 'right'); wait(lambda s: s['selected'] == 'p2' and s['editorActive'], 'select before native Remove')
        call('action', 'widgetEditRemove'); wait(lambda s: not s['pending'] and len(s['rows']) == 5, 'native Remove clears only the selected card')
        wait(lambda s: s['editorActive'], 'focus before Escape'); call('sendEscape')
        wait(lambda s: not s['editing'] and not s['editorVisible'] and s['targets'] == 4 and s['priorActive'] and s['restores'] >= 1, 'Escape, remaining input regions and previous focus restoration')
        # Changing a real reserved edge must move native input without writing desired cells.
        token = state()['token']; saved = state()['saved']; point = state()['points']['p1']
        call('reserve', 300)
        wait(lambda s: s['points']['p1']['y'] > point['y'] + 260, 'reserved bar moves card and native region')
        time.sleep(.1); behind = state()['behind']; pointer(point)
        wait(lambda s: s['behind'] == behind + 1, 'old region cleared after reserved-area change')
        pointer(state()['points']['p1']); wait(lambda s: s['plays'] == 8, 'reflowed native input accepts action')
        assert state()['token'] == token and state()['saved'] == saved, 'Temporary reflow must not save desired cells'
        call('editing', 'true'); wait(lambda s: s['editorActive'], 'editor before reserved-area change')
        call('reserve', 0); wait(lambda s: not s['editing'] and not s['editorVisible'], 'geometry change closes editor safely')
        point = state()['points']['p1']; call('clearPlayers')
        wait(lambda s: not s['pending'] and s['targets'] == 0 and len(s['rows']) == 1, 'last interactive target removed')
        time.sleep(.1); behind = state()['behind']; pointer(point)
        wait(lambda s: s['behind'] == behind + 1, 'empty native input union passes through')
        before_token = state()['token']; call('editing', 'true'); wait(lambda s: s['editorActive'], 'editor opens for passive types')
        pointer(dict(x=clock['wx'] + 80, y=clock['wy'] + 80), 'right')
        wait(lambda s: s['selected'] == 'clock', 'passive card actions only in Edit'); call('done')
        wait(lambda s: not s['editing'] and s['priorActive'], 'Done returns focus')
        assert state()['token'] == before_token, 'Selection and editor focus must not write settings'
        call('displayWidgets', 'false')
        wait(lambda s: not s['pending'] and s['resources']['views'] == 0 and not s['resources']['clock']['running'], 'disabled desktop destroys all visual consumers')
        call('displayWidgets', 'true')
        wait(lambda s: not s['pending'] and s['resources']['views'] == 1 and s['resources']['clock']['running'], 'enabled desktop recreates the saved Clock')
        call('addActivity')
        current = wait(lambda s: not s['pending'] and s['targets'] == 1 and s['resources']['sources']['stats'] == 1, 'Activity has a native input region and a shared subscription')
        activity_id = next(row['wid'] for row in current['rows'] if row['wtype'] == 'activity')
        call('move', activity_id, 0, 0)
        wait(lambda s: not s['pending'] and activity_id in s['points'] and s['points'][activity_id]['x'] < 300, 'Activity inside the guarded surface')
        time.sleep(.1); pointer(state()['points'][activity_id])
        wait(lambda s: json.loads(call('activity'))['opens'] == 1, 'real compositor click opens Activity details')
        assert json.loads(call('activity'))['output'] == output['name'], 'Activity must open on its own output'
        call('editing', 'true'); wait(lambda s: s['editorActive'], 'Activity editor')
        pointer(state()['points'][activity_id]); wait(lambda s: s['selected'] == activity_id, 'Edit takes priority over Activity details')
        assert json.loads(call('activity'))['opens'] == 1
        call('done'); wait(lambda s: not s['editing'], 'finish Activity editing')
        point = state()['points'][activity_id]; call('remove', activity_id)
        wait(lambda s: not s['pending'] and s['targets'] == 0 and s['resources']['sources']['stats'] == 0, 'Activity removal releases source and input')
        time.sleep(.1); behind = state()['behind']; pointer(point)
        wait(lambda s: s['behind'] == behind + 1, 'removed Activity leaves no native input region')
        call('addBatteries')
        current = wait(lambda s: not s['pending'] and s['resources']['sources']['batteries'] == 1, 'Batteries subscribes without an input region')
        batteries_id = next(row['wid'] for row in current['rows'] if row['wtype'] == 'batteries')
        call('move', batteries_id, 0, 0)
        current = wait(lambda s: not s['pending'] and next(row for row in s['saved'] if row['id'] == batteries_id)['position']['column'] == 0, 'Batteries inside the guarded surface')
        row = next(row for row in current['rows'] if row['wid'] == batteries_id)
        point = dict(x=row['wx'] + 80, y=row['wy'] + 80)
        time.sleep(.1); behind = state()['behind']; pointer(point)
        wait(lambda s: s['behind'] == behind + 1 and s['targets'] == 0, 'Batteries remains click-through')
        call('editing', 'true'); wait(lambda s: s['editorActive'], 'Batteries editor')
        pointer(point, 'right'); wait(lambda s: s['selected'] == batteries_id, 'Batteries selection works in Edit')
        call('done'); wait(lambda s: not s['editing'], 'finish Batteries editing')
        call('remove', batteries_id)
        wait(lambda s: not s['pending'] and s['resources']['sources']['batteries'] == 0, 'Batteries releases its source')
        call('quit'); process.wait(timeout=5)
        log_stream.flush()
        log = log_path.read_text()
        focus_modes = re.findall(r'set_keyboard_interactivity\((\d+)\)', log)
        assert focus_modes and set(focus_modes) == {'0', '1'} and focus_modes[-1] == '0', 'Only Arrange may request exclusive keyboard focus, then release it'
        assert not re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign|Failed to load configuration', log), 'QML runtime error'
        print('MACSHELL_WIDGET_INPUT_NATIVE_PASS: six Players, Activity, passive Batteries/Edit/removal, native masks, fullscreen, disable/enable, drag, Escape/Done, focus restoration and reserved-area reflow')
    except Exception:
        log_stream.flush()
        for line in log_path.read_text().splitlines():
            if any(word in line for word in ('ERROR', 'Error', 'FAIL', 'Binding loop')):
                print(line)
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
        log_stream.close()
