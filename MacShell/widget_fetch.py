#!/usr/bin/env python3
"""One owned, cancellable request process for shared widget data."""
import json
import math
import sys
import urllib.error
import urllib.parse
import urllib.request

LIMIT = 1024 * 1024


def fetch(url, parameters=None):
    if parameters:
        url += '?' + urllib.parse.urlencode(parameters)
    request = urllib.request.Request(url, headers={'User-Agent': 'macshell-widgets (quickshell)', 'Accept': 'application/json'})
    with urllib.request.urlopen(request, timeout=8) as response:
        data = response.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError('Response too large')
    return json.loads(data)


def coordinates(value):
    latitude, longitude = float(value['latitude']), float(value['longitude'])
    if not math.isfinite(latitude) or not math.isfinite(longitude) or not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise ValueError('Invalid coordinates')
    return latitude, longitude


def weather(mode, city, unit):
    located = mode != 'city' or not city.strip()
    if not located:
        location = fetch('https://geocoding-api.open-meteo.com/v1/search', {'name': city.strip(), 'count': 1, 'language': 'en', 'format': 'json'})['results'][0]
        place = location['name']
    else:
        try:
            location = fetch('https://ipwho.is/')
            coordinates(location)
        except (OSError, ValueError, KeyError, TypeError):
            location = fetch('https://ipapi.co/json/')
        place = location.get('city') or location.get('region') or location.get('country') or 'Current Location'
    latitude, longitude = coordinates(location)
    forecast = fetch('https://api.open-meteo.com/v1/forecast', {
        'latitude': latitude, 'longitude': longitude, 'current': 'temperature_2m,weather_code,is_day',
        'hourly': 'temperature_2m,weather_code,is_day', 'daily': 'temperature_2m_max,temperature_2m_min,weather_code',
        'temperature_unit': 'fahrenheit' if unit == 'F' else 'celsius', 'timezone': 'auto', 'forecast_days': 6})
    return {'forecast': forecast, 'latitude': latitude, 'longitude': longitude, 'place': place, 'located': located}


def lyrics(title, artist, album, duration):
    try:
        return fetch('https://lrclib.net/api/get', {'track_name': title, 'artist_name': artist, 'album_name': album, 'duration': duration})
    except (OSError, ValueError):
        return fetch('https://lrclib.net/api/search', {'q': artist + ' ' + title})


def main(arguments):
    kind, epoch = arguments[0], int(arguments[1])
    try:
        if kind == 'weather' and len(arguments) == 5:
            result = weather(*arguments[2:])
        elif kind == 'lyrics' and len(arguments) == 6:
            result = lyrics(*arguments[2:])
        else:
            raise ValueError('Invalid request')
        message = {'epoch': epoch, 'success': True, 'result': result}
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        message = {'epoch': epoch, 'success': False, 'error': 'Weather unavailable.' if kind == 'weather' else 'Lyrics unavailable.'}
    print(json.dumps(message, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main(sys.argv[1:])
