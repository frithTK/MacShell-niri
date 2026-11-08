from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]


class WidgetFetchRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mode = 'normal'
        cls.requests = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                parsed = urlsplit(self.path)
                cls.requests.append((parsed.path, parse_qs(parsed.query, keep_blank_values=True)))
                if cls.mode == 'slow': time.sleep(3)
                if parsed.path == '/get' or (cls.mode == 'offline'):
                    self.send_error(503)
                    return
                values = {'/geocode': {'results': [{'name': 'Demo', 'latitude': 51.5, 'longitude': -0.1}]},
                          '/location': {'success': False}, '/fallback': {'latitude': 50, 'longitude': 10, 'city': 'Demo'},
                          '/forecast': {'current': {'temperature_2m': 18}}, '/search': [{'plainLyrics': 'sample'}]}
                payload = b'x' * (1024 * 1024 + 1) if cls.mode == 'oversized' else json.dumps(values[parsed.path]).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers()
                try: self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError): pass
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.server.server_close)
        cls.addClassCleanup(cls.server.shutdown)
        cls.temp = tempfile.TemporaryDirectory(prefix='widget-fetch-test-')
        cls.addClassCleanup(cls.temp.cleanup)
        env = dict(os.environ, MACSHELL_WIDGET_TEST_API=f'http://127.0.0.1:{cls.server.server_port}/')
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/widget-fetch/Cargo.toml'), '--target-dir', cls.temp.name], env=env, check=True, timeout=180)
        cls.binary = Path(cls.temp.name) / 'debug/macshell-widget-fetch'

    def setUp(self):
        type(self).mode = 'normal'
        type(self).requests.clear()

    def run_fetch(self, *args):
        result = subprocess.run([str(self.binary), *args], capture_output=True, text=True, check=True, timeout=12)
        return json.loads(result.stdout)

    def test_city_query_and_forecast(self):
        result = self.run_fetch('weather', '7', 'city', ' A & B ', 'F')
        self.assertTrue(result['success'])
        self.assertEqual(result['epoch'], 7)
        self.assertEqual(result['result']['place'], 'Demo')
        self.assertEqual(self.requests[0][1]['name'], ['A & B'])
        self.assertEqual(self.requests[1][1]['temperature_unit'], ['fahrenheit'])

    def test_location_and_lyrics_fallback(self):
        result = self.run_fetch('weather', '8', 'auto', '', 'C')
        self.assertTrue(result['result']['located'])
        self.assertEqual([r[0] for r in self.requests], ['/location', '/fallback', '/forecast'])
        self.requests.clear()
        result = self.run_fetch('lyrics', '9', 'A & B', 'Demo', '', '120')
        self.assertEqual(result['result'][0]['plainLyrics'], 'sample')
        self.assertEqual(self.requests[-1][1]['q'], ['Demo A & B'])

    def test_oversized_response_is_rejected_without_private_data(self):
        type(self).mode = 'oversized'
        result = self.run_fetch('weather', '10', 'city', 'private city', 'C')
        self.assertFalse(result['success'])
        self.assertNotIn('private city', json.dumps(result))

    def test_cancellation_terminates_owned_process(self):
        type(self).mode = 'slow'
        process = subprocess.Popen([str(self.binary), 'weather', '11', 'city', 'test', 'C'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not self.requests and time.monotonic() < deadline: time.sleep(.02)
            self.assertTrue(self.requests)
            process.terminate()
            process.communicate(timeout=3)
            self.assertIsNotNone(process.returncode)
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()


if __name__ == '__main__':
    unittest.main()
