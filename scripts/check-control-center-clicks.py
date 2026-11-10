#!/usr/bin/env python3
"""Click Control Center, Wi-Fi and Bluetooth in an isolated nested niri.

Uses fixture network/Bluetooth services and a virtual pointer bound to the nested
output only. Does not change the installed profile or the live MacShell session.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
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
LARGE = (1100, 700)
SMALL = (800, 430)


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


def patch_shell(shell):
    bar = shell / 'MacBar.qml'
    text = bar.read_text()
    marker = '                id: ui\n                Component.onCompleted: root.demoUi = ui\n'
    probe = (project / 'tests/control-center-click-probe.qml').read_text()
    if marker not in text:
        raise RuntimeError('Control Center probe insertion point changed')
    bar.write_text(text.replace(marker, marker + probe, 1))
    nmcli = 'command: ["sh", "-c", "nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null"]'
    stub = 'command: ["sh", "-c", "printf \'%s\\\\n\' \'Office VPN:vpn:--\' \'Lab VPN:vpn:--\' \'Home VPN:vpn:--\' \'Travel VPN:vpn:--\' \'Backup VPN:vpn:--\'"]'
    showcase.replace(bar, nmcli, stub)
    showcase.replace(shell / 'shell.qml', 'ShellRoot {', 'ShellRoot {\n' + (project / 'tests/control-center-click-ipc.qml').read_text())
    networks = [dict(id='demo', ssid='Studio Network', signal=92, inUse=True, secure=True, saved=True, known=True, security='WPA2')]
    networks += [dict(id='n' + str(i), ssid='Guest Network ' + str(i), signal=70 - i, inUse=False, secure=True,
                      saved=False, known=False, security='WPA2') for i in range(1, 14)]
    source = (shell / 'network_control.py').read_text()
    old = "networks=[dict(id='demo', ssid='Studio Network', signal=92, inUse=True, secure=True, saved=True, known=True, security='WPA2'), dict(id='guest', ssid='Guest Network', signal=67, inUse=False, secure=True, saved=False, known=False, security='WPA2')]"
    if old not in source:
        raise RuntimeError('Fixture network list no longer matches')
    (shell / 'network_control.py').write_text(source.replace(old, 'networks=' + repr(networks), 1))


def patch_settings(root):
    bar = json.loads((root / 'settings/macbar/settings.json').read_text())
    bar.update(barWidgets=['wifi', 'bluetooth', 'controlCenter', 'clock'], ccControls=['wifi', 'bluetooth'],
               statsMetrics=[], showTray=False, showSearch=False, ccMigGame=True, ccMigRec=True, uiSounds=False)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(bar))
    dock = json.loads((root / 'settings/macdock/settings.json').read_text())
    dock.update(dockEnabled=False, windowCapture=False, showThumbs=False, showTrash=False)
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dock))


def compile_pointer(root):
    binary = root / 'input-client'
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
    subprocess.run(['cc', '-std=gnu11', '-O2', str(project / 'tests/native/widget-input-client.c'), '-o', str(binary), *flags], check=True)
    listed = subprocess.run([str(binary), '--list'], capture_output=True, text=True, env=dict(os.environ))
    if listed.returncode:
        raise RuntimeError('The Control Center click check needs wlr-virtual-pointer v2.')
    return binary


def main():
    parent_display = os.environ.get('WAYLAND_DISPLAY')
    parent_socket = os.environ.get('NIRI_SOCKET')
    if not parent_display or not parent_socket:
        raise RuntimeError('A parent Wayland/niri session is required to start nested niri')
    host_w, host_h = host_size()
    large_w, large_h = min(LARGE[0], host_w - 40), min(LARGE[1], host_h - 40)
    small_w, small_h = min(SMALL[0], large_w), min(SMALL[1], large_h - 80)
    if large_w < 900 or large_h < 560 or small_h < 380:
        raise RuntimeError('Host output is too small for the nested Control Center click check')
    token = uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='macshell-cc-clicks-') as temporary:
        root = Path(temporary)
        binary = compile_pointer(root)
        shell = showcase.prepare(root, 'en')
        patch_shell(shell)
        patch_settings(root)
        log_path = Path('/tmp/macshell-cc-clicks.log')
        environment = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
            XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'), XDG_DATA_DIRS=str(root / 'data'),
            MACSHELL_SETTINGS_HOME=str(root / 'settings'), MACSHELL_NIRI_PROFILE=str(root / 'niri'),
            QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic', QT_QPA_PLATFORM='wayland',
            DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            PIPEWIRE_REMOTE='macshell-cc-clicks-no-pipewire', PULSE_SERVER='unix:' + str(root / 'no-pulse'),
            MACSHELL_SHOWCASE_DARK_WALL=str(showcase.ASSETS / 'wallpaper-dark.svg'),
            MACSHELL_SHOWCASE_LIGHT_WALL=str(showcase.ASSETS / 'wallpaper.svg'),
            MACSHELL_SHOWCASE_ART=(showcase.ASSETS / 'album.svg').as_uri(),
            MACSHELL_NESTED_TEST_TOKEN=token)
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
                def resize(width, height):
                    run(['niri', 'msg', 'action', 'set-window-width', '--id', ident, str(width)])
                    run(['niri', 'msg', 'action', 'set-window-height', '--id', ident, str(height)])
                    run(['niri', 'msg', 'action', 'move-floating-window', '--id', ident, '-x', '80', '-y', '60'])
                resize(large_w, large_h)
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

                def wait_output(width, height, label):
                    nonlocal transform
                    deadline = time.monotonic() + 8
                    last = {}
                    while time.monotonic() < deadline:
                        last = nested_outputs()
                        if len(last) != 1:
                            time.sleep(.1)
                            continue
                        info = next(iter(last.values()))
                        logical = info['logical']
                        if (logical['width'], logical['height']) == (width, height):
                            transform = logical.get('transform') or 'Normal'
                            return next(iter(last))
                        time.sleep(.1)
                    raise RuntimeError(label + ': ' + repr(last))

                def map_point(x, y, width, height):
                    x, y = int(round(x)), int(round(y))
                    if transform == 'Flipped180':
                        y = height - y
                    elif transform == '180':
                        x, y = width - x, height - y
                    elif transform == 'Flipped':
                        x = width - x
                    return max(0, min(width - 1, x)), max(0, min(height - 1, y))

                output_name = wait_output(large_w, large_h, 'nested output size')
                qs = quickshell()
                client = subprocess.Popen([qs, '-p', str(shell)], env=nested_env, stdout=log, stderr=log)

                def ipc(target, method, *values):
                    if client.poll() is not None:
                        raise RuntimeError('Control Center shell exited: ' + log_path.read_text()[-4000:])
                    return run([qs, '-p', str(shell), 'ipc', 'call', target, method, *map(str, values)], nested_env)

                def probe():
                    return json.loads(ipc('ccprobe', 'state'))

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
                    raise RuntimeError(label + ': ' + json.dumps(last, ensure_ascii=False)[:1200])

                def dump(state):
                    try:
                        run(['grim', '-o', output_name, '/tmp/macshell-cc-click-fail.png'], nested_env)
                    except Exception:
                        pass
                    try:
                        print('LAYERS ' + run(['niri', 'msg', 'layers'], nested_env)[:1500], flush=True)
                    except Exception as error:
                        print('LAYERS ' + repr(error), flush=True)
                    log.flush()
                    print('PROBE ' + json.dumps(state, ensure_ascii=False)[:2000], flush=True)

                def pointer(kind, x, y, extra=None):
                    current = probe()
                    width, height = int(current['screenW']), int(current['screenH'])
                    x, y = map_point(x, y, width, height)
                    if not (0 <= x < width and 0 <= y < height):
                        raise RuntimeError('Input request outside the nested output: %s,%s of %sx%s' % (x, y, width, height))
                    command = [str(binary), kind, output_name, str(x), str(y), str(width), str(height)]
                    command += extra if extra else ['left']
                    listed = subprocess.run([str(binary), '--list'], capture_output=True, text=True, env=nested_env, timeout=3)
                    if listed.returncode:
                        raise RuntimeError('Nested compositor has no virtual pointer v2: ' + listed.stderr)
                    subprocess.run(command + ['owned-probe'], check=True, env=nested_env, timeout=3, capture_output=True)
                    time.sleep(.05)

                def click(name, fx=0.5, fy=0.5, use_global=False):
                    current = wait(lambda s: s.get('targets', {}).get(name) and s['targets'][name]['width'] > 2, 'target ' + name)
                    target = current['targets'][name]
                    if target['shown'] < 0.4:
                        dump(current)
                        raise RuntimeError('Target is not shown: ' + name)
                    origin_x = target['gx'] if use_global else target['x']
                    origin_y = target['gy'] if use_global else target['y']
                    pointer('click', origin_x + target['width'] * fx, origin_y + target['height'] * fy)

                def click_until(name, predicate, label, fx=0.5, fy=0.5):
                    before = probe().get('pop')
                    click(name, fx, fy)
                    try:
                        return wait(predicate, label, 4)
                    except RuntimeError:
                        if probe().get('pop') != before:
                            return wait(predicate, label, 4)
                        click(name, fx, fy, use_global=True)
                        return wait(predicate, label, 4)

                def escape():
                    run(['wtype', '-k', 'Escape'], nested_env, timeout=3)

                def assert_embedded(state, page_name, parent_key):
                    page, panel = state[page_name], state['cc']
                    if not state['embedded'] or state[parent_key] != 'cc':
                        dump(state)
                        raise RuntimeError(page_name + ' was not embedded in Control Center')
                    if not (abs(page['x'] - panel['x']) < 4 and abs(page['y'] - panel['y']) < 4 and abs(page['width'] - panel['width']) < 4):
                        dump(state)
                        raise RuntimeError(page_name + ' coordinates do not match Control Center after reparent')
                    if page['z'] < 10:
                        dump(state)
                        raise RuntimeError(page_name + ' z-order is below the Control Center chrome')
                    if page['y'] + page['height'] > state['screenH'] + 2:
                        dump(state)
                        raise RuntimeError(page_name + ' extends past the nested output')
                    if not state['focus']:
                        dump(state)
                        raise RuntimeError(page_name + ' did not take keyboard focus')

                def assert_bar_popover(state, page_name, parent_key, anchor):
                    if state['embedded'] or state[parent_key] != 'ui' or state['anchorType'] != anchor:
                        dump(state)
                        raise RuntimeError(page_name + ' opened as an embedded Control Center page from the menu bar')
                    if state['cc'] and state['cc']['shown'] > 0.2:
                        dump(state)
                        raise RuntimeError('Control Center stayed visible over a menu-bar popover')
                    if state[page_name]['y'] < 20:
                        dump(state)
                        raise RuntimeError(page_name + ' popover overlaps the menu bar')

                def scroll_at(box, delta):
                    pointer('scroll', box['x'] + box['width'] * 0.5, box['y'] + max(16, box['height'] * 0.5), [str(delta)])

                def scroll_until(key, moved, label):
                    current = probe()
                    box = current.get(key)
                    if not box or box.get('width', 0) < 2 or box.get('height', 0) < 2:
                        dump(current)
                        raise RuntimeError('scroll target missing: ' + key)
                    before = box.get('contentY') or 0
                    for delta in (180, -180, 90, -90):
                        scroll_at(probe()[key], delta)
                        time.sleep(.2)
                        try:
                            return wait(lambda s, k=key, b=before, m=moved: s.get(k) and m(s[k], b), label, 1.5)
                        except RuntimeError:
                            continue
                    return wait(lambda s, k=key, b=before, m=moved: s.get(k) and m(s[k], b), label, 2)

                def click_flow(theme_name, dark):
                    ipc('ccprobe', 'theme', 'true' if dark else 'false')
                    wait(lambda s: s.get('dark') is dark and s.get('pop') == '', theme_name + ' theme', 6)
                    wait(lambda s: s.get('targets', {}).get('cc') and s['targets']['cc']['width'] > 2, 'Control Center button', 8)
                    click_until('cc', lambda s: s['pop'] == 'cc' and s['ccOpen'] > 0.95 and s['targets'].get('ccWifi') and s['targets']['ccWifi']['shown'] > 0.7, 'open Control Center')
                    opened = wait(lambda s: s['pop'] == 'cc' and s['focus'] and s['anchorType'] == 'controlCenter', 'Control Center focus')
                    if opened['targets']['ccWifi'] is None or opened['targets']['ccBt'] is None:
                        dump(opened)
                        raise RuntimeError('Control Center tiles were not hit-testable')
                    click_until('ccWifi', lambda s: s['pop'] == 'wifi' and s['embedded'], 'open Wi-Fi from Control Center')
                    wifi = wait(lambda s: s['pop'] == 'wifi' and s['wifi']['shown'] > 0.8 and s['targets']['wifiBack']['shown'] > 0.5, 'Wi-Fi page shown')
                    assert_embedded(wifi, 'wifi', 'wifiParent')
                    click_until('wifiBack', lambda s: s['pop'] == 'cc' and not s['embedded'], 'Wi-Fi back button')
                    wait(lambda s: s['anchorType'] == 'controlCenter' and s['pop'] == 'cc', 'returned to Control Center from Wi-Fi')
                    click_until('ccBt', lambda s: s['pop'] == 'bt' and s['embedded'], 'open Bluetooth from Control Center')
                    bluetooth = wait(lambda s: s['pop'] == 'bt' and s['bt']['shown'] > 0.8 and s['targets']['btBack']['shown'] > 0.5, 'Bluetooth page shown')
                    assert_embedded(bluetooth, 'bt', 'btParent')
                    escape()
                    wait(lambda s: s['pop'] == 'cc' and not s['embedded'] and s['anchorType'] == 'controlCenter', 'Escape returns to Control Center')
                    click_until('cc', lambda s: s['pop'] == '', 'close Control Center')
                    click_until('barWifi', lambda s: s['pop'] == 'wifi' and not s['embedded'] and s['cc']['shown'] < 0.2, 'open Wi-Fi from the menu bar')
                    bar_wifi = wait(lambda s: s['pop'] == 'wifi' and s['wifi']['shown'] > 0.8, 'menu-bar Wi-Fi shown')
                    assert_bar_popover(bar_wifi, 'wifi', 'wifiParent', 'wifi')
                    if bar_wifi['targets']['wifiBack']['shown'] > 0.2:
                        dump(bar_wifi)
                        raise RuntimeError('Wi-Fi back button appeared on a menu-bar popover')
                    escape()
                    wait(lambda s: s['pop'] == '', 'Escape closes menu-bar Wi-Fi')
                    click_until('barBt', lambda s: s['pop'] == 'bt' and not s['embedded'] and s['cc']['shown'] < 0.2, 'open Bluetooth from the menu bar')
                    bar_bt = wait(lambda s: s['pop'] == 'bt' and s['bt']['shown'] > 0.8, 'menu-bar Bluetooth shown')
                    assert_bar_popover(bar_bt, 'bt', 'btParent', 'bluetooth')
                    escape()
                    wait(lambda s: s['pop'] == '', 'Escape closes menu-bar Bluetooth')
                    print('FLOW ' + theme_name, flush=True)

                wait(lambda s: s.get('ready') and s.get('glass') in ('ready', 'failed') and s.get('targets', {}).get('cc'),
                     'Control Center probe ready', 40)
                click_flow('dark', True)
                click_until('cc', lambda s: s['pop'] == 'cc', 'reopen Control Center for scroll')
                click_until('ccWifi', lambda s: s['pop'] == 'wifi' and s['embedded'], 'Wi-Fi page for list scroll')
                listed = wait(lambda s: s.get('wifiList') and s['wifiList']['contentHeight'] > s['wifiList']['height'] + 20, 'Wi-Fi list is taller than the viewport')
                before = listed['wifiList']['contentY']
                after = scroll_until('wifiList', lambda box, start: abs(box['contentY'] - start) > 8, 'Wi-Fi list scrolled')
                print('SCROLL list %.1f -> %.1f' % (before, after['wifiList']['contentY']), flush=True)
                escape()
                wait(lambda s: s['pop'] == 'cc', 'return after list scroll')
                click_until('cc', lambda s: s['pop'] == '', 'close before resize')

                resize(small_w, small_h)
                output_name = wait_output(small_w, small_h, 'small nested output')
                wait(lambda s: s['screenW'] == small_w and s['screenH'] == small_h, 'shell output followed the small size', 8)
                click_until('cc', lambda s: s['pop'] == 'cc' and s['targets'].get('ccWifi') and s['targets']['ccWifi']['shown'] > 0.6, 'open Control Center on a small screen')
                click_until('ccWifi', lambda s: s['pop'] == 'wifi' and s['embedded'], 'Wi-Fi page on a small screen')
                small = wait(lambda s: s.get('wifiScroll') and s['wifiScroll']['contentHeight'] > s['wifiScroll']['height'] + 8, 'Wi-Fi page scrolls on a small screen')
                assert_embedded(small, 'wifi', 'wifiParent')
                try:
                    outer = scroll_until('wifiScroll', lambda box, start: abs(box['contentY'] - start) > 4, 'small-screen Wi-Fi page accepted scroll')
                except RuntimeError:
                    outer = scroll_until('wifiList', lambda box, start: abs(box['contentY'] - start) > 4, 'small-screen Wi-Fi list accepted scroll')
                print('SCROLL page %.1f list %.1f' % (outer['wifiScroll']['contentY'], outer.get('wifiList', {}).get('contentY') or 0), flush=True)
                escape()
                wait(lambda s: s['pop'] == 'cc', 'Escape on a small screen returns to Control Center')
                click_until('cc', lambda s: s['pop'] == '', 'close small-screen Control Center')
                resize(large_w, large_h)
                output_name = wait_output(large_w, large_h, 'restored nested output')
                wait(lambda s: s['screenW'] == large_w and s['screenH'] == large_h, 'shell output restored', 8)
                click_flow('light', False)
                ipc('ccprobe', 'shutDown')
                client.wait(timeout=8)
                client = None
                log.flush()
                errors = log_path.read_text()
                if re.search(QML_ERRORS, errors):
                    raise RuntimeError('QML errors in ' + str(log_path) + '\n' + errors[-4000:])
                print('MACSHELL_CC_CLICKS_PASS: nested niri clicks, Control Center pages, menu-bar popovers, Escape, scroll, both themes', flush=True)
            finally:
                stop(client)
                stop(nested)


if __name__ == '__main__':
    main()
