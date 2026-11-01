#!/usr/bin/env python3
"""Verify Clock fragment playback using a private PipeWire server and null sink."""
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.05)
    raise RuntimeError(message)


def stop(child):
    if child and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=4)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def child():
    with tempfile.TemporaryDirectory(prefix='macshell-clock-audio-') as directory:
        root = Path(directory)
        for name in ('config', 'state', 'cache'):
            (root / name).mkdir()
        env = dict(os.environ, HOME=directory, XDG_RUNTIME_DIR=directory, PIPEWIRE_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'),
                   XDG_CACHE_HOME=str(root / 'cache'), GIO_USE_VFS='local',
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-system-bus'))
        for name in ('PIPEWIRE_REMOTE', 'PIPEWIRE_CONFIG_DIR', 'WIREPLUMBER_CONFIG_DIR'):
            env.pop(name, None)
        log_path = root / 'audio.log'
        with log_path.open('w+') as log:
            pipewire = subprocess.Popen(['pipewire'], env=env, stdout=log, stderr=log)
            manager = recorder = None
            try:
                wait_for(lambda: (root / 'pipewire-0').exists() or pipewire.poll() is not None, 'private PipeWire did not start')
                if pipewire.poll() is not None or not (root / 'pipewire-0').exists():
                    raise RuntimeError('private PipeWire exited')
                # The policy profile intentionally excludes ALSA, Bluetooth and hardware discovery.
                manager = subprocess.Popen(['wireplumber', '-p', 'policy'], env=env, stdout=log, stderr=log)
                time.sleep(.6)
                subprocess.run(['pw-cli', 'create-node', 'adapter',
                                '{ factory.name = support.null-audio-sink node.name = clock-test media.class = Audio/Sink audio.position = [ FL FR ] object.linger = true }'],
                               env=env, stdout=log, stderr=log, timeout=8, check=True)
                def sink_ready():
                    result = subprocess.run(['pw-dump', '-N'], env=env, capture_output=True, text=True, timeout=5)
                    return result.returncode == 0 and 'clock-test' in result.stdout
                wait_for(sink_ready, 'private null sink unavailable')
                source = root / 'tone.wav'
                samples = [round(15000 * math.sin(2 * math.pi * 440 * i / 48000)) for i in range(96000)]
                with wave.open(str(source), 'wb') as output:
                    output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
                    output.writeframes(struct.pack('<' + str(len(samples)) + 'h', *samples))
                peaks = []
                for volume in (80, 40):
                    captured = root / ('capture-' + str(volume) + '.raw')
                    with captured.open('wb') as output:
                        recorder = subprocess.Popen(['pw-record', '--raw', '--rate=48000', '--channels=2', '--format=s16',
                                                     '--target=clock-test', '-P', '{ stream.capture.sink = true }', '-'],
                                                    env=env, stdout=output, stderr=log)
                        time.sleep(.5)
                        options = {'volume': volume, 'startMs': 300, 'durationMs': 600, 'fadeMs': 600}
                        start = time.monotonic()
                        result = subprocess.run([sys.executable, str(ROOT / 'MacShell/clock_audio_player.py'),
                                                 str(source), json.dumps(options)], env=env, stdout=log, stderr=log, timeout=8)
                        elapsed = time.monotonic() - start
                        time.sleep(.5)
                        stop(recorder)
                        recorder = None
                    if result.returncode or not .35 <= elapsed < 3:
                        raise RuntimeError('fragment player failed or ignored its duration')
                    data = captured.read_bytes()
                    data = data[:len(data) // 2 * 2]
                    recorded = struct.unpack('<' + str(len(data) // 2) + 'h', data)
                    blocks = []
                    block_size = 4800  # 50 ms at 48 kHz stereo
                    for offset in range(0, len(recorded) - block_size, block_size):
                        block = recorded[offset:offset + block_size]
                        blocks.append(math.sqrt(sum(value * value for value in block) / len(block)))
                    active = [index for index, level in enumerate(blocks) if level > 100]
                    if len(active) < 7:
                        raise RuntimeError('fragment was not audible in private sink')
                    first, last = active[0], active[-1]
                    if last - first > 18 or max(blocks[first:first + 2]) >= max(blocks[max(first, last - 2):last + 1]) * .65:
                        raise RuntimeError('fade or fragment length was not reflected in captured sound')
                    peaks.append(max(blocks))
                if not .40 <= peaks[1] / peaks[0] <= .60:
                    raise RuntimeError('stream volume did not scale the captured audio')
                compressed = root / 'tone.m4a'
                encoded = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(source), str(compressed)],
                                         env=env, stdout=log, stderr=log, timeout=10)
                if encoded.returncode == 0:
                    captured = root / 'compressed.raw'
                    with captured.open('wb') as output:
                        recorder = subprocess.Popen(['pw-record', '--raw', '--rate=48000', '--channels=2', '--format=s16',
                                                     '--target=clock-test', '-P', '{ stream.capture.sink = true }', '-'],
                                                    env=env, stdout=output, stderr=log)
                        time.sleep(.3)
                        result = subprocess.run([sys.executable, str(ROOT / 'MacShell/clock_audio_player.py'),
                                                 str(compressed), '{}'], env=env, stdout=log, stderr=log, timeout=8)
                        time.sleep(.3)
                        stop(recorder)
                        recorder = None
                    data = captured.read_bytes()
                    data = data[:len(data) // 2 * 2]
                    pcm = struct.unpack('<' + str(len(data) // 2) + 'h', data)
                    if result.returncode or max((abs(value) for value in pcm), default=0) < 1000:
                        raise RuntimeError('AAC audio was not decoded into the private sink')
                print('CLOCK_AUDIO_NATIVE_PASS: private PipeWire null sink, fragment, volume, fade' +
                      (', AAC' if encoded.returncode == 0 else ' (AAC encoder unavailable)'))
            finally:
                stop(recorder)
                stop(manager)
                stop(pipewire)


if __name__ == '__main__':
    if '--child' in sys.argv:
        child()
    else:
        sys.exit(subprocess.call(['dbus-run-session', '--', sys.executable, str(Path(__file__).resolve()), '--child']))
