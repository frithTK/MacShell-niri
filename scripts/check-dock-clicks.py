#!/usr/bin/env python3
"""Click Dock menus, bounce and hide in an isolated nested niri.

Uses a fixture desktop entry, isolated Trash and a virtual pointer bound to the
nested output only. Does not change the installed profile or the live session.
Never calls ktrash or the host file manager.
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
PROBE_ID = 'org.macshell.DockProbe'
PROBE_KEY = PROBE_ID.lower()
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


def patch_shell(shell, probe_app, pid_path):
    dock = shell / 'MacDock.qml'
    text = dock.read_text()
    if 'function demoSettings() { return prefsWindow; }' not in text:
        raise RuntimeError('Dock showcase insertion point changed')
    text = text.replace('function demoSettings() { return prefsWindow; }\n',
                        'function demoSettings() { return prefsWindow; }\n    property var demoUi: null\n', 1)
    marker = '                id: ui\n                anchors.fill: parent\n'
    probe = (project / 'tests/dock-click-probe.qml').read_text()
    if marker not in text:
        raise RuntimeError('Dock probe insertion point changed')
    text = text.replace(marker, marker + '                Component.onCompleted: root.demoUi = ui\n' + probe, 1)
    if 'd=\\"${XDG_DATA_HOME:-$HOME/.local/share}/Trash\\"; "' not in text:
        raise RuntimeError('Dock emptyTrash isolated fallback changed')
    launch = '            L[item.key] = Date.now();\n            launching = L;\n'
    hook = (launch +
            '            if (item.key === "org.macshell.dockprobe") {\n'
            '                Quickshell.execDetached(["sh", "-c", Quickshell.env("MACSHELL_DOCK_PROBE_EXEC")]);\n'
            '                pruneTimer.restart();\n'
            '                return;\n'
            '            }\n')
    if launch not in text:
        raise RuntimeError('Dock activate() launch point changed')
    dock.write_text(text.replace(launch, hook, 1))
    showcase.replace(shell / 'shell.qml', 'ShellRoot {', 'ShellRoot {\n' + (project / 'tests/dock-click-ipc.qml').read_text())
    icon = str(project / 'MacShell/assets/music-app.svg')
    (probe_app.parent / (PROBE_ID + '.desktop')).write_text(
        '[Desktop Entry]\nType=Application\nName=Dock Probe\nExec=%s %s\nIcon=%s\n'
        'StartupWMClass=org.macshell.DockProbe\nCategories=Utility;\n' % (sys.executable, probe_app, icon))
    pid_path.parent.mkdir(parents=True, exist_ok=True)


def patch_settings(root):
    dock = json.loads((root / 'settings/macdock/settings.json').read_text())
    dock.update(dockEnabled=True, hideMode='never', showTrash=True, showThumbs=False, windowCapture=False,
                bounceOnLaunch=True, magnificationEnabled=False, showLabels=True)
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dock))
    pinned = json.loads((root / 'settings/macdock/pinned.json').read_text())
    pinned = [PROBE_ID] + [item for item in pinned if item != PROBE_ID]
    (root / 'settings/macdock/pinned.json').write_text(json.dumps(pinned))
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
        raise RuntimeError('The Dock click check needs wlr-virtual-pointer v2.')
    return binary


def menu_item(state, label):
    for item in state.get('menuItems') or []:
        if item.get('label') == label:
            return item
    return None


def main():
    parent_display = os.environ.get('WAYLAND_DISPLAY')
    parent_socket = os.environ.get('NIRI_SOCKET')
    if not parent_display or not parent_socket:
        raise RuntimeError('A parent Wayland/niri session is required to start nested niri')
    host_w, host_h = host_size()
    width, height = min(SIZE[0], host_w - 40), min(SIZE[1], host_h - 40)
    if width < 900 or height < 560:
        raise RuntimeError('Host output is too small for the nested Dock click check')
    token = uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='macshell-dock-clicks-') as temporary:
        root = Path(temporary)
        binary = compile_pointer(root)
        pid_path = root / 'probe.pid'
        shell = showcase.prepare(root, 'en')
        probe_app = root / 'data/applications/dock-probe-app.py'
        shutil.copyfile(project / 'tests/dock-probe-app.py', probe_app)
        probe_app.chmod(0o755)
        patch_shell(shell, probe_app, pid_path)
        patch_settings(root)
        trash_dir = root / 'data/Trash/files'
        trash_dir.mkdir(parents=True)
        (root / 'data/Trash/info').mkdir(parents=True, exist_ok=True)
        log_path = Path('/tmp/macshell-dock-clicks.log')
        environment = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
            XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'), XDG_DATA_DIRS=str(root / 'data'),
            MACSHELL_SETTINGS_HOME=str(root / 'settings'), MACSHELL_NIRI_PROFILE=str(root / 'niri'),
            QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic', QT_QPA_PLATFORM='wayland',
            DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            PIPEWIRE_REMOTE='macshell-dock-clicks-no-pipewire', PULSE_SERVER='unix:' + str(root / 'no-pulse'),
            MACSHELL_SHOWCASE_DARK_WALL=str(showcase.ASSETS / 'wallpaper-dark.svg'),
            MACSHELL_SHOWCASE_LIGHT_WALL=str(showcase.ASSETS / 'wallpaper.svg'),
            MACSHELL_SHOWCASE_ART=(showcase.ASSETS / 'album.svg').as_uri(),
            MACSHELL_NESTED_TEST_TOKEN=token, MACSHELL_DOCK_PROBE_PID=str(pid_path),
            MACSHELL_DOCK_PROBE_EXEC='%s %s >>/tmp/macshell-dock-probe-app.log 2>&1' % (sys.executable, probe_app))
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

                def map_point(x, y, screen_w, screen_h):
                    x, y = int(round(x)), int(round(y))
                    if transform == 'Flipped180':
                        y = screen_h - y
                    elif transform == '180':
                        x, y = screen_w - x, screen_h - y
                    elif transform == 'Flipped':
                        x = screen_w - x
                    return max(0, min(screen_w - 1, x)), max(0, min(screen_h - 1, y))

                output_name = wait_output()
                qs = quickshell()
                client = subprocess.Popen([qs, '-p', str(shell)], env=nested_env, stdout=log, stderr=log)

                def ipc(target, method, *values):
                    if client.poll() is not None:
                        raise RuntimeError('Dock shell exited: ' + log_path.read_text()[-4000:])
                    return run([qs, '-p', str(shell), 'ipc', 'call', target, method, *map(str, values)], nested_env)

                def probe():
                    return json.loads(ipc('dockprobe', 'state'))

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

                def dump(state):
                    try:
                        run(['grim', '-o', output_name, '/tmp/macshell-dock-click-fail.png'], nested_env)
                    except Exception:
                        pass
                    try:
                        print('LAYERS ' + run(['niri', 'msg', 'layers'], nested_env)[:1500], flush=True)
                    except Exception as error:
                        print('LAYERS ' + repr(error), flush=True)
                    try:
                        print('WINDOWS ' + run(['niri', 'msg', '--json', 'windows'], nested_env)[:1500], flush=True)
                    except Exception as error:
                        print('WINDOWS ' + repr(error), flush=True)
                    app_log = Path('/tmp/macshell-dock-probe-app.log')
                    if app_log.exists():
                        print('APPLOG ' + app_log.read_text()[-1500:], flush=True)
                    log.flush()
                    print('PROBE ' + json.dumps(state, ensure_ascii=False)[:2200], flush=True)

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

                def click_cell(key, button='left'):
                    current = wait(lambda s: s.get('cells', {}).get(key) and s['cells'][key]['width'] > 2, 'cell ' + key)
                    click_box(current['cells'][key], button=button)

                def click_menu(label):
                    current = wait(lambda s: s.get('menuOpen') and menu_item(s, label), 'menu ' + label)
                    item = menu_item(current, label)
                    if item['shown'] < 0.4:
                        dump(current)
                        raise RuntimeError('menu item not shown: ' + label)
                    click_box(item)

                def move_to(x, y):
                    pointer('move', x, y)

                def close_probe_app():
                    if pid_path.exists():
                        try:
                            os.kill(int(pid_path.read_text().strip()), 15)
                        except (OSError, ValueError):
                            pass
                    try:
                        windows = json.loads(run(['niri', 'msg', '--json', 'windows'], nested_env))
                    except RuntimeError:
                        windows = []
                    for window in windows:
                        app = (window.get('app_id') or '').lower()
                        title = window.get('title') or ''
                        if 'dockprobe' in app or 'Dock Probe' in title:
                            run(['niri', 'msg', 'action', 'close-window', '--id', str(window['id'])], nested_env)

                def click_flow(theme_name, dark):
                    ipc('dockprobe', 'theme', 'true' if dark else 'false')
                    ipc('dockprobe', 'hideMode', 'never')
                    ipc('dockprobe', 'prefs', 'false')
                    wait(lambda s: s.get('dark') is dark and not s.get('menuOpen') and not s.get('tucked'), theme_name + ' theme', 8)
                    opened = wait(lambda s: s.get('ready') and s.get('cells', {}).get('__trash') and s['cells'].get(PROBE_KEY),
                                  'Dock icons ready', 20)
                    if opened['cells']['__trash']['shown'] < 0.5:
                        dump(opened)
                        raise RuntimeError('Trash icon is not shown')
                    click_cell('__trash', 'right')
                    trash_menu = wait(lambda s: s.get('menuOpen') and menu_item(s, 'Empty Trash') and menu_item(s, 'Open')
                                      and menu_item(s, 'Settings…'), 'Trash menu')
                    empty = menu_item(trash_menu, 'Empty Trash')
                    if not empty['disabled']:
                        dump(trash_menu)
                        raise RuntimeError('Empty Trash was enabled on an empty isolated trash')
                    click_box(empty)
                    time.sleep(.25)
                    after_disabled = probe()
                    if after_disabled.get('trashFull'):
                        dump(after_disabled)
                        raise RuntimeError('Disabled Empty Trash emptied the trash')
                    if after_disabled.get('menuOpen'):
                        away = after_disabled['menu']
                        pointer('click', max(8, away['x'] - 24), away['y'] + 8, ['left'])
                    wait(lambda s: not s.get('menuOpen'), 'click-away closes the Dock menu')
                    (trash_dir / 'probe.txt').write_text('isolated dock trash')
                    wait(lambda s: s.get('trashFull'), 'isolated trash became full', 6)
                    click_cell('__trash', 'right')
                    wait(lambda s: s.get('menuOpen') and menu_item(s, 'Empty Trash') and not menu_item(s, 'Empty Trash')['disabled'],
                         'Empty Trash enabled')
                    click_menu('Empty Trash')
                    armed = wait(lambda s: s.get('menuOpen') and s.get('armed') == 'Empty Trash' and menu_item(s, 'Empty Trash')
                                 and menu_item(s, 'Empty Trash')['armed'], 'Empty Trash confirmation armed')
                    if not armed.get('trashFull'):
                        dump(armed)
                        raise RuntimeError('First confirmation click emptied the trash')
                    click_menu('Empty Trash')
                    wait(lambda s: not s.get('menuOpen') and not s.get('trashFull'), 'confirmed Empty Trash cleared the isolated folder', 6)
                    if any(trash_dir.iterdir()):
                        raise RuntimeError('Isolated trash files remained after Empty Trash')
                    click_cell(PROBE_KEY, 'right')
                    app_menu = wait(lambda s: s.get('menuOpen') and menu_item(s, 'Settings…') and (
                        menu_item(s, 'Remove from Dock') or menu_item(s, 'Keep in Dock')), 'app context menu')
                    if menu_item(app_menu, 'Empty Trash'):
                        dump(app_menu)
                        raise RuntimeError('App menu showed Trash actions')
                    click_menu('Settings…')
                    wait(lambda s: not s.get('menuOpen') and s.get('prefs'), 'Settings… opened Dock preferences')
                    ipc('dockprobe', 'prefs', 'false')
                    wait(lambda s: not s.get('prefs'), 'Dock preferences closed')
                    click_cell(PROBE_KEY, 'left')
                    bouncing = wait(lambda s: PROBE_KEY in (s.get('launching') or []) or (
                        s.get('cells', {}).get(PROBE_KEY) and (s['cells'][PROBE_KEY]['wantBounce'] or s['cells'][PROBE_KEY]['bounceLift'] > 2)),
                                    'launch bounce started', 6)
                    print('BOUNCE ' + theme_name + ' lift=' + str(bouncing['cells'][PROBE_KEY]['bounceLift']), flush=True)
                    wait(lambda s: (s.get('cells', {}).get(PROBE_KEY) or {}).get('running') or pid_path.exists(),
                         'probe application started', 12)
                    wait(lambda s: PROBE_KEY not in (s.get('launching') or []) and (s.get('cells', {}).get(PROBE_KEY) or {}).get('bounceLift', 0) < 2,
                         'bounce settled after launch', 12)
                    close_probe_app()
                    wait(lambda s: not (s.get('cells', {}).get(PROBE_KEY) or {}).get('running'), 'probe application stopped', 8)
                    ipc('dockprobe', 'hideDelay', '200')
                    ipc('dockprobe', 'hideMode', 'always')
                    move_to(width * 0.5, 24)
                    wait(lambda s: s.get('tucked') and s.get('hideMode') == 'always' and not s.get('revealed')
                         and s.get('dock') and s['dock']['y'] >= s['screenH'] - 8, 'Dock tucked', 6)
                    move_to(width * 0.5, height - 2)
                    wait(lambda s: s.get('revealed') and not s.get('tucked'), 'pointer revealed the Dock', 4)
                    move_to(width * 0.5, 24)
                    wait(lambda s: s.get('tucked') and not s.get('revealed'), 'Dock hid after the pointer left', 4)
                    ipc('dockprobe', 'hideMode', 'never')
                    wait(lambda s: not s.get('tucked'), 'Dock restored')
                    print('FLOW ' + theme_name, flush=True)

                wait(lambda s: s.get('ready') and s.get('glass') in ('ready', 'failed') and s.get('cells', {}).get('__trash'),
                     'Dock probe ready', 40)
                click_flow('dark', True)
                click_flow('light', False)
                ipc('dockprobe', 'shutDown')
                client.wait(timeout=8)
                client = None
                log.flush()
                errors = log_path.read_text()
                if re.search(QML_ERRORS, errors):
                    raise RuntimeError('QML errors in ' + str(log_path) + '\n' + errors[-4000:])
                print('MACSHELL_DOCK_CLICKS_PASS: nested niri clicks, Dock menus, confirmation, bounce, hide, both themes', flush=True)
            finally:
                if pid_path.exists():
                    try:
                        os.kill(int(pid_path.read_text().strip()), 15)
                    except (OSError, ValueError):
                        pass
                stop(client)
                stop(nested)


if __name__ == '__main__':
    main()
