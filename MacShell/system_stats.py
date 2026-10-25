#!/usr/bin/env python3
"""Bounded, read-only /proc sampler. Rates are bytes/s; disk sectors are 512 B."""
import glob
from line_service import LineService
import os
from pathlib import Path
import re
import stat
import time


def cpu_counters(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        if fields and (fields[0] == 'cpu' or fields[0][3:].isdigit() and fields[0].startswith('cpu')):
            values = [int(v) for v in fields[1:9]]  # guest already included in user/nice
            result[fields[0]] = (sum(values), sum(values[3:5]))
    return result


def cpu_delta(before, after):
    if before is None or after[0] <= before[0] or after[1] < before[1]:
        return None
    total, idle = after[0] - before[0], after[1] - before[1]
    return round(max(0, min(100, 100 * (total - idle) / total)), 1)


def memory(text):
    data = {parts[0].rstrip(':'): int(parts[1]) * 1024 for line in text.splitlines()
            if len(parts := line.split()) >= 2 and parts[1].isdigit()}
    total = data.get('MemTotal', 0)
    available = data.get('MemAvailable', 0)
    return {'total': total, 'used': max(0, total - available),
            'swapTotal': data.get('SwapTotal', 0),
            'swapUsed': max(0, data.get('SwapTotal', 0) - data.get('SwapFree', 0))}


def networks(text):
    result = {}
    for line in text.splitlines()[2:]:
        if ':' not in line:
            continue
        name, counters = line.split(':', 1)
        fields = counters.split()
        if len(fields) >= 16:
            result[name.strip()] = (int(fields[0]), int(fields[8]))
    return result


def disks(text):
    result = {}
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 14:
            result[f[2]] = (int(f[5]) * 512, int(f[9]) * 512)
    return result


def rates(before, after, elapsed):
    if before is None or after is None or elapsed <= 0 or any(a < b for a, b in zip(after, before)):
        return None
    return [(a - b) / elapsed for a, b in zip(after, before)]


def default_interface(names, route4, route6):
    candidates = []
    for line in route4.splitlines()[1:]:
        f = line.split()
        if len(f) > 7 and f[1] == '00000000' and int(f[3], 16) & 1:
            candidates.append((int(f[6]), f[0]))
    for line in route6.splitlines():
        f = line.split()
        if len(f) >= 10 and f[0] == '0' * 32 and f[1] == '00' and int(f[8], 16) & 1:
            candidates.append((int(f[5], 16), f[-1]))
    # Prefer the transport interface to a tunnel; count one layer only.
    available = [n for n in names if n != 'lo' and Path('/sys/class/net', n, 'device').exists()]
    choices = sorted((metric, name) for metric, name in candidates if name in available)
    return choices[0][1] if choices else (next(iter(sorted(n for n in available if read('/sys/class/net/' + n + '/operstate').strip() == 'up')), ''))


def block_name(number, names):
    name = Path(os.path.realpath(f'/sys/dev/block/{os.major(number)}:{os.minor(number)}')).name
    return name if name in names else ''


def root_mount(text):
    roots = []
    for line in text.splitlines():
        before, separator, after = line.partition(' - ')
        fields, source = before.split(), after.split()
        if separator and len(fields) >= 6 and fields[4] == '/' and len(source) >= 2:
            path = re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), source[1])
            roots.append((source[0], path))
    # Do not guess between hidden/overmounted roots.
    return roots[0] if len(roots) == 1 else ('', '')


def single_btrfs_device(name, sysfs=Path('/sys/fs/btrfs')):
    for directory in sysfs.glob('*/devices'):
        try:
            devices = [entry.name for entry in directory.iterdir()]
        except OSError:
            continue
        if name in devices:
            # A single selected-device rate cannot represent a multi-device FS.
            return devices == [name]
    return False


