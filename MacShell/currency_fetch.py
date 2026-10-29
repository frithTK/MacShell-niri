#!/usr/bin/env python3
"""One cancellable request for daily reference rates; no amounts leave the app."""
import argparse
from datetime import date, datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time
import urllib.request

API = 'https://api.frankfurter.dev/v2/'
LIMIT = 256 * 1024
TTL_MS = 60 * 60 * 1000
CODE = re.compile(r'^[A-Z]{3}$')


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 < value < 1e15


def valid_date(value, now_ms):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValueError('Invalid rate date')
    parsed = date.fromisoformat(value)
    if not date(1990, 1, 1) <= parsed <= datetime.fromtimestamp(now_ms / 1000, timezone.utc).date() + timedelta(days=1):
        raise ValueError('Invalid rate date')
    return value


def validate_snapshot(value, now_ms):
    if not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1 or value.get('provider') != 'frankfurter-v2':
        raise ValueError('Unsupported currency cache')
    fetched = value.get('fetchedAt')
    if not number(fetched) or fetched > now_ms + 60000:
        raise ValueError('Invalid cache timestamp')
    rates, dates, names = value.get('rates'), value.get('dates'), value.get('names')
    if not isinstance(rates, dict) or not 2 <= len(rates) <= 300 or not isinstance(dates, dict) or not isinstance(names, dict):
        raise ValueError('Invalid rate data')
    for code, rate in rates.items():
        if not isinstance(code, str) or not CODE.fullmatch(code) or not number(rate):
            raise ValueError('Invalid exchange rate')
        valid_date(dates.get(code), now_ms)
        name = names.get(code)
        if not isinstance(name, str) or not re.fullmatch(r'[^\x00-\x1f<>&]{1,100}', name):
            raise ValueError('Invalid currency name')
    if rates.get('USD') != 1:
        raise ValueError('Invalid base currency')
    return dict(version=1, provider='frankfurter-v2', fetchedAt=fetched,
                rates=dict(rates), dates={code: dates[code] for code in rates}, names={code: names[code] for code in rates})


def snapshot_from_api(currencies, rows, now_ms):
    if not isinstance(currencies, list) or not 2 <= len(currencies) <= 300 or not isinstance(rows, list) or not 2 <= len(rows) <= 300:
        raise ValueError('Invalid currency response')
    names = {}
    for item in currencies:
        if not isinstance(item, dict): raise ValueError('Invalid currency metadata')
        code, name = item.get('iso_code'), item.get('name')
        if not isinstance(code, str) or not CODE.fullmatch(code) or code in names:
            raise ValueError('Invalid currency code')
        names[code] = name
    rates, dates = {}, {}
    for item in rows:
        if not isinstance(item, dict) or item.get('base') != 'USD': raise ValueError('Invalid currency base')
        code = item.get('quote')
        if not isinstance(code, str) or code not in names or code in rates:
            raise ValueError('Invalid currency quote')
        rates[code], dates[code] = item.get('rate'), item.get('date')
    if set(rates) != set(names):
        raise ValueError('Incomplete exchange rates')
    return validate_snapshot(dict(version=1, provider='frankfurter-v2', fetchedAt=now_ms, rates=rates, dates=dates, names=names), now_ms)


def fetch_json(endpoint):
    request = urllib.request.Request(API + endpoint, headers={'Accept': 'application/json', 'User-Agent': 'MacShell-Calculator/1.0'})
    with urllib.request.urlopen(request, timeout=8) as response:
        data = response.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError('Currency response is too large')
    return json.loads(data)


def load_cache(path, now_ms):
    try:
        with path.open('rb') as stream:
            raw = stream.read(LIMIT + 1)
        if len(raw) > LIMIT: return None
        return validate_snapshot(json.loads(raw), now_ms)
    except (OSError, ValueError, TypeError, OverflowError):
        return None


def save_cache(path, snapshot):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stage = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, prefix='.currency-', delete=False) as stream:
            stage = Path(stream.name)
            os.chmod(stage, 0o600)
            json.dump(snapshot, stream, ensure_ascii=False, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(stage, path)
    finally:
        if stage is not None: stage.unlink(missing_ok=True)


def request_rates(path, refresh, emit, fetcher=fetch_json, now=None):
    now_ms = int((time.time() if now is None else now) * 1000)
    cached = load_cache(path, now_ms)
    if cached:
        emit(dict(type='cache', snapshot=cached))
        if not refresh and 0 <= now_ms - cached['fetchedAt'] < TTL_MS:
            emit(dict(type='result', success=True, cached=True, snapshot=cached))
            return
    try:
        currencies = fetcher('currencies')
        rows = fetcher('rates?base=USD')
        # Date the check after both responses complete, not when the request began.
        checked_ms = int(time.time() * 1000) if now is None else now_ms
        snapshot = snapshot_from_api(currencies, rows, checked_ms)
        if cached and any(snapshot['dates'][code] < cached['dates'][code] for code in snapshot['rates'].keys() & cached['rates'].keys()):
            raise ValueError('Provider returned older rates')
    except (OSError, ValueError, KeyError, TypeError, OverflowError):
        emit(dict(type='result', success=False, error='Could not update exchange rates. Check your connection.'))
        return
    warning = ''
    try:
        save_cache(path, snapshot)
    except OSError:
        warning = 'Rates loaded, but the offline cache could not be saved.'
    emit(dict(type='result', success=True, cached=False, snapshot=snapshot, warning=warning))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('epoch', type=int)
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--cache', type=Path, default=Path(os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache') / 'macshell-niri/currency-rates.json')
    args = parser.parse_args()
    def emit(message):
        message['epoch'] = args.epoch
        print(json.dumps(message, ensure_ascii=False, allow_nan=False), flush=True)
    request_rates(args.cache, args.refresh, emit)


if __name__ == '__main__':
    main()
