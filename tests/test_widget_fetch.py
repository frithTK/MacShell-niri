import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))
import widget_fetch


class WidgetFetchTests(unittest.TestCase):
    def test_city_and_units_are_encoded_in_a_single_request_pipeline(self):
        forecast = {'current': {'temperature_2m': 18}}
        with patch.object(widget_fetch, 'fetch', side_effect=[{'results': [{'name': 'Demo', 'latitude': 51.5, 'longitude': -0.1}]}, forecast]) as fetch:
            result = widget_fetch.weather('city', ' A & B ', 'F')
        self.assertFalse(result['located']); self.assertEqual(result['place'], 'Demo')
        self.assertEqual(fetch.call_args_list[0].args[1]['name'], 'A & B')
        self.assertEqual(fetch.call_args_list[1].args[1]['temperature_unit'], 'fahrenheit')
        self.assertEqual(result['forecast'], forecast)

    def test_invalid_primary_location_falls_back_before_forecast(self):
        with patch.object(widget_fetch, 'fetch', side_effect=[{'success': False}, {'latitude': 50, 'longitude': 10, 'city': 'Demo'}, {}]) as fetch:
            result = widget_fetch.weather('auto', '', 'C')
        self.assertTrue(result['located']); self.assertEqual(fetch.call_count, 3)
        self.assertEqual(fetch.call_args_list[1].args[0], 'https://ipapi.co/json/')

    def test_invalid_coordinates_never_reach_forecast(self):
        for latitude in (float('nan'), float('inf'), 91):
            with patch.object(widget_fetch, 'fetch', return_value={'latitude': latitude, 'longitude': 0}) as fetch:
                with self.assertRaises(ValueError): widget_fetch.weather('auto', '', 'C')
                self.assertEqual(fetch.call_count, 2)

    def test_http_payload_is_bounded_and_query_values_are_not_shell_text(self):
        with patch.object(widget_fetch.urllib.request, 'urlopen', return_value=io.BytesIO(b'{"value": false}')) as open_url:
            self.assertEqual(widget_fetch.fetch('https://example.test/api', {'name': 'a & $(no command)'}), {'value': False})
        request = open_url.call_args.args[0]
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)['name'], ['a & $(no command)'])
        self.assertEqual(open_url.call_args.kwargs['timeout'], 8)
        with patch.object(widget_fetch.urllib.request, 'urlopen', return_value=io.BytesIO(b'x' * (widget_fetch.LIMIT + 1))):
            with self.assertRaises(ValueError): widget_fetch.fetch('https://example.test/api')

    def test_lyrics_get_failure_uses_search_without_changing_the_track(self):
        with patch.object(widget_fetch, 'fetch', side_effect=[urllib.error.URLError('offline'), [{'plainLyrics': 'sample'}]]) as fetch:
            result = widget_fetch.lyrics('Title', 'Artist', 'Album', '120')
        self.assertEqual(result, [{'plainLyrics': 'sample'}])
        self.assertEqual(fetch.call_args_list[1].args[1], {'q': 'Artist Title'})

    def test_response_keeps_generation_and_failure_does_not_leak_request_data(self):
        for success in (True, False):
            output = io.StringIO()
            with contextlib.redirect_stdout(output), patch.object(widget_fetch, 'lyrics', return_value={'plainLyrics': 'sample'}, side_effect=None if success else ValueError('private track data')):
                widget_fetch.main(['lyrics', '23', 'private title', 'private artist', '', '10'])
            response = json.loads(output.getvalue())
            self.assertEqual(response['epoch'], 23); self.assertEqual(response['success'], success)
            self.assertNotIn('private', output.getvalue())


if __name__ == '__main__':
    unittest.main()
