#!/usr/bin/env python3
"""Check Dock Tahoe glass labels and context menu in nested niri.

Runs GPU DockGlassPanel tests, then a nested MacDock copy: hover dwell, showLabels,
liquid/solid live blur, right-click menu objectNames and tail. Does not change the
installed profile or the live session.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

spec = importlib.util.spec_from_file_location('showcase', project / 'scripts/capture-showcase.py')
showcase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(showcase)

QML_ERRORS = r'TypeError|ReferenceError|Binding loop|Unable to assign|Failed to load configuration'
SIZE = (1100, 700)


def run(command, environment=None, timeout=10):
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(command[0] + ': ' + (result.stderr or result.stdout).strip())
    return result.stdout


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def owned_socket(path, token):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(path)
        pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    if uid != os.getuid():
        raise RuntimeError('Nested niri socket is owned by another user')
    environ = Path('/proc', str(pid), 'environ').read_bytes().split(b'\0')
    if ('MACSHELL_NESTED_TEST_TOKEN=' + token).encode() not in environ:
        raise RuntimeError('Refusing input: compositor is not the test niri')


def host_size():
    outputs = json.loads(run(['niri', 'msg', '--json', 'outputs']))
    focused = json.loads(run(['niri', 'msg', '--json', 'focused-output']))
    logical = (focused or next(iter(outputs.values())))['logical']
    return int(logical['width']), int(logical['height'])


def qmltestrunner():
    env = os.environ.get('MACSHELL_QML_TEST_RUNNER')
    if env:
        return env
    qt_root = os.environ.get('QT_ROOT_DIR')
    if qt_root:
        candidate = Path(qt_root) / 'bin' / 'qmltestrunner'
        if os.access(candidate, os.X_OK):
            return str(candidate)
    for name in ('qmltestrunner6', '/usr/lib/qt6/bin/qmltestrunner', '/usr/lib/qt6/qmltestrunner', 'qmltestrunner'):
        path = name if name.startswith('/') else shutil.which(name)
        if path and os.access(path, os.X_OK):
            return path
    raise RuntimeError('Qt 6 qmltestrunner not found. Install Qt Quick Test or set MACSHELL_QML_TEST_RUNNER.')


def patch_shell(shell):
    dock = shell / 'MacDock.qml'
    text = dock.read_text()
    if 'function demoSettings() { return prefsWindow; }' not in text:
        raise RuntimeError('Dock showcase insertion point changed')
    text = text.replace('function demoSettings() { return prefsWindow; }\n',
                        'function demoSettings() { return prefsWindow; }\n    property var demoUi: null\n', 1)
    marker = '                id: ui\n                anchors.fill: parent\n'
    probe = (project / 'tests/dock-click-probe.qml').read_text()
    if marker not in text:
        raise RuntimeError('Dock panel probe insertion point changed')
    if 'objectName: "dockContextMenu"' not in text or 'DockGlassPanel' not in text:
        raise RuntimeError('Temp Dock copy is missing DockGlassPanel context menu')
    text = text.replace(marker, marker + '                Component.onCompleted: root.demoUi = ui\n' + probe, 1)
    dock.write_text(text)
    showcase.replace(shell / 'shell.qml', 'ShellRoot {', 'ShellRoot {\n' + (project / 'tests/dock-panel-ipc.qml').read_text())


def patch_settings(root):
    dock = json.loads((root / 'settings/macdock/settings.json').read_text())
    dock.update(dockEnabled=True, dockStyle='liquid', hideMode='never', showTrash=True, showThumbs=False,
                windowCapture=False, magnificationEnabled=False, showLabels=True)
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dock))
    bar = json.loads((root / 'settings/macbar/settings.json').read_text())
    bar.update(barWidgets=['clock'], ccControls=[], statsMetrics=[], showTray=False, showSearch=False, uiSounds=False)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(bar))
    widgets = json.loads((root / 'settings/macwidgets/settings.json').read_text())
    widgets['values']['widgets'] = []
    (root / 'settings/macwidgets/settings.json').write_text(json.dumps(widgets))


def compile_pointer(root):
    binary = root / 'input-client'
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
    subprocess.run(['cc', '-std=gnu11', '-O2', str(project / 'tests/native/widget-input-client.c'), '-o', str(binary), *flags], check=True)
    listed = subprocess.run([str(binary), '--list'], capture_output=True, text=True, env=dict(os.environ))
    if listed.returncode:
        raise RuntimeError('The Dock glass-panel check needs wlr-virtual-pointer v2.')
    return binary


def menu_item(state, label):
    for item in state.get('menuItems') or []:
        if item.get('label') == label:
            return item
    return None


def hover_ok(state, key, dark, live):
    cell = (state.get('cells') or {}).get(key) or {}
    if not cell.get('tipOn'):
        return False
    tip = cell.get('tip') or {}
    if tip.get('shown', 0) < 0.4 or tip.get('width', 0) < 8:
        return False
    if cell.get('tipName') != 'dockHoverLabel':
        return False
    if cell.get('tipTailH', 0) < 2 or cell.get('tipTailW', 0) < 8:
        return False
    if cell.get('tipDark') is not dark:
        return False
    if live is True and not cell.get('tipLive'):
        return False
    if live is False and cell.get('tipLive'):
        return False
    return True


def menu_ok(state, dark, live):
    if not state.get('menuOpen'):
        return False
    menu = state.get('menu') or {}
    if menu.get('name') != 'dockContextMenu':
        return False
    if menu.get('shown', 0) < 0.4 or menu.get('width', 0) < 80:
        return False
    if menu.get('tailH', 0) < 2 or menu.get('tailW', 0) < 8:
        return False
    if menu.get('dark') is not dark:
        return False
    if not menu.get('frozen'):
        return False
    if live is True and not menu.get('live'):
        return False
    if live is False and menu.get('live'):
        return False
    if not menu_item(state, 'Empty Trash') or not menu_item(state, 'Open') or not menu_item(state, 'Settings…'):
        return False
    return True


def main():
    parent_display = os.environ.get('WAYLAND_DISPLAY')
    parent_socket = os.environ.get('NIRI_SOCKET')
    if not parent_display or not parent_socket:
        raise RuntimeError('A parent Wayland/niri session is required to start nested niri')
    host_w, host_h = host_size()
    width, height = min(SIZE[0], host_w - 40), min(SIZE[1], host_h - 40)
    if width < 900 or height < 560:
        raise RuntimeError('Host output is too small for the nested Dock glass-panel check')
    token = uuid.uuid4().hex
    runner = qmltestrunner()
    with tempfile.TemporaryDirectory(prefix='macshell-dock-panel-') as temporary:
        root = Path(temporary)
        binary = compile_pointer(root)
        shell = showcase.prepare(root, 'en')
        patch_shell(shell)
        patch_settings(root)
        log_path = Path('/tmp/macshell-dock-glass-panel.log')
        gpu_log = Path('/tmp/macshell-dock-glass-panel-gpu.log')
        environment = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
            XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'), XDG_DATA_DIRS=str(root / 'data'),
            MACSHELL_SETTINGS_HOME=str(root / 'settings'), MACSHELL_NIRI_PROFILE=str(root / 'niri'),
            QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic', QT_QPA_PLATFORM='wayland',
            DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            PIPEWIRE_REMOTE='macshell-dock-panel-no-pipewire', PULSE_SERVER='unix:' + str(root / 'no-pulse'),
            MACSHELL_SHOWCASE_DARK_WALL=str(showcase.ASSETS / 'wallpaper-dark.svg'),
            MACSHELL_SHOWCASE_LIGHT_WALL=str(showcase.ASSETS / 'wallpaper.svg'),
            MACSHELL_SHOWCASE_ART=(showcase.ASSETS / 'album.svg').as_uri(),
            MACSHELL_NESTED_TEST_TOKEN=token)
        environment.pop('QT_QUICK_BACKEND', None)
        nested = client = None
        with log_path.open('w') as log:
            try:
                nested = subprocess.Popen(['niri', '--config', str(root / 'niri/config.kdl'), '--',
                                           sys.executable, str(root / 'child.py')],
                                          env=environment, stdout=log, stderr=log)
                deadline = time.monotonic() + 10
                while not (root / 'nested.json').exists():
                    if nested.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Nested niri did not start: ' + str(log_path))
                    time.sleep(.1)
                host_windows = json.loads(run(['niri', 'msg', '--json', 'windows']))
                own = next((window for window in host_windows if window.get('pid') == nested.pid), None)
                if not own:
                    raise RuntimeError('Cannot identify the owned nested compositor window')
                ident = str(own['id'])
                if not own['is_floating']:
                    run(['niri', 'msg', 'action', 'toggle-window-floating', '--id', ident])
                run(['niri', 'msg', 'action', 'set-window-width', '--id', ident, str(width)])
                run(['niri', 'msg', 'action', 'set-window-height', '--id', ident, str(height)])
                run(['niri', 'msg', 'action', 'move-floating-window', '--id', ident, '-x', '80', '-y', '60'])
                run(['niri', 'msg', 'action', 'focus-window', '--id', ident])
                nested_env = dict(environment)
                nested_env.update(json.loads((root / 'nested.json').read_text()))
                if nested_env.get('WAYLAND_DISPLAY') in (None, parent_display):
                    raise RuntimeError('Refusing input: nested Wayland display is the parent session')
                if nested_env.get('NIRI_SOCKET') in (None, parent_socket):
                    raise RuntimeError('Refusing input: nested niri socket is the parent session')
                owned_socket(nested_env['NIRI_SOCKET'], token)
                time.sleep(.4)
                transform = 'Normal'

                def nested_outputs():
                    return json.loads(run(['niri', 'msg', '--json', 'outputs'], nested_env))

                def wait_output():
                    nonlocal transform
                    deadline = time.monotonic() + 8
                    last = {}
                    while time.monotonic() < deadline:
                        last = nested_outputs()
                        if len(last) == 1:
                            info = next(iter(last.values()))
                            logical = info['logical']
                            if (logical['width'], logical['height']) == (width, height):
                                transform = logical.get('transform') or 'Normal'
                                return next(iter(last))
                        time.sleep(.1)
                    raise RuntimeError('nested output size: ' + repr(last))

                output_name = wait_output()
                gpu = subprocess.run(
                    [runner, '-input', str(project / 'tests/gpu/tst_DockGlassPanel.qml'), '-o', '-,txt'],
                    env=nested_env, capture_output=True, text=True, timeout=90)
                gpu_log.write_text(gpu.stdout + '\n' + gpu.stderr)
                print(gpu.stdout.strip() or gpu.stderr.strip(), flush=True)
                if gpu.returncode or not re.search(r'\d+ passed', gpu.stdout + gpu.stderr):
                    raise RuntimeError('GPU DockGlassPanel tests failed; see ' + str(gpu_log))
                print('GPU_DOCK_GLASS_PANEL_PASS', flush=True)

                qs = quickshell()
                client = subprocess.Popen([qs, '-p', str(shell)], env=nested_env, stdout=log, stderr=log)

                def ipc(method, *values):
                    if client.poll() is not None:
                        raise RuntimeError('Dock panel shell exited: ' + log_path.read_text()[-4000:])
                    return run([qs, '-p', str(shell), 'ipc', 'call', 'dockpanel', method, *map(str, values)], nested_env)

                def probe():
                    return json.loads(ipc('state'))

                def dump(state):
                    try:
                        run(['grim', '-o', output_name, '/tmp/macshell-dock-panel-fail.png'], nested_env)
                    except Exception:
                        pass
                    log.flush()
                    print('PROBE ' + json.dumps(state, ensure_ascii=False)[:2200], flush=True)
                    print('LOGTAIL ' + log_path.read_text()[-1800:], flush=True)

                def wait(predicate, label, timeout=8):
                    deadline = time.monotonic() + timeout
                    last = {}
                    while time.monotonic() < deadline:
                        try:
                            last = probe()
                            if predicate(last):
                                return last
                        except (ValueError, RuntimeError):
                            if client.poll() is not None:
                                raise
                        time.sleep(.08)
                    dump(last)
                    raise RuntimeError(label + ': ' + json.dumps(last, ensure_ascii=False)[:1400])

                def map_point(x, y, screen_w, screen_h):
                    x, y = int(round(x)), int(round(y))
                    if transform == 'Flipped180':
                        y = screen_h - y
                    elif transform == '180':
                        x, y = screen_w - x, screen_h - y
                    elif transform == 'Flipped':
                        x = screen_w - x
                    return max(0, min(screen_w - 1, x)), max(0, min(screen_h - 1, y))

                def pointer(kind, x, y, extra=None):
                    current = probe()
                    screen_w, screen_h = int(current['screenW']), int(current['screenH'])
                    x, y = map_point(x, y, screen_w, screen_h)
                    if not (0 <= x < screen_w and 0 <= y < screen_h):
                        raise RuntimeError('Input request outside the nested output: %s,%s of %sx%s' % (x, y, screen_w, screen_h))
                    command = [str(binary), kind, output_name, str(x), str(y), str(screen_w), str(screen_h)]
                    if extra:
                        command += extra
                    listed = subprocess.run([str(binary), '--list'], capture_output=True, text=True, env=nested_env, timeout=3)
                    if listed.returncode:
                        raise RuntimeError('Nested compositor has no virtual pointer v2: ' + listed.stderr)
                    subprocess.run(command + ['owned-probe'], check=True, env=nested_env, timeout=3, capture_output=True)
                    time.sleep(.05)

                def click_box(box, fx=0.5, fy=0.5, button='left'):
                    if not box or box.get('width', 0) < 2:
                        dump(probe())
                        raise RuntimeError('click target missing')
                    pointer('click', box['x'] + box['width'] * fx, box['y'] + box['height'] * fy, [button])

                def move_to(x, y):
                    pointer('move', x, y)

                def hover_cell(key):
                    current = wait(lambda s: s.get('cells', {}).get(key) and s['cells'][key]['width'] > 2, 'cell ' + key)
                    cell = current['cells'][key]
                    move_to(cell['x'] + cell['width'] * 0.5, cell['y'] + cell['height'] * 0.55)
                    return current

                def panel_flow(theme_name, dark):
                    ipc('theme', 'true' if dark else 'false')
                    ipc('dockStyle', 'liquid')
                    ipc('labels', 'true')
                    ipc('hideMode', 'never')
                    wait(lambda s: s.get('dark') is dark and not s.get('menuOpen') and not s.get('tucked')
                         and s.get('showLabels') and s.get('dockStyle') == 'liquid', theme_name + ' theme', 8)
                    opened = wait(lambda s: s.get('ready') and s.get('cells', {}).get('__trash')
                                  and s['cells']['__trash']['width'] > 2, 'Trash icon ready', 20)
                    if opened.get('labelK', 0) < 0.7:
                        dump(opened)
                        raise RuntimeError('labelK missing')
                    move_to(width * 0.5, 24)
                    wait(lambda s: not (s.get('cells') or {}).get('__trash', {}).get('tipOn'), 'tip closed after leaving', 4)
                    hover_cell('__trash')
                    hovered = wait(lambda s: hover_ok(s, '__trash', dark, True), theme_name + ' liquid hover label', 4)
                    print('HOVER ' + theme_name + ' live=' + str(hovered['cells']['__trash']['tipLive'])
                          + ' tailH=' + str(hovered['cells']['__trash']['tipTailH']), flush=True)
                    ipc('labels', 'false')
                    wait(lambda s: not s.get('showLabels') and not (s.get('cells') or {}).get('__trash', {}).get('tipOn'),
                         'showLabels hides the hover label', 4)
                    ipc('labels', 'true')
                    hover_cell('__trash')
                    wait(lambda s: hover_ok(s, '__trash', dark, True), 'hover label returns with showLabels', 4)
                    click_box(probe()['cells']['__trash'], button='right')
                    menu = wait(lambda s: menu_ok(s, dark, True), theme_name + ' liquid context menu')
                    if menu_item(menu, 'Empty Trash')['disabled'] is not True:
                        dump(menu)
                        raise RuntimeError('Empty Trash should stay disabled on the empty isolated trash')
                    print('MENU ' + theme_name + ' live=' + str(menu['menu']['live'])
                          + ' frozen=' + str(menu['menu']['frozen'])
                          + ' tailH=' + str(menu['menu']['tailH']), flush=True)
                    away = menu['menu']
                    pointer('click', max(8, away['x'] - 24), away['y'] + 8, ['left'])
                    wait(lambda s: not s.get('menuOpen'), 'click-away closes the glass menu')
                    ipc('dockStyle', 'blur')
                    wait(lambda s: s.get('dockStyle') == 'blur' and not s.get('liquidActive'), 'blur dock style', 6)
                    hover_cell('__trash')
                    wait(lambda s: hover_ok(s, '__trash', dark, False), theme_name + ' solid hover label', 4)
                    click_box(probe()['cells']['__trash'], button='right')
                    wait(lambda s: menu_ok(s, dark, False), theme_name + ' solid context menu')
                    ipc('theme', 'true' if dark else 'false')
                    wait(lambda s: not s.get('menuOpen'), 'menu closed before next theme', 4)
                    ipc('dockStyle', 'liquid')
                    print('FLOW ' + theme_name, flush=True)

                wait(lambda s: s.get('ready') and s.get('glass') in ('ready', 'failed') and s.get('cells', {}).get('__trash'),
                     'Dock panel probe ready', 40)
                panel_flow('dark', True)
                panel_flow('light', False)
                ipc('shutDown')
                client.wait(timeout=8)
                client = None
                log.flush()
                errors = log_path.read_text()
                if re.search(QML_ERRORS, errors):
                    raise RuntimeError('QML errors in ' + str(log_path) + '\n' + errors[-4000:])
                print('MACSHELL_DOCK_GLASS_PANEL_PASS: GPU panel, nested hover/menu, liquid/solid, both themes', flush=True)
            finally:
                stop(client)
                stop(nested)


if __name__ == '__main__':
    main()
