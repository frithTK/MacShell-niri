# SPDX-License-Identifier: LGPL-2.1-or-later
"""In-memory research only. Scores are not authentication decisions."""
import argparse
import resource
import subprocess
import sys
import time

import numpy as np

from .features import PROFILES, compare, compare_mutual, extract
from .diagnostics import background_delta

FINGERS = ('right-index', 'left-index', 'right-middle')
COUNT = 5
FRAME_BYTES = 80 * 80 * 2
STUDY_PROFILES = (*PROFILES, 'temporal_median_fresh_background')


class BridgeError(RuntimeError):
    pass


class Bridge:
    """Communicate with the privileged USB helper without logging biometric data."""

    def __init__(self, argv):
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def line(self):
        line = self.process.stdout.readline(128)
        if not line.endswith(b'\n'):
            raise BridgeError('USB bridge disconnected or sent an invalid response')
        try:
            return line.decode('ascii').strip()
        except UnicodeDecodeError as exc:
            raise BridgeError('Invalid response from USB bridge') from exc

    def command(self, text, frame=False):
        self.process.stdin.write((text + '\n').encode('ascii'))
        self.process.stdin.flush()
        response = self.line()
        if response.startswith('ERR '):
            try:
                code = int(response[4:])
            except ValueError as exc:
                raise BridgeError('Invalid USB bridge error') from exc
            if code == 1 and text.startswith('W '):
                return False
            raise BridgeError(f'USB operation failed (code {code})')
        if not frame:
            if response != 'OK':
                raise BridgeError('Unexpected USB bridge response')
            return True
        if response != f'FRAME {FRAME_BYTES}':
            raise BridgeError('Unexpected USB frame size')
        data = np.zeros((80, 80), dtype=np.uint16)
        view = memoryview(data).cast('B')
        try:
            offset = 0
            while offset < FRAME_BYTES:
                count = self.process.stdout.readinto(view[offset:])
                if not count:
                    raise BridgeError('Incomplete USB frame')
                offset += count
            return data
        except BaseException:
            data.fill(0)
            raise
        finally:
            view.release()

    def close(self):
        try:
            if self.process.poll() is None:
                try:
                    self.process.stdin.write(b'Q\n')
                    self.process.stdin.flush()
                except BrokenPipeError:
                    pass
                finally:
                    self.process.stdin.close()
                try:
                    # The helper may be privileged, so signals from this process
                    # are not available. Each wait command is short and followed
                    # by Q, allowing the helper to stop the reader itself.
                    self.process.wait(timeout=25)
                except subprocess.TimeoutExpired as exc:
                    raise BridgeError('USB helper did not confirm shutdown') from exc
            if self.process.returncode != 0:
                raise BridgeError('USB helper did not confirm a clean shutdown')
        finally:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            self.process.stdout.close()


def wait_for_press(bridge, timeout_seconds=90):
    deadline = time.monotonic() + timeout_seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        # Short waits make Q responsive without signalling a privileged process.
        interval_ms = max(100, min(2000, int(remaining * 1000)))
        if bridge.command(f'W {interval_ms}'):
            return True


def evaluate(samples, score=compare):
    """Hold out captures 4 and 5; compare against the first three of each finger."""
    if set(samples) != set(FINGERS) or any(len(samples[f]) != COUNT for f in FINGERS):
        raise ValueError('Incomplete study: refusing to report scores')
    genuine, impostor = [], []
    for finger in FINGERS:
        for query in samples[finger][3:]:
            for candidate in FINGERS:
                scores = [score(query, reference) for reference in samples[candidate][:3]]
                (genuine if finger == candidate else impostor).append(max(scores))
    return genuine, impostor


