import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class ClockJournalRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='clock-journal-build-'); cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.temp.name, '--example', 'journal'], check=True, timeout=120)
        cls.binary = Path(cls.temp.name) / 'debug/examples/journal'

    def call(self, envelope, journal, now=1200):
        request = dict(envelope=envelope, journal=journal, bootId='boot-a', now=now)
        result = subprocess.run([str(self.binary)], input=json.dumps(request, ensure_ascii=False)+'\n', capture_output=True, text=True, check=True, timeout=5)
        return json.loads(result.stdout)

    def test_digest_matches_python_and_replay_preserves_result(self):
        envelope = dict(id=str(uuid.uuid4()), bootId='boot-a', issuedBootMs=1100, revision=1, action='start', args=dict(sessionId='timer', durationMs=5000, label='Чай'))
        actual = self.call(envelope, [])['result']
        expected = hashlib.sha256(json.dumps(envelope, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()).hexdigest()
        self.assertEqual(actual['digest'], expected)
        record = dict(actual['record'], result={'revision': 2, 'timer': {'state': 'running'}})
        replay = self.call(envelope, [record], now=1300)
        self.assertEqual(replay['result']['replay'], record['result'])
        changed = copy.deepcopy(envelope); changed['args']['durationMs'] = 9000
        self.assertFalse(self.call(changed, [record])['success'])

    def test_expiry_duplicate_and_invalid_envelopes(self):
        envelope = dict(id=str(uuid.uuid4()), bootId='boot-a', issuedBootMs=1100, revision=1, action='pause', args=dict(sessionId='timer'))
        record = self.call(envelope, [])['result']['record']
        self.assertFalse(self.call(envelope, [record, record])['success'])
        self.assertFalse(self.call(envelope, [], now=601101)['success'])
        invalid = dict(envelope, args=dict(sessionId='timer', extra=True))
        self.assertFalse(self.call(invalid, [])['success'])
        future = dict(record, issuedBootMs=1300)
        self.assertFalse(self.call(envelope, [future])['success'])


if __name__ == '__main__': unittest.main()
