import copy
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).parents[1] / 'MacShell/currency_fetch.py'
spec = importlib.util.spec_from_file_location('currency_fetch', SOURCE)
currency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(currency)
NOW = datetime(2026, 10, 26, 12, tzinfo=timezone.utc).timestamp()
METADATA = [dict(iso_code=code, name=name) for code, name in [('USD', 'US Dollar'), ('RUB', 'Russian Ruble'), ('EUR', 'Euro')]]
RATES = [dict(base='USD', quote=code, rate=rate, date='2026-10-26') for code, rate in [('USD', 1), ('RUB', 80), ('EUR', .8)]]


class CurrencyFetchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'cache/currency-rates.json'
        self.calls = []

    def fetch(self, endpoint):
        self.calls.append(endpoint)
        return copy.deepcopy(METADATA if endpoint == 'currencies' else RATES)

    def request(self, refresh=False, fetcher=None, now=NOW):
        messages = []
        currency.request_rates(self.path, refresh, messages.append, fetcher or self.fetch, now=now)
        return messages

    def snapshot(self, now=NOW):
        return currency.snapshot_from_api(METADATA, RATES, now * 1000)

    def test_first_request_validates_and_saves_private_cache(self):
        messages = self.request()
        self.assertEqual(self.calls, ['currencies', 'rates?base=USD'])
        self.assertEqual(len(messages), 1)
        self.assertTrue(messages[0]['success'])
        self.assertFalse(messages[0]['cached'])
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved['rates'], {'USD': 1, 'RUB': 80, 'EUR': .8})
        self.assertEqual(saved['names']['RUB'], 'Russian Ruble')
        self.assertEqual(saved['fetchedAt'], NOW * 1000)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)

    def test_fresh_cache_skips_network_without_rewriting(self):
        currency.save_cache(self.path, self.snapshot())
        original = self.path.stat().st_mtime_ns
        messages = self.request(now=NOW + 3599)
        self.assertEqual(self.calls, [])
        self.assertEqual([m['type'] for m in messages], ['cache', 'result'])
        self.assertTrue(messages[-1]['cached'])
        self.assertEqual(messages[-1]['snapshot']['fetchedAt'], NOW * 1000)
        self.assertEqual(self.path.stat().st_mtime_ns, original)

    def test_expiry_and_explicit_refresh_fetch_again(self):
        for force, age in [(False, 3600), (True, 5)]:
            with self.subTest(force=force):
                currency.save_cache(self.path, self.snapshot())
                self.calls.clear()
                messages = self.request(refresh=force, now=NOW + age)
                self.assertEqual([m['type'] for m in messages], ['cache', 'result'])
                self.assertEqual(len(self.calls), 2)
                self.assertFalse(messages[-1]['cached'])
                self.assertEqual(messages[-1]['snapshot']['fetchedAt'], (NOW + age) * 1000)

    def test_offline_keeps_exact_cached_data_and_timestamp(self):
        currency.save_cache(self.path, self.snapshot())
        before = self.path.read_bytes()
        def offline(endpoint):
            raise OSError('offline')
        messages = self.request(fetcher=offline, now=NOW + 7200)
        self.assertEqual(messages[0]['snapshot']['fetchedAt'], NOW * 1000)
        self.assertFalse(messages[-1]['success'])
        self.assertEqual(self.path.read_bytes(), before)

    def test_no_cache_offline_does_not_invent_rates(self):
        messages = self.request(fetcher=lambda _: (_ for _ in ()).throw(OSError()))
        self.assertEqual(len(messages), 1)
        self.assertFalse(messages[0]['success'])
        self.assertNotIn('snapshot', messages[0])
        self.assertFalse(self.path.exists())

    def test_malformed_rates_do_not_replace_good_cache(self):
        currency.save_cache(self.path, self.snapshot())
        before = self.path.read_bytes()
        for changes in [dict(rate=0), dict(rate=-1), dict(rate=True), dict(rate=float('nan')), dict(rate=float('inf')),
                        dict(base='EUR'), dict(quote='bad'), dict(date='2026-02-30'), dict(date='2026-11-01'), dict(date=None)]:
            with self.subTest(changes=changes):
                def bad(endpoint):
                    value = self.fetch(endpoint)
                    if endpoint.startswith('rates'): value[1].update(changes)
                    return value
                messages = self.request(refresh=True, fetcher=bad)
                self.assertFalse(messages[-1]['success'])
                self.assertEqual(self.path.read_bytes(), before)

    def test_missing_duplicate_and_unknown_rows_are_rejected(self):
        for rows in [RATES[:-1], RATES + [RATES[0]], [dict(row, quote='XXX') if row['quote'] == 'EUR' else row for row in RATES]]:
            with self.subTest(rows=rows):
                with self.assertRaises(ValueError): currency.snapshot_from_api(METADATA, rows, NOW * 1000)

    def test_bad_metadata_and_base_anchor_are_rejected(self):
        for field, value in [('name', '<img src=x>'), ('name', 'bad\nname'), ('name', 'x' * 101), ('iso_code', 'usd')]:
            metadata = copy.deepcopy(METADATA)
            metadata[0][field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises(ValueError): currency.snapshot_from_api(metadata, RATES, NOW * 1000)
        rows = copy.deepcopy(RATES)
        rows[0]['rate'] = 2
        with self.assertRaises(ValueError): currency.snapshot_from_api(METADATA, rows, NOW * 1000)

    def test_observation_dates_are_kept_per_currency(self):
        rows = copy.deepcopy(RATES)
        rows[2]['date'] = '2026-10-23'
        snapshot = currency.snapshot_from_api(METADATA, rows, NOW * 1000)
        self.assertEqual(snapshot['dates']['EUR'], '2026-10-23')
        self.assertEqual(snapshot['dates']['RUB'], '2026-10-26')

    def test_older_provider_response_cannot_roll_back_rates(self):
        currency.save_cache(self.path, self.snapshot())
        before = self.path.read_bytes()
        def older(endpoint):
            value = self.fetch(endpoint)
            if endpoint.startswith('rates'): value[1]['date'] = '2026-10-23'
            return value
        messages = self.request(refresh=True, fetcher=older)
        self.assertFalse(messages[-1]['success'])
        self.assertEqual(self.path.read_bytes(), before)

    def test_corrupt_future_or_oversized_cache_is_replaced_only_after_valid_fetch(self):
        for data in [b'{broken', b' ' * (currency.LIMIT + 1), json.dumps(dict(self.snapshot(), version=99)).encode(),
                     json.dumps(dict(self.snapshot(), version=True)).encode(), json.dumps(dict(self.snapshot(), fetchedAt=(NOW + 120) * 1000)).encode()]:
            with self.subTest(size=len(data)):
                self.path.parent.mkdir(parents=True, exist_ok=True)
                self.path.write_bytes(data)
                self.assertIsNone(currency.load_cache(self.path, NOW * 1000))
                messages = self.request()
                self.assertTrue(messages[-1]['success'])
                self.assertIsNotNone(currency.load_cache(self.path, NOW * 1000))

    def test_cache_write_failure_still_returns_online_rates(self):
        with patch.object(currency, 'save_cache', side_effect=OSError('disk unavailable')):
            message = self.request()[-1]
        self.assertTrue(message['success'])
        self.assertEqual(message['snapshot']['rates']['RUB'], 80)
        self.assertIn('could not be saved', message['warning'])

    def test_atomic_replace_failure_preserves_previous_file_and_cleans_stage(self):
        currency.save_cache(self.path, self.snapshot())
        before = self.path.read_bytes()
        with patch.object(currency.os, 'replace', side_effect=OSError('interrupted')):
            with self.assertRaises(OSError): currency.save_cache(self.path, self.snapshot(NOW + 5))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.glob('.currency-*')), [])

    def test_network_request_is_bounded_and_fetches_no_amount(self):
        response = io.BytesIO(json.dumps(RATES).encode())
        with patch.object(currency.urllib.request, 'urlopen', return_value=response) as opened:
            self.assertEqual(currency.fetch_json('rates?base=USD'), RATES)
        args, kwargs = opened.call_args
        self.assertEqual(args[0].full_url, 'https://api.frankfurter.dev/v2/rates?base=USD')
        self.assertEqual(kwargs['timeout'], 8)
        with patch.object(currency.urllib.request, 'urlopen', return_value=io.BytesIO(b'x' * (currency.LIMIT + 1))):
            with self.assertRaises(ValueError): currency.fetch_json('rates?base=USD')


if __name__ == '__main__':
    unittest.main()
