#!/usr/bin/env python3
"""Focus / idle inhibition deadlines. Duration uses BOOTTIME, calendar uses UTC."""
import datetime as dt
import math
from line_service import LineService
from niri_ipc import request as niri_request
import os
from pathlib import Path
import time


def identity():
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    session = os.environ.get('MACSHELL_SESSION_TOKEN', '')
    if not session:
        try:
            niri_request('Version')  # A stale socket file does not confirm a live login.
            stat = os.stat(os.environ.get('NIRI_SOCKET', ''))
            session = f'{boot}:{stat.st_dev}:{stat.st_ino}:{stat.st_ctime_ns}'
        except (OSError, RuntimeError, ValueError, KeyError):
            pass
    return boot, session


def until_evening(now):
    local = dt.datetime.fromtimestamp(now)
    target = local.replace(hour=20, minute=0, second=0, microsecond=0)
    if target <= local:
        target += dt.timedelta(days=1)
    return target.timestamp()


def create(mode, now, boottime, boot, session):
    value = {'mode': mode, 'boot': boot, 'session': session}
    if mode in ('15', '30', '60'):
        duration = int(mode) * 60
        value.update(utc=now + duration, deadline=boottime + duration)
    elif mode == 'evening':
        value['utc'] = until_evening(now)
    elif mode not in ('off', 'manual'):
        raise ValueError('Invalid duration')
    return value


def remaining(value, now, boottime, boot):
    if value.get('mode') == 'off':
        return 0
    if value.get('mode') == 'manual':
        return None
    if value.get('mode') != 'evening' and value.get('boot') == boot:
        return max(0, value.get('deadline', 0) - boottime)
    return max(0, value.get('utc', 0) - now)


def restore(value, kind, now, boottime, boot, session):
    if not isinstance(value, dict) or value.get('mode') not in ('off', 'manual', '15', '30', '60', 'evening'):
        return create('off', now, boottime, boot, session)
    if value.get('mode') not in ('off', 'manual'):
        fields = ['utc'] + (['deadline'] if value.get('mode') != 'evening' and value.get('boot') == boot else [])
        if any(not isinstance(value.get(key), (int, float)) or not math.isfinite(value[key]) for key in fields):
            return create('off', now, boottime, boot, session)
    if kind == 'awake' and (not session or value.get('session') != session or value.get('boot') != boot):
        return create('off', now, boottime, boot, session)
    left = remaining(value, now, boottime, boot)
    if left == 0:
        return create('off', now, boottime, boot, session)
    value = dict(value)
    if left is not None and value.get('mode') != 'evening' and value.get('boot') != boot:
        value['deadline'] = boottime + left
    value.update(boot=boot, session=session)
    return value


class TimedService(LineService):
    def __init__(self):
        super().__init__()
        self.boot, self.session = identity()
        self.values = {}
        self.next_tick = time.monotonic() + 1

    def finite(self):
        return any(v.get('mode') not in ('manual', 'off') for v in self.values.values())

    def wait_timeout(self):
        return max(0, self.next_tick - time.monotonic()) if self.finite() else None

    def publish(self, changed=False):
        now, uptime = time.time(), time.clock_gettime(time.CLOCK_BOOTTIME)
        left = {k: remaining(v, now, uptime, self.boot) for k, v in self.values.items()}
        for k, seconds in left.items():
            if seconds == 0 and self.values[k]['mode'] != 'off':
                self.values[k] = create('off', now, uptime, self.boot, self.session)
                changed = True
        self.emit(type='state', values=self.values, remaining=left, changed=changed, sessionKnown=bool(self.session))
        self.next_tick = time.monotonic() + 1

    def command(self, request):
        data = request.get('data', {})
        now, uptime = time.time(), time.clock_gettime(time.CLOCK_BOOTTIME)
        if request['action'] == 'restore':
            self.values = {k: restore(data.get(k, {'mode': 'off'}), k, now, uptime, self.boot, self.session) for k in ('focus', 'awake')}
        elif request['action'] == 'set' and data['kind'] in ('focus', 'awake'):
            self.values[data['kind']] = create(data['mode'], now, uptime, self.boot, self.session)
        else:
            raise ValueError('Invalid timer request')
        self.publish(True)

    def tick(self):
        if self.finite() and time.monotonic() >= self.next_tick:
            self.publish()


if __name__ == '__main__':
    TimedService().run()
