#!/usr/bin/env python3
"""Decode one bounded alert fragment and play it through PipeWire."""
import contextlib
import json
import signal
import subprocess
import sys

from clock_sound_options import normalize
from line_service import protect_child


def stop(child):
    if child is None:
        return
    if child.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            child.terminate()
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                child.kill()
            child.wait()


def main():
    if len(sys.argv) != 3:
        return 2
    options = normalize(json.loads(sys.argv[2]))
    decoder = player = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(1))
    try:
        if options['startMs']:
            probe = subprocess.run(['ffprobe', '-v', 'error', '-protocol_whitelist', 'file,pipe',
                                    '-show_entries', 'format=duration', '-of', 'json', sys.argv[1]],
                                   stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=10,
                                   preexec_fn=protect_child)
            duration = float(json.loads(probe.stdout)['format']['duration'])
            if not duration > options['startMs'] / 1000:
                return 1
        command = ['ffmpeg', '-nostdin', '-v', 'error', '-xerror']
        if options['startMs']:
            command += ['-ss', str(options['startMs'] / 1000)]
        command += ['-protocol_whitelist', 'file,pipe', '-i', sys.argv[1], '-map', '0:a:0']
        if options['durationMs']:
            command += ['-t', str(options['durationMs'] / 1000)]
        if options['fadeMs']:
            elapsed = options.get('fadeElapsedMs', 0)
            if type(elapsed) is not int or elapsed < 0:
                return 1
            command += ['-af', "volume='min(1,(t+" + str(elapsed / 1000) + ")/" + str(options['fadeMs'] / 1000) + ")':eval=frame"]
        command += ['-f', 's16le', '-ac', '2', '-ar', '48000', 'pipe:1']
        decoder = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, preexec_fn=protect_child)
        player = subprocess.Popen(['pw-play', '--raw', '--rate=48000', '--channels=2', '--format=s16',
                                   '--volume=' + str(options['volume'] / 100), '-'],
                                  stdin=decoder.stdout, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, preexec_fn=protect_child)
        decoder.stdout.close()
        player_code = player.wait()
        decoder_code = decoder.wait()
        return 0 if player_code == 0 and decoder_code == 0 else 1
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        return 1
    finally:
        stop(player)
        stop(decoder)


if __name__ == '__main__':
    sys.exit(main())
