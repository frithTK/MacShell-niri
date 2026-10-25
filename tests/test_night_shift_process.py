import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from test_dbus_protocol import Client


class NightShiftProcessTests(unittest.TestCase):
    def client(self, trace, delay=0):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        if trace:
            script = '#!' + sys.executable + '\nimport json, os, signal, sys, time\nsignal.signal(signal.SIGINT, lambda *_: sys.exit(0))\nwith open(os.environ["NIGHT_TEST_STARTS"], "a") as log: log.write(json.dumps(sys.argv) + "\\n")\ntime.sleep(' + repr(delay) + ')\nprint(' + repr(trace) + ', file=sys.stderr, flush=True)\nwhile True: time.sleep(.1)\n'
            (folder / 'wlsunset').write_text(script); (folder / 'wlsunset').chmod(0o755)
        client = Client('night_shift.py', environment={'PATH': str(folder), 'NIGHT_TEST_STARTS': str(folder / 'starts')})
        client.starts = folder / 'starts'
        self.addCleanup(client.close)
        client.wait(lambda m: m.get('type') == 'ready')
        return client

    def test_missing_binary_is_unavailable_not_on(self):
        client = self.client(None)
        client.send('configure', enabled=True, temperature=4000)
        state = client.wait(lambda m: m.get('state') == 'unavailable')
        self.assertFalse(state['available'])
        self.assertIn('Install wlsunset', state['error'])
        client.process.terminate()
        self.assertEqual(client.process.wait(timeout=2), 0)

    def test_observed_gamma_submission_and_process_cleanup(self):
        client = self.client('[123] -> zwlr_gamma_control_v1#9.set_gamma(fd 4)')
        client.send('configure', enabled=True, temperature=4100)
        state = client.wait(lambda m: m.get('state') == 'on')
        self.assertEqual(state['temperature'], 4100)
        self.assertEqual(state['appliedTemperature'], 4100)
        client.send('configure', enabled=False, temperature=4100)
        client.wait(lambda m: m.get('state') == 'off')

    def test_failed_gamma_control_never_becomes_on(self):
        client = self.client('[123] zwlr_gamma_control_v1#9.failed()')
        client.send('configure', enabled=True, temperature=4000)
        state = client.wait(lambda m: m.get('state') == 'error')
        self.assertIn('another color manager', state['error'])
        self.assertFalse(any(m.get('state') == 'on' for m in client.lines))

    def test_temperature_change_waits_for_new_gamma_request(self):
        client = self.client('[123] -> zwlr_gamma_control_v1#9.set_gamma(fd 4)', delay=.2)
        client.send('configure', enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'on')
        client.send('configure', enabled=True, temperature=3500)
        pending = client.wait(lambda m: m.get('temperature') == 3500)
        self.assertEqual(pending['state'], 'starting')
        applied = client.wait(lambda m: m.get('state') == 'on' and m.get('appliedTemperature') == 3500)
        self.assertEqual(applied['temperature'], 3500)
        starts = [json.loads(line) for line in client.starts.read_text().splitlines()]
        self.assertEqual(len(starts), 2)
        self.assertIn('3500', starts[-1])

    def test_unchanged_configuration_keeps_owned_process(self):
        client = self.client('[123] -> zwlr_gamma_control_v1#9.set_gamma(fd 4)')
        client.send('configure', enabled=True, temperature=4100)
        client.wait(lambda m: m.get('state') == 'on')
        client.send('configure', enabled=True, temperature=4100)
        same = client.wait(lambda m: m.get('state') == 'on')
        self.assertEqual(same['appliedTemperature'], 4100)
        client.send('configure', enabled=False, temperature=4100)
        stopped = client.wait(lambda m: m.get('state') == 'off')
        self.assertIsNone(stopped['appliedTemperature'])
        self.assertEqual(len(client.starts.read_text().splitlines()), 1)

    def test_off_cancels_unconfirmed_activation(self):
        client = self.client('[123] -> zwlr_gamma_control_v1#9.set_gamma(fd 4)', delay=1)
        client.send('configure', enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'starting')
        client.send('configure', enabled=False, temperature=4000)
        stopped = client.wait(lambda m: m.get('state') == 'off')
        self.assertIsNone(stopped['appliedTemperature'])
        self.assertFalse(any(m.get('state') == 'on' for m in client.lines))
