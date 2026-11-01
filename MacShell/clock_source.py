"""Linux boot and wall clock readings used by Clock's runtime."""

from pathlib import Path
import os
import time
import uuid
from zoneinfo import ZoneInfo


def boot_id(path=Path('/proc/sys/kernel/random/boot_id')):
    value = path.read_text(encoding='ascii').strip()
    parsed = uuid.UUID(value)
    if str(parsed) != value:
        raise ValueError('Invalid boot ID')
    return value


def boot_time_ms():
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000


def wall_time_ms():
    return time.time_ns() // 1_000_000


def system_zone():
    configured = os.environ.get('TZ', '').lstrip(':')
    if configured:
        if configured.startswith('/'):
            configured = str(Path(configured).resolve().relative_to('/usr/share/zoneinfo'))
        return ZoneInfo(configured)
    localtime = Path('/etc/localtime').resolve()
    try:
        return ZoneInfo(str(localtime.relative_to('/usr/share/zoneinfo')))
    except ValueError:
        name = Path('/etc/timezone').read_text(encoding='utf-8').strip()
        if not name:
            raise ValueError('System time zone is unavailable')
        return ZoneInfo(name)
