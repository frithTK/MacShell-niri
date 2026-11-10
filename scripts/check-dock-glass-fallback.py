#!/usr/bin/env python3
"""Check dockglass failure falling back to the shared liquidglass QSB.

Runs GPU ShaderEffect tests and a nested-niri copy of MacDock with dockglass
removed. Does not change the installed profile or the live session.
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
SIZE = (1000, 640)


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
    probe = (project / 'tests/dock-glass-probe.qml').read_text()
    if marker not in text:
        raise RuntimeError('Dock glass probe insertion point changed')
    text = text.replace(marker, marker + '                Component.onCompleted: root.demoUi = ui\n' + probe, 1)
    capture = '            readonly property bool captureGlass: root.hub && root.hub.glassReady(modelData.name)\n'
    forced = '            readonly property bool captureGlass: true\n'
    if capture not in text:
        raise RuntimeError('Dock captureGlass insertion point changed')
    dock.write_text(text.replace(capture, forced, 1))
    qsb = shell / 'dockglass.frag.qsb'
    if not qsb.exists():
        raise RuntimeError('Temp Dock copy is missing dockglass.frag.qsb')
    qsb.unlink()
    showcase.replace(shell / 'shell.qml', 'ShellRoot {', 'ShellRoot {\n' + (project / 'tests/dock-glass-ipc.qml').read_text())


def patch_settings(root):
    dock = json.loads((root / 'settings/macdock/settings.json').read_text())
    dock.update(dockEnabled=True, dockStyle='liquid', hideMode='never', showTrash=False, showThumbs=False,
                windowCapture=False, magnificationEnabled=False)
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dock))
    bar = json.loads((root / 'settings/macbar/settings.json').read_text())
    bar.update(barWidgets=['clock'], ccControls=[], statsMetrics=[], showTray=False, showSearch=False, uiSounds=False)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(bar))
    widgets = json.loads((root / 'settings/macwidgets/settings.json').read_text())
    widgets['values']['widgets'] = []
    (root / 'settings/macwidgets/settings.json').write_text(json.dumps(widgets))


def fallback_ok(state, dark=None):
    if not state.get('ready'):
        return False
    if not state.get('dockGlassFailed'):
        return False
    if state.get('glassState') != 'ready' or not state.get('liquidActive'):
        return False
    if state.get('shaderStatus') != 0 and state.get('liveStatus') != 0:
        return False
    shader = str(state.get('fragmentShader') or '')
    fallback = str(state.get('glassShaderUrl') or '')
    if 'liquidglass' not in shader or 'liquidglass' not in fallback:
        return False
    if shader != fallback:
        return False
    if not state.get('layerActive'):
        return False
    if state.get('padPx') != 10:
        return False
    if not state.get('screens'):
        return False
    failed = {screen.get('dockGlassFailed') for screen in state['screens']}
    urls = {screen.get('glassShaderUrl') for screen in state['screens']}
    if failed != {True} or len(urls) != 1:
        return False
    if dark is not None and state.get('dark') is not dark:
        return False
    return True


def main():
    parent_display = os.environ.get('WAYLAND_DISPLAY')
    parent_socket = os.environ.get('NIRI_SOCKET')
    if not parent_display or not parent_socket:
        raise RuntimeError('A parent Wayland/niri session is required to start nested niri')
    host_w, host_h = host_size()
    width, height = min(SIZE[0], host_w - 40), min(SIZE[1], host_h - 40)
    if width < 800 or height < 500:
        raise RuntimeError('Host output is too small for the nested dockglass fallback check')
    token = uuid.uuid4().hex
    runner = qmltestrunner()
    with tempfile.TemporaryDirectory(prefix='macshell-dock-glass-') as temporary:
        root = Path(temporary)
        shell = showcase.prepare(root, 'en')
        patch_shell(shell)
        patch_settings(root)
        log_path = Path('/tmp/macshell-dock-glass-fallback.log')
        gpu_log = Path('/tmp/macshell-dock-glass-gpu.log')
        environment = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
            XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'), XDG_DATA_DIRS=str(root / 'data'),
            MACSHELL_SETTINGS_HOME=str(root / 'settings'), MACSHELL_NIRI_PROFILE=str(root / 'niri'),
            QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic', QT_QPA_PLATFORM='wayland',
            DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            PIPEWIRE_REMOTE='macshell-dock-glass-no-pipewire', PULSE_SERVER='unix:' + str(root / 'no-pulse'),
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
                    raise RuntimeError('Refusing: nested Wayland display is the parent session')
                if nested_env.get('NIRI_SOCKET') in (None, parent_socket):
                    raise RuntimeError('Refusing: nested niri socket is the parent session')
                owned_socket(nested_env['NIRI_SOCKET'], token)
                time.sleep(.4)

                def nested_outputs():
                    return json.loads(run(['niri', 'msg', '--json', 'outputs'], nested_env))

                deadline = time.monotonic() + 8
                last = {}
                output_name = None
                while time.monotonic() < deadline:
                    last = nested_outputs()
                    if len(last) == 1:
                        info = next(iter(last.values()))
                        logical = info['logical']
                        if (logical['width'], logical['height']) == (width, height):
                            output_name = next(iter(last))
                            break
                    time.sleep(.1)
                if not output_name:
                    raise RuntimeError('nested output size: ' + repr(last))

                gpu = subprocess.run(
                    [runner, '-input', str(project / 'tests/gpu/tst_DockGlassFallback.qml'), '-o', '-,txt'],
                    env=nested_env, capture_output=True, text=True, timeout=90)
                gpu_log.write_text(gpu.stdout + '\n' + gpu.stderr)
                print(gpu.stdout.strip() or gpu.stderr.strip(), flush=True)
                if gpu.returncode or not re.search(r'\d+ passed', gpu.stdout + gpu.stderr):
                    raise RuntimeError('GPU dockglass fallback tests failed; see ' + str(gpu_log))
                print('GPU_DOCKGLASS_FALLBACK_PASS', flush=True)

                qs = quickshell()
                client = subprocess.Popen([qs, '-p', str(shell)], env=nested_env, stdout=log, stderr=log)

                def ipc(method, *values):
                    if client.poll() is not None:
                        raise RuntimeError('Dock glass shell exited: ' + log_path.read_text()[-4000:])
                    return run([qs, '-p', str(shell), 'ipc', 'call', 'dockglass', method, *map(str, values)], nested_env)

                def probe():
                    return json.loads(ipc('state'))

                def dump(state):
                    try:
                        run(['grim', '-o', output_name, '/tmp/macshell-dock-glass-fail.png'], nested_env)
                    except Exception:
                        pass
                    log.flush()
                    print('PROBE ' + json.dumps(state, ensure_ascii=False)[:2200], flush=True)
                    print('LOGTAIL ' + log_path.read_text()[-1800:], flush=True)

                def wait(predicate, label, timeout=8):
                    deadline = time.monotonic() + timeout
                    last_state = {}
                    while time.monotonic() < deadline:
                        try:
                            last_state = probe()
                            if predicate(last_state):
                                return last_state
                        except (ValueError, RuntimeError):
                            if client.poll() is not None:
                                raise
                        time.sleep(.12)
                    dump(last_state)
                    raise RuntimeError(label + ': ' + json.dumps(last_state, ensure_ascii=False)[:1400])

                first = wait(lambda s: fallback_ok(s, True), 'missing dockglass fell back to shared QSB', 40)
                print('DOCK_GLASS_FALLBACK_STATE', json.dumps(first, ensure_ascii=False), flush=True)
                if first['screenCount'] < 1:
                    raise RuntimeError('No Quickshell screens reported')
                for theme_name, dark in (('dark', True), ('light', False)):
                    ipc('theme', 'true' if dark else 'false')
                    themed = wait(lambda s: fallback_ok(s, dark), theme_name + ' fallback still compiled', 8)
                    print('FLOW ' + theme_name + ' screens=' + str(themed['screenCount'])
                          + ' status=' + str(themed['shaderStatus']) + ' pad=' + str(themed['padPx']), flush=True)
                ipc('shutDown')
                client.wait(timeout=8)
                client = None
                log.flush()
                errors = log_path.read_text()
                if re.search(QML_ERRORS, errors):
                    raise RuntimeError('QML errors in ' + str(log_path) + '\n' + errors[-4000:])
                print('MACSHELL_DOCK_GLASS_FALLBACK_PASS: GPU two-screen fallback, nested missing dockglass, shared QSB, both themes',
                      flush=True)
            finally:
                stop(client)
                stop(nested)


if __name__ == '__main__':
    main()
