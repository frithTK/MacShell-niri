"""Compare the Rust Wi-Fi decision core to the existing Python backend."""
import json
import os
import random
import pwd
import subprocess
import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import network_control as network

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_CORE_HARNESS')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_CORE_HARNESS')
class NetworkCoreRustTests(unittest.TestCase):
    def test_synthetic_decisions_match_python(self):
        rng = random.Random(92114)
        cases = []
        expected = []
        for _ in range(250):
            flags, wpa, rsn = (rng.randrange(0x4000) for _ in range(3))
            cases.append(dict(action='security', flags=flags, wpa=wpa, rsn=rsn))
            expected.append(network.security({'Flags': flags, 'WpaFlags': wpa, 'RsnFlags': rsn}))

        for kind in ('open', 'wpa-psk', 'sae', 'enterprise', 'owe', 'unsupported'):
            for password in ('', 'short', 'пароль12', 'x' * 63, 'f' * 64, 'z' * 64, 'x' * 65):
                cases.append(dict(action='password', kind=kind, password=password))
                try:
                    network.make_profile({'ssid': 'test', 'rawSsid': [255, 0], 'security': kind,
                                          'interface': 'fake0'}, password)
                    expected.append(None)
                except ValueError as error:
                    expected.append(str(error))

        for _ in range(150):
            rows, originals = [], {}
            for index in range(rng.randrange(7)):
                ssid = rng.choice(([110, 101, 116], [110, 101, 116, 255], [0, 255]))
                interface = rng.choice((None, 'fake0', 'fake1'))
                key = rng.choice(('open', 'wpa-psk', 'sae'))
                path, uuid, timestamp = f'/profile{index}', f'{rng.randrange(3):02}', rng.randrange(4)
                rows.append(dict(path=path, ssid=ssid, interface=interface, key=key,
                                 timestamp=timestamp, uuid=uuid))
                connection = {'timestamp': timestamp, 'uuid': uuid}
                if interface is not None:
                    connection['interface-name'] = interface
                originals[path] = {'connection': connection, '802-11-wireless': {'ssid': ssid},
                                   '802-11-wireless-security': {'key-mgmt': key}}
            ssid = rng.choice(([110, 101, 116], [110, 101, 116, 255], [0, 255]))
            interface, key = rng.choice(('fake0', 'fake1')), rng.choice(('open', 'wpa-psk', 'sae'))
            active = rng.choice([''] + [row['path'] for row in rows])
            cases.append(dict(action='profile', profiles=rows, ssid=ssid, interface=interface, key=key, active=active))
            expected.append(network.choose_profile(originals, ssid, key, interface, active))

        result = subprocess.run([BINARY], input=''.join(json.dumps(case) + '\n' for case in cases),
                                capture_output=True, text=True, check=True, timeout=10)
        actual = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(actual, expected)

    def test_new_profile_metadata_matches_python_without_returning_password(self):
        rng = random.Random(8159)
        username = pwd.getpwuid(os.getuid()).pw_name
        uuid = 'd4ac1208-0a7b-4012-8abc-381d6ca41234'
        cases, expected = [], []
        for _ in range(80):
            raw = [rng.randrange(1, 256) for _ in range(rng.randrange(1, 33))]
            kind = rng.choice(('open', 'wpa-psk', 'sae'))
            password = '' if kind == 'open' else 'synthetic-passphrase'
            display = bytes(raw).decode('utf-8', 'replace')
            cases.append(dict(action='new-profile', ssid=raw, interface='fake0', username=username,
                              kind=kind, uuid=uuid, password=password))
            with patch.object(network.uuid, 'uuid4', return_value=uuid):
                profile = network.make_profile({'ssid': display, 'rawSsid': raw, 'security': kind,
                                                'interface': 'fake0'}, password)
            connection = profile['connection']
            expected.append(dict(ssid=profile['802-11-wireless']['ssid'].unpack(),
                                 display=connection['id'].unpack(), interface=connection['interface-name'].unpack(),
                                 permission=connection['permissions'].unpack()[0], uuid=connection['uuid'].unpack(),
                                 security={'open': 'Open', 'wpa-psk': 'WpaPsk', 'sae': 'Sae'}[kind]))
        result = subprocess.run([BINARY], input=''.join(json.dumps(case) + '\n' for case in cases),
                                capture_output=True, text=True, check=True, timeout=10)
        self.assertNotIn('synthetic-passphrase', result.stdout)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()], expected)


if __name__ == '__main__':
    unittest.main()
