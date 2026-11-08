#!/usr/bin/env python3
"""Compare bridges using a private fake niri and synthetic window data only."""
import argparse
import copy
import json
import math
import os
from pathlib import Path
import statistics
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from test_niri_rust_compat import FakeNiri, Runner, WINDOW


def cpu_ticks(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
    return int(fields[11]) + int(fields[12])


def pss_mib(pid):
    for line in Path(f'/proc/{pid}/smaps_rollup').read_text().splitlines():
        if line.startswith('Pss:'):
            return int(line.split()[1]) / 1024
    raise RuntimeError('PSS is unavailable')


def percentile(values, percentile_value):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * percentile_value) - 1)]


def run_one(command, scenario, seconds, frequency, windows):
    with tempfile.TemporaryDirectory(prefix='macshell-fake-niri-bench-') as directory:
        address = str(Path(directory) / 'fake.sock')
        initial_windows = [dict(copy.deepcopy(WINDOW), id=42 + i, title=f'Synthetic {i}', is_focused=i == 0)
                           for i in range(windows)]
        # The modified window must match the fixture except for title.
        initial_windows[0] = copy.deepcopy(WINDOW)
        server = FakeNiri(address, windows=initial_windows)
        start = time.monotonic()
        runner = Runner(command, address)
        try:
            stream = server.streams.get(timeout=4)
            runner.next(lambda m: len(m.get('state', {}).get('windows', [])) == windows)
            startup_ms = (time.monotonic() - start) * 1000
            time.sleep(.5)
            pid = runner.process.pid
            start_cpu = cpu_ticks(pid)
            start = time.monotonic()
            peak = pss_mib(pid)
            latencies = []
            count = 0
            deadline = start + seconds
            next_sample = start + 1
            while time.monotonic() < deadline:
                if scenario == 'idle':
                    time.sleep(min(.2, max(0, deadline - time.monotonic())))
                else:
                    due = start + count / frequency
                    if time.monotonic() < due:
                        time.sleep(due - time.monotonic())
                    if time.monotonic() >= deadline:
                        break
                    marker = f'synthetic-{count}'
                    window = copy.deepcopy(WINDOW)
                    window['title'] = marker
                    if scenario == 'geometry':
                        window['layout']['window_size'] = [400 + count % 2, 300]
                    payload = json.dumps({'WindowOpenedOrChanged': {'window': window}}).encode() + b'\n'
                    sent = time.monotonic()
                    stream.sendall(payload)
                    runner.next(lambda m: m.get('titles', {}).get('42') == marker or
                                any(w.get('title') == marker for w in m.get('state', {}).get('windows', [])), timeout=3)
                    latencies.append((time.monotonic() - sent) * 1000)
                    count += 1
                if time.monotonic() >= next_sample:
                    peak = max(peak, pss_mib(pid)); next_sample += 1
            elapsed = time.monotonic() - start
            ticks = cpu_ticks(pid) - start_cpu
            peak = max(peak, pss_mib(pid))
            result = {'scenario': scenario, 'seconds': round(elapsed, 3), 'events': count,
                      'startup_ms': round(startup_ms, 2), 'cpu_one_core_pct': round(ticks / os.sysconf('SC_CLK_TCK') / elapsed * 100, 3),
                      'peak_pss_mib': round(peak, 2)}
            if latencies:
                result.update(latency_median_ms=round(statistics.median(latencies), 2),
                              latency_p95_ms=round(percentile(latencies, .95), 2))
            return result
        finally:
            runner.close(); server.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust', required=True, help='Path to the release-built Rust bridge')
    parser.add_argument('--seconds', type=float, default=4)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--frequency', type=float, default=10)
    parser.add_argument('--windows', type=int, default=8, help='Number of synthetic windows')
    parser.add_argument('--output', help='Optional path for aggregate-only JSON results')
    args = parser.parse_args()
    if not 1 <= args.seconds <= 12 or not 2 <= args.rounds <= 10 or not 1 <= args.frequency <= 30 or not 1 <= args.windows <= 100:
        parser.error('Use 1–12 seconds, 2–10 rounds, 1–30 events/sec and 1–100 windows')
    commands = {'python': [sys.executable, '-u', str(ROOT / 'MacShell/niri_ipc.py')], 'rust': [args.rust]}
    records = []
    for round_index in range(args.rounds):
        order = ('python', 'rust') if round_index % 2 == 0 else ('rust', 'python')
        for scenario in ('idle', 'titles', 'geometry'):
            for name in order:
                record = run_one(commands[name], scenario, args.seconds, args.frequency, args.windows)
                record.update(implementation=name, round=round_index + 1)
                records.append(record)
                print(f"round={round_index+1} scenario={scenario} implementation={name} "
                      f"cpu={record['cpu_one_core_pct']}% pss={record['peak_pss_mib']}MiB", flush=True, file=sys.stderr)
    summary = {}
    for scenario in ('idle', 'titles', 'geometry'):
        summary[scenario] = {}
        for name in commands:
            group = [r for r in records if r['scenario'] == scenario and r['implementation'] == name]
            summary[scenario][name] = {key: round(statistics.median(row[key] for row in group), 3)
                                       for key in ('startup_ms', 'cpu_one_core_pct', 'peak_pss_mib', 'latency_median_ms', 'latency_p95_ms') if key in group[0]}
    report = {'kind': 'synthetic fake-niri bridge-only benchmark; not whole-shell or real-user workload',
              'frequency_hz': args.frequency, 'synthetic_windows': args.windows, 'rounds': args.rounds, 'records': records, 'summary_medians': summary}
    encoded = json.dumps(report, indent=2)
    if args.output: Path(args.output).write_text(encoded + '\n')
    print(encoded)


if __name__ == '__main__': main()
