#!/usr/bin/env python3
"""Read-only bounded CPU/RSS snapshot for one shell and its subprocesses."""
import argparse
import json
import os
from pathlib import Path
import time


def read_process(pid):
    try:
        data = (Path('/proc') / str(pid) / 'stat').read_text()
        tail = data[data.rfind(')') + 2:].split()
        return dict(ticks=int(tail[11]) + int(tail[12]), born=int(tail[19]), rss=int(tail[21]) * os.sysconf('SC_PAGE_SIZE'))
    except (OSError, ValueError, IndexError):
        return None


def tree(pid):
    result, waiting = {}, [pid]
    while waiting:
        current = waiting.pop()
        if current in result:
            continue
        value = read_process(current)
        if value is None:
            continue
        result[current] = value
        try:
            children = (Path('/proc') / str(current) / 'task' / str(current) / 'children').read_text().split()
            waiting.extend(int(child) for child in children)
        except OSError:
            pass
    return result


def measure(pid, seconds):
    previous = tree(pid)
    if pid not in previous:
        raise SystemExit('The selected process is unavailable.')
    started = time.monotonic()
    ticks, maximum_rss, maximum_processes, samples = 0, 0, 0, []
    while time.monotonic() - started < seconds:
        time.sleep(min(1, max(0, seconds - (time.monotonic() - started))))
        current = tree(pid)
        if pid not in current or current[pid]['born'] != previous[pid]['born']:
            raise SystemExit('The shell exited or restarted during measurement.')
        for process, state in current.items():
            old = previous.get(process)
            if old and old['born'] == state['born']:
                ticks += max(0, state['ticks'] - old['ticks'])
        rss = sum(value['rss'] for value in current.values())
        maximum_rss = max(maximum_rss, rss)
        maximum_processes = max(maximum_processes, len(current))
        samples.append(rss)
        previous = current
    elapsed = time.monotonic() - started
    return dict(seconds=round(elapsed, 2), cpuOneCorePercent=round(ticks / os.sysconf('SC_CLK_TCK') / elapsed * 100, 3),
                meanRssMiB=round(sum(samples) / len(samples) / 1048576, 2), maxRssMiB=round(maximum_rss / 1048576, 2),
                maxProcesses=maximum_processes, samples=len(samples))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--seconds', type=int, choices=range(1, 61), default=30, metavar='1..60')
    args = parser.parse_args()
    print(json.dumps(measure(args.pid, args.seconds), indent=2))
