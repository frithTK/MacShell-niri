import sys
import unittest
from unittest.mock import patch

import numpy as np

from elan0c4f.study import Bridge, BridgeError, COUNT, FINGERS, evaluate, run, wait_for_press


class StudyTests(unittest.TestCase):
    def test_only_held_out_samples_are_compared(self):
        samples = {finger: [(finger, index) for index in range(COUNT)] for finger in FINGERS}
        seen = []

        def score(query, reference):
            seen.append((query, reference))
            return int(query[0] == reference[0])

        genuine, impostor = evaluate(samples, score)
        self.assertEqual(genuine, [1] * 6)
        self.assertEqual(impostor, [0] * 12)
        self.assertTrue(all(q[1] >= 3 and r[1] < 3 for q, r in seen))

    def test_incomplete_study_refuses_to_report(self):
        with self.assertRaises(ValueError):
            evaluate({finger: [None] * 4 for finger in FINGERS})

    def test_wait_uses_short_bounded_commands(self):
        class FakeBridge:
            calls = []

            def command(self, text):
                self.calls.append(text)
                return len(self.calls) == 3

        bridge = FakeBridge()
        self.assertTrue(wait_for_press(bridge))
        self.assertEqual(bridge.calls, ['W 2000', 'W 2000', 'W 2000'])

    def test_binary_bridge_and_timeout(self):
        helper = r'''
import sys
out = sys.stdout.buffer
out.write(b"READY 0165\n"); out.flush()
for line in sys.stdin.buffer:
    if line == b"R\n":
        out.write(b"FRAME 12800\n" + (1234).to_bytes(2, sys.byteorder) * 6400)
    elif line == b"W 300\n":
        out.write(b"ERR 1\n")
    elif line == b"Q\n":
        break
    else:
        out.write(b"ERR -4\n")
    out.flush()
'''
        bridge = Bridge([sys.executable, '-c', helper])
        try:
            self.assertEqual(bridge.line(), 'READY 0165')
            frame = bridge.command('R', frame=True)
            self.assertEqual(frame.shape, (80, 80))
            self.assertTrue(np.all(frame == 1234))
            frame.fill(0)
            self.assertFalse(bridge.command('W 300'))
            with self.assertRaises(BridgeError):
                bridge.command('INVALID')
        finally:
            bridge.close()

    def test_shutdown_failure_is_reported(self):
        helper = 'import sys; print("READY 0165", flush=True); sys.stdin.readline(); sys.exit(1)'
        bridge = Bridge([sys.executable, '-c', helper])
        self.assertEqual(bridge.line(), 'READY 0165')
        with self.assertRaisesRegex(BridgeError, 'clean shutdown'):
            bridge.close()

    def test_fresh_background_comes_from_preceding_idle_frame(self):
        class FakeBridge:
            read_count = 0
            closed = False

            def line(self):
                return 'READY 0165'

            def command(self, command, frame=False):
                if command == 'C':
                    return np.full((80, 80), 4000, dtype=np.uint16)
                if command == 'R':
                    self.read_count += 1
                    # Every fifth read is the idle frame after four touch frames.
                    value = 1000 + self.read_count // 5 if self.read_count % 5 == 0 else 5000
                    return np.full((80, 80), value, dtype=np.uint16)
                return command != 'W 300'

            def close(self):
                self.closed = True

        bridge = FakeBridge()
        seen = []

        def fake_extract(frames, background, profile):
            seen.append((profile, int(frames[0][0, 0]), int(background[0, 0])))
            return type('FakeFeatures', (), {'count': 1})()

        with patch('elan0c4f.study.Bridge', return_value=bridge), \
             patch('elan0c4f.study.extract', side_effect=fake_extract), \
             patch('elan0c4f.study.evaluate', return_value=([], [])), \
             patch('elan0c4f.study.resource.setrlimit'), \
             patch('builtins.input', return_value='continue'), patch('builtins.print'):
            run('/not-used')

        self.assertTrue(bridge.closed)
        self.assertEqual(len(seen), 15 * 4)
        for touch in range(15):
            group = seen[touch * 4:(touch + 1) * 4]
            self.assertEqual([entry[1] for entry in group], [5000] * 4)
            self.assertEqual([entry[2] for entry in group[:3]], [4000] * 3)
            self.assertEqual(group[3][2], 4000 if touch == 0 else 1000 + touch)


if __name__ == '__main__':
    unittest.main()
