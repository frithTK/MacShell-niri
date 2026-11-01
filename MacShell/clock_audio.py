"""Owned playback for a single claimed Clock event."""

import contextlib
import json
import subprocess
import sys
from pathlib import Path

from line_service import protect_child
from clock_sound_options import normalize


RING_LIMIT_MS = 5 * 60 * 1000
REPEAT_DELAY_MS = 250


class ClockAudio:
    def __init__(self, sound_dir):
        self.sound_dir = Path(sound_dir)
        self.event_id = None
        self.kind = None
        self.child = None
        self.next_play_ms = 0
        self.stop_at_ms = 0
        self.failed = False
        self.fallback_used = False
        self.selected_path = None
        self.finished = False
        self.options = normalize(None)
        self.started_ms = 0

    def stop(self):
        if self.child is not None:
            if self.child.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    self.child.terminate()
                try:
                    self.child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        self.child.kill()
                    self.child.wait()
            self.child = None
        self.event_id = None
        self.kind = None
        self.failed = False
        self.fallback_used = False
        self.selected_path = None
        self.finished = False

    def start(self, event, boot_now, sound_path=None):
        self.stop()
        if event.get('kind') not in ('timer', 'alarm'):
            raise ValueError('Invalid sound event')
        self.event_id = event['eventId']
        self.kind = event['kind']
        self.selected_path = Path(sound_path) if sound_path is not None else None
        self.options = normalize(event.get('soundOptions'))
        self.started_ms = boot_now
        self.stop_at_ms = boot_now + RING_LIMIT_MS
        self.next_play_ms = boot_now
        self.tick(event, boot_now)

    def tick(self, event, boot_now):
        if self.event_id is None:
            return
        if not event or event.get('eventId') != self.event_id or boot_now >= self.stop_at_ms:
            self.stop()
            return
        if self.child is not None:
            code = self.child.poll()
            if code is None:
                return
            self.child = None
            if code != 0:
                if (self.playing_custom or self.advanced_play) and not self.fallback_used:
                    self.fallback_used = True
                    self.next_play_ms = boot_now
                else:
                    self.failed = True
                    return
            else:
                if not self.options['repeat']:
                    self.finished = True
                    return
                self.next_play_ms = boot_now + REPEAT_DELAY_MS
        if self.failed or self.finished or boot_now < self.next_play_ms:
            return
        filename = self.kind + '.wav'
        path = self.selected_path if self.selected_path is not None else self.sound_dir / filename
        self.playing_custom = path.is_file() and not self.fallback_used
        if not self.playing_custom:
            path = Path(__file__).with_name('sounds') / filename
        options = dict(self.options)
        if self.fallback_used or (self.selected_path is not None and not self.playing_custom):
            options.update(startMs=0, durationMs=0, fadeMs=0)
        self.advanced_play = bool(options['fadeMs'] or options['startMs'] or options['durationMs'] or path.suffix.lower() != '.wav')
        if self.advanced_play:
            options['fadeElapsedMs'] = max(0, boot_now - self.started_ms)
            command = [sys.executable, str(Path(__file__).with_name('clock_audio_player.py')),
                       str(path), json.dumps(options, separators=(',', ':'))]
        else:
            command = ['pw-play', '--volume=' + str(options['volume'] / 100), str(path)]
        try:
            self.child = subprocess.Popen(command,
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, preexec_fn=protect_child)
        except OSError:
            self.failed = True

    def timeout(self, boot_now):
        if self.event_id is None or self.failed or self.finished:
            return None
        if self.child is not None:
            return max(0, min(.25, (self.stop_at_ms - boot_now) / 1000))
        return max(0, min((self.next_play_ms - boot_now) / 1000, (self.stop_at_ms - boot_now) / 1000))


class ClockPreview:
    """One bounded preview, owned by the same service as alert playback."""
    LIMIT_MS = 15000

    def __init__(self):
        self.child = None
        self.sound_id = None
        self.stop_at_ms = 0

    def stop(self):
        if self.child is not None:
            if self.child.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    self.child.terminate()
                try:
                    self.child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        self.child.kill()
                    self.child.wait()
            self.child = None
        self.sound_id = None

    def start(self, sound_id, path, boot_now, options=None):
        self.stop()
        settings = normalize(options)
        if settings['fadeMs'] or settings['startMs'] or settings['durationMs'] or Path(path).suffix.lower() != '.wav':
            settings['fadeElapsedMs'] = 0
            command = [sys.executable, str(Path(__file__).with_name('clock_audio_player.py')),
                       str(path), json.dumps(settings, separators=(',', ':'))]
        else:
            command = ['pw-play', '--volume=' + str(settings['volume'] / 100), str(path)]
        self.child = subprocess.Popen(command,
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, preexec_fn=protect_child)
        self.sound_id = sound_id
        self.stop_at_ms = boot_now + self.LIMIT_MS

    def tick(self, boot_now):
        if self.child is None:
            return False
        code = self.child.poll()
        failed = code is not None and code != 0
        if code is not None or boot_now >= self.stop_at_ms:
            self.stop()
        return failed

    def timeout(self, boot_now):
        if self.child is None:
            return None
        return max(0, min(.25, (self.stop_at_ms - boot_now) / 1000))