def run(bridge_path):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    bridge = Bridge(['pkexec', bridge_path])
    background = None
    fresh_background = None
    samples = {profile: {finger: [] for finger in FINGERS} for profile in STUDY_PROFILES}
    try:
        ready = bridge.line()
        if not ready.startswith('READY '):
            raise BridgeError(f'USB bridge failed to open the sensor: {ready}')
        print('SENSOR_READY; leave sensor clear for calibration', flush=True)
        background = bridge.command('C', frame=True)
        fresh_background = background.copy()
        for finger_index, finger in enumerate(FINGERS):
            if finger_index:
                print(f'SWITCH_TO {finger}; waiting for confirmation', flush=True)
                if input().strip() != 'continue':
                    raise BridgeError('Finger transition cancelled')
            for index in range(COUNT):
                print(f'PRESS_READY {finger} {index + 1}/{COUNT}', flush=True)
                if not wait_for_press(bridge):
                    raise BridgeError('Timed out waiting for a finger')
                frames = []
                try:
                    frames.append(bridge.command('R', frame=True))
                    for _ in range(3):
                        if not bridge.command('W 200'):
                            break
                        frames.append(bridge.command('R', frame=True))
                    for profile in PROFILES:
                        samples[profile][finger].append(extract(frames, background, profile))
                    samples['temporal_median_fresh_background'][finger].append(
                        extract(frames, fresh_background, 'temporal_median'))
                    counts = ','.join(str(samples[p][finger][-1].count) for p in STUDY_PROFILES)
                    print(f'PRESS_RECORDED {finger} {index + 1}/{COUNT} frames={len(frames)} features={counts}', flush=True)
                finally:
                    for frame in frames:
                        frame.fill(0)
                # Require a quiet interval before accepting the next touch.
                for _ in range(30):
                    if not bridge.command('W 300'):
                        break
                    time.sleep(.1)
                else:
                    raise BridgeError('Finger release was not detected')
                idle = bridge.command('R', frame=True)
                try:
                    median, p90 = background_delta(idle, background)
                    print(f'BACKGROUND_DELTA median={median:.1f} p90={p90:.1f}', flush=True)
                    # Only an idle frame from before the *next* touch may be used.
                    fresh_background[:] = idle
                finally:
                    idle.fill(0)
        for profile in STUDY_PROFILES:
            for name, scorer in (('ratio', compare), ('mutual_ratio', compare_mutual)):
                genuine, impostor = evaluate(samples[profile], scorer)
                print(f'RESULT {profile} {name} genuine={genuine} different_finger={impostor}', flush=True)
    finally:
        if background is not None:
            background.fill(0)
        if fresh_background is not None:
            fresh_background.fill(0)
        bridge.close()


def check_idle(bridge_path):
    """Check repeated waits and clean shutdown without capturing a fingerprint."""
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    bridge = Bridge(['pkexec', bridge_path])
    background = None
    empty_features = []
    try:
        ready = bridge.line()
        if not ready.startswith('READY '):
            raise BridgeError(f'USB bridge failed to open the sensor: {ready}')
        print('IDLE_CHECK: keep sensor clear', flush=True)
        background = bridge.command('C', frame=True)
        for index in range(3):
            if bridge.command('W 2000'):
                raise BridgeError('Finger detected; idle check aborted')
            idle = bridge.command('R', frame=True)
            try:
                median, p90 = background_delta(idle, background)
                empty_features.append(extract([idle], background, 'temporal_median'))
                print(f'IDLE_TIMEOUT_OK {index + 1}/3 background_delta_median={median:.1f} p90={p90:.1f}', flush=True)
            finally:
                idle.fill(0)
        for name, scorer in (('ratio', compare), ('mutual_ratio', compare_mutual)):
            scores = [scorer(empty_features[i], empty_features[j])
                      for i in range(len(empty_features)) for j in range(i + 1, len(empty_features))]
            print(f'IDLE_COMPARISONS {name} scores={scores}', flush=True)
    finally:
        if background is not None:
            background.fill(0)
        bridge.close()
    print('IDLE_SHUTDOWN_OK', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', required=True, help='Absolute path to the compiled elan-study-bridge')
    parser.add_argument('--check-idle', action='store_true', help='Test idle waits without capturing a fingerprint')
    args = parser.parse_args()
    try:
        (check_idle if args.check_idle else run)(args.bridge)
    except (BridgeError, OSError, EOFError, KeyboardInterrupt) as exc:
        print(f'STUDY_STOPPED {type(exc).__name__}: {exc}', flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
