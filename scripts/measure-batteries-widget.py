#!/usr/bin/env python3
"""Measure four large Batteries cards with isolated shared device data."""
import argparse
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=int, choices=range(1, 61), default=10)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
measure = runpy.run_path(str(project / 'scripts/measure-shell.py'))['measure']
result = dict(backend='offscreen/software', inputIntervalSeconds=2, warmupSeconds=2,
              baseline='Static Normal Calendar in every phase; shared synthetic device inputs, four Large Batteries, six devices; laptop charge changes every two seconds.',
              budgets=dict(cpuOneCoreDelta=2.0, meanRssDeltaMiB=25.0), scenarios={})
with tempfile.TemporaryDirectory(prefix='macshell-batteries-measure-') as directory:
    root = Path(directory)
    shutil.copytree(project / 'MacShell', root / 'shell')
    shutil.copyfile(project / 'tests/batteries-widget-baseline.qml', root / 'shell/shell.qml')
    for key in ('runtime', 'cache', 'config'):
        (root / key).mkdir()
    (root / 'runtime').chmod(0o700)
    environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='',
        QT_QUICK_CONTROLS_STYLE='Basic', XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CACHE_HOME=str(root / 'cache'),
        XDG_CONFIG_HOME=str(root / 'config'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
        DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    for key in ('DISPLAY', 'WAYLAND_DISPLAY'):
        environment.pop(key, None)
    for scenario in ('none', 'widgets', 'hidden', 'removed'):
        environment['MACSHELL_BATTERIES_SCENARIO'] = scenario
        with (root / 'log').open('w') as log:
            process = subprocess.Popen([quickshell(), '-p', str(root / 'shell')], env=environment, stdout=log, stderr=log)
            try:
                time.sleep(2)
                result['scenarios'][scenario] = measure(process.pid, args.seconds)
            finally:
                process.terminate()
                process.wait(timeout=5)
        output = (root / 'log').read_text()
        if re.search(r'ERROR|TypeError|ReferenceError|Binding loop|Unable to assign', output):
            raise RuntimeError(output)
        print(scenario, json.dumps(result['scenarios'][scenario]), flush=True)
live, baseline = result['scenarios']['widgets'], result['scenarios']['none']
result['delta'] = dict(cpuOneCorePercent=round(live['cpuOneCorePercent'] - baseline['cpuOneCorePercent'], 3),
                       meanRssMiB=round(live['meanRssMiB'] - baseline['meanRssMiB'], 2))
result['withinBudgets'] = (result['delta']['cpuOneCorePercent'] <= result['budgets']['cpuOneCoreDelta']
                          and result['delta']['meanRssMiB'] <= result['budgets']['meanRssDeltaMiB']
                          and live['maxProcesses'] == 1)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(dict(delta=result['delta'], withinBudgets=result['withinBudgets'])))
