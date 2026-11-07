"""Compare recording geometry with Python using synthetic displays."""
import os
import json
import random
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import recording_control as recording

BINARY = os.environ.get('MACSHELL_TEST_RECORDING_CORE_HARNESS')
AUDIO_BINARY = os.environ.get('MACSHELL_TEST_RECORDING_AUDIO_HARNESS')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_RECORDING_CORE_HARNESS')
class RecordingCoreRustTests(unittest.TestCase):
    def test_geometry_matches_existing_python(self):
        rng = random.Random(10495)
        lines, expected = [], []
        for _ in range(500):
            ox, oy = rng.randint(-2500, 1000), rng.randint(-1500, 1000)
            ow, oh = rng.randint(100, 3000), rng.randint(100, 2000)
            x, y = rng.randint(ox - 3, ox + ow + 3), rng.randint(oy - 3, oy + oh + 3)
            width, height = rng.randint(0, ow + 3), rng.randint(0, oh + 3)
            text = f'{x},{y} {width}x{height}'
            lines.append(f'{ox} {oy} {ow} {oh} {text}\n')
            try:
                result = recording.geometry(text, {'logical': {'x': ox, 'y': oy, 'width': ow, 'height': oh}})
                expected.append('OK ' + result)
            except ValueError:
                expected.append('ERROR')
        result = subprocess.run([BINARY], input=''.join(lines), capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(result.stdout.splitlines(), expected)


@unittest.skipUnless(AUDIO_BINARY, 'Set MACSHELL_TEST_RECORDING_AUDIO_HARNESS')
class RecordingAudioRustTests(unittest.TestCase):
    def test_links_match_python_for_synthetic_graphs(self):
        rng = random.Random(517)
        inputs, expected = [], []
        for _ in range(300):
            objects = [
                {'id': 1, 'type': 'PipeWire:Interface:Client', 'info': {'props': {'application.process.id': '42'}}},
                {'id': 2, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'wf-recorder', 'client.id': '1'}}},
                {'id': 3, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'mic'}}},
                {'id': 4, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'other'}}},
                {'id': 5, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'wf-recorder3', 'application.process.id': '43'}}},
                {'id': 6, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'capture'}}},
                {'id': 7, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'playback'}}},
            ]
            for index in range(rng.randrange(7)):
                objects.append({'id': 10 + index, 'type': 'PipeWire:Interface:Link', 'info': {
                    'output-node-id': rng.choice([3, 4, 7]), 'input-node-id': rng.choice([2, 5, 6, 3]),
                    'state': rng.choice(['active', 'paused'])}})
            pid = rng.choice([42, 43, 44])
            target = rng.choice(['mic', 'other', 'absent'])
            routes = rng.choice([[], [['other', 'capture', 'playback', 'mic']]])
            expected.append(recording.audio_link_state(objects, pid, target, routes))
            inputs.append(json.dumps({'objects': objects, 'pid': pid, 'target': target, 'routes': routes}))
        result = subprocess.run([AUDIO_BINARY], input='\n'.join(inputs) + '\n', capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(result.stdout.splitlines(), expected)

    def test_rejects_duplicate_ids_and_bad_links(self):
        inputs = [
            {'objects': [{'id': 1}, {'id': 1}], 'pid': 1, 'target': 'mic', 'routes': []},
            {'objects': [{'id': 1, 'type': 'x:Link', 'info': {}}], 'pid': 1, 'target': 'mic', 'routes': []},
        ]
        result = subprocess.run([AUDIO_BINARY], input='\n'.join(map(json.dumps, inputs)) + '\n', capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(result.stdout.splitlines(), ['error', 'error'])


if __name__ == '__main__':
    unittest.main()
