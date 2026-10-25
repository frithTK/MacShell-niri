#!/usr/bin/env python3
"""Measure the isolated stats helper + visible graph menu, without the desktop."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from install_niri import quickshell


HARNESS = '''import QtQuick
import QtQuick.Window
import Quickshell
ShellRoot {
    SystemStats { id: stats }
    Window {
        visible: true; width: 390; height: 650; color: "#202024"
        SystemStatsMenu { anchors.fill: parent; controller: stats }
    }
}
'''


def counters(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1].split()
    return int(fields[11]) + int(fields[12]), int(fields[21]) * os.sysconf('SC_PAGE_SIZE')


def measure(seconds):
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='macshell-perf-') as temporary:
        base = Path(temporary)
        for name in ('runtime', 'config', 'cache'):
            (base / name).mkdir(mode=0o700)
        source = base / 'source'
        shutil.copytree(repo / 'MacShell', source)
        (source / 'shell.qml').write_text(HARNESS)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                   QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
                   XDG_RUNTIME_DIR=str(base / 'runtime'), XDG_CONFIG_HOME=str(base / 'config'),
                   XDG_CACHE_HOME=str(base / 'cache'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(base / 'no-bus'))
        for name in ('DISPLAY', 'WAYLAND_DISPLAY'):
            env.pop(name, None)
        with (base / 'log').open('w') as log:
            process = subprocess.Popen([str(quickshell()), '-p', str(source)], env=env, stdout=log, stderr=log)
            try:
                time.sleep(2)  # Runtime startup is separate from the sampling window.
                if process.poll() is not None:
                    raise RuntimeError((base / 'log').read_text())
                children = Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
                pids = [process.pid] + [int(pid) for pid in children]
                if len(pids) != 2:
                    raise RuntimeError('Expected one qs process and one stats helper.')
                initial = {pid: counters(pid) for pid in pids}
                peak = {pid: initial[pid][1] for pid in pids}
                begin = time.monotonic()
                while time.monotonic() - begin < seconds:
                    time.sleep(min(1, max(.01, seconds - (time.monotonic() - begin))))
                    for pid in pids:
                        peak[pid] = max(peak[pid], counters(pid)[1])
                elapsed = time.monotonic() - begin
                processes = []
                for pid in pids:
                    ticks, _ = counters(pid)
                    processes.append({
                        'command': Path(f'/proc/{pid}/comm').read_text().strip(),
                        'cpuPercentOneCore': round((ticks - initial[pid][0]) / os.sysconf('SC_CLK_TCK') / elapsed * 100, 3),
                        'peakRssMiB': round(peak[pid] / 1048576, 2),
                    })
                return {'seconds': round(elapsed, 2), 'processes': processes,
                        'log': (base / 'log').read_text()[-2000:]}
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=60)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    print(json.dumps(measure(args.seconds), indent=2))
