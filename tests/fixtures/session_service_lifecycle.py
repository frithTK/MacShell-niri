#!/usr/bin/env python3
"""Exercise restart and independent locker cgroups using harmless user services."""
import subprocess
import time
import uuid


def run(command, check=True):
    return subprocess.run(command, check=check, capture_output=True, text=True, timeout=15)


def value(unit, prop):
    return run(['systemctl', '--user', 'show', unit, '--property=' + prop, '--value']).stdout.strip()


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(.05)
    raise RuntimeError('Timed out waiting for test service state')


def main():
    suffix = uuid.uuid4().hex
    compositor = 'macshell-test-compositor-' + suffix
    shell = 'macshell-test-shell-' + suffix
    locker = 'macshell-test-locker-' + suffix
    crashing = 'macshell-test-crashing-' + suffix
    units = [name + '.service' for name in (compositor, shell, locker, crashing)]
    try:
        run(['systemd-run', '--user', '--unit=' + compositor, '--property=RuntimeMaxSec=60s',
             '--property=ExecStopPost=-/usr/bin/systemctl --user stop ' + shell + '.service', '/usr/bin/sleep', '60'])
        for unit, restart in ((shell, True), (locker, False)):
            command = ['systemd-run', '--user', '--unit=' + unit, '--property=PartOf=' + compositor + '.service',
                       '--property=RuntimeMaxSec=60s']
            if restart: command += ['--property=Restart=on-failure', '--property=RestartSec=0.2s']
            run(command + ['/usr/bin/sleep', '60'])
        old_shell, old_locker = value(shell + '.service', 'MainPID'), value(locker + '.service', 'MainPID')
        if old_shell == '0' or old_locker == '0': raise RuntimeError('Services did not start')
        run(['systemctl', '--user', 'kill', '--kill-whom=main', '--signal=SIGKILL', shell + '.service'])
        wait_for(lambda: value(shell + '.service', 'ActiveState') == 'active' and
                 value(shell + '.service', 'MainPID') not in ('0', old_shell))
        if value(locker + '.service', 'MainPID') != old_locker:
            raise RuntimeError('Shell crash changed the locker process')
        run(['systemctl', '--user', 'stop', shell + '.service'])
        if value(locker + '.service', 'MainPID') != old_locker:
            raise RuntimeError('Stopping the shell changed the locker process')
        if value(shell + '.service', 'LoadState') == 'not-found':
            # A transient test unit can be collected after stop; the installed
            # MacShell unit is persistent and can be started normally.
            run(['systemd-run', '--user', '--unit=' + shell, '--property=PartOf=' + compositor + '.service',
                 '--property=RuntimeMaxSec=60s', '--property=Restart=on-failure',
                 '--property=RestartSec=0.2s', '/usr/bin/sleep', '60'])
        else:
            run(['systemctl', '--user', 'start', shell + '.service'])
        run(['systemctl', '--user', 'stop', compositor + '.service'])
        wait_for(lambda: value(shell + '.service', 'ActiveState') == 'inactive' and
                 value(locker + '.service', 'ActiveState') == 'inactive')
        run(['systemd-run', '--user', '--unit=' + crashing, '--property=StartLimitIntervalSec=10',
             '--property=StartLimitBurst=3', '--property=Restart=on-failure', '--property=RestartSec=0.1s',
             '/usr/bin/false'], check=False)
        wait_for(lambda: value(crashing + '.service', 'Result') == 'start-limit-hit')
        print('SESSION_LIFECYCLE_PASS: restart, lock independence, session cleanup and crash limit')
    finally:
        for unit in reversed(units):
            run(['systemctl', '--user', 'stop', unit], check=False)
            run(['systemctl', '--user', 'reset-failed', unit], check=False)


if __name__ == '__main__':
    main()