def root_device(names):
    try:
        name = block_name(os.stat('/').st_dev, names)
        if name:
            return name
        # Btrfs subvolumes use an anonymous st_dev, not a diskstats device ID.
        filesystem, source = root_mount(read('/proc/self/mountinfo'))
        if not source.startswith('/dev/'):
            return ''
        device = os.stat(source)
        if not stat.S_ISBLK(device.st_mode):
            return ''
        name = block_name(device.st_rdev, names)
        if filesystem == 'btrfs' and name and not single_btrfs_device(name):
            return ''
        return name
    except OSError:
        return ''


def read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return ''


class Sampler:
    def __init__(self):
        self.previous = None
        self.capacity = None
        self.capacity_at = -60

    def sample(self, interface='', device='', now=None, boot=None):
        now = time.monotonic() if now is None else now
        boot = time.clock_gettime(time.CLOCK_BOOTTIME) if boot is None else boot
        cpus = cpu_counters(read('/proc/stat'))
        net = networks(read('/proc/net/dev'))
        disk = disks(read('/proc/diskstats'))
        iface = interface if interface in net else '' if interface else default_interface(net, read('/proc/net/route'), read('/proc/net/ipv6_route'))
        block = device if device in disk else '' if device else root_device(disk)
        old = self.previous
        gap = old is None or now - old['now'] > 15 or abs((boot - now) - old['sleep']) > .5 or set(cpus) != set(old['cpu'])
        elapsed = now - old['now'] if old else 0
        per_cpu = {key: cpu_delta(old['cpu'].get(key) if old and not gap else None, value) for key, value in cpus.items()}
        net_rate = rates(old['net'].get(iface) if old and not gap and old['iface'] == iface else None, net.get(iface), elapsed)
        disk_rate = rates(old['disk'].get(block) if old and not gap and old['block'] == block else None, disk.get(block), elapsed)
        if now - self.capacity_at >= 30:
            # Local root only; no directory traversal or remote filesystem calls.
            stat = os.statvfs('/')
            self.capacity = {'total': stat.f_blocks * stat.f_frsize, 'free': stat.f_bavail * stat.f_frsize}
            self.capacity_at = now
        temperatures = []
        for path in glob.glob('/sys/class/hwmon/hwmon*/temp*_input'):
            label = read(path.replace('_input', '_label')).strip()
            name = read(str(Path(path).parent / 'name')).strip()
            if name in ('coretemp', 'k10temp', 'zenpower', 'cpu_thermal'):
                try:
                    value = int(read(path)) / 1000
                    if 0 < value < 130:
                        temperatures.append(value)
                except ValueError:
                    pass
        self.previous = {'now': now, 'sleep': boot - now, 'cpu': cpus, 'net': net, 'disk': disk, 'iface': iface, 'block': block}
        return {'type': 'sample', 'time': boot, 'gap': gap, 'cpu': per_cpu.pop('cpu', None),
                'cores': per_cpu, 'memory': memory(read('/proc/meminfo')), 'interface': iface,
                'interfaces': sorted(n for n in net if n != 'lo'), 'network': net_rate,
                'device': block, 'devices': sorted(n for n in disk if not n.startswith(('loop', 'ram'))),
                'disk': disk_rate, 'diskLabel': 'Selected block layer (manual)' if device and block else 'Selected block device is unavailable' if device else 'Root filesystem block layer' if block else 'Select a block device (root mapping unavailable)',
                'capacity': self.capacity, 'temperature': max(temperatures) if temperatures else None}


class StatsService(LineService):
    def __init__(self):
        super().__init__()
        self.sampler = Sampler()
        self.interval, self.interface, self.device = 1, '', ''
        self.deadline = 0

    def wait_timeout(self):
        return max(0, self.deadline - time.monotonic())

    def command(self, request):
        data = request.get('data', {})
        interval = data.get('interval', self.interval)
        self.interval = interval if interval in (1, 2, 5) else 1
        self.interface = str(data.get('interface', self.interface))
        self.device = str(data.get('device', self.device))
        self.sampler.previous = None
        self.deadline = 0

    def tick(self):
        now = time.monotonic()
        if now >= self.deadline:
            self.emit(**self.sampler.sample(self.interface, self.device))
            self.deadline = now + self.interval


if __name__ == '__main__':
    StatsService().run()
