#!/usr/bin/env python3
"""Own just one wlsunset; observe gamma submission/failure, never infer from spawn."""
import os
import re
import selectors
import shutil
import subprocess
import time
from line_service import LineService, protect_child


class NightShift(LineService):
    def __init__(self):
        super().__init__()
        self.child = None
        self.desired = False
        self.temperature = 4000
        self.applied_temperature = None
        self.restart_at = 0
        self.started_at = 0
        self.submitted_at = None
        self.log = ''
        self.failed = False
        self.state = 'off'
        self.error = ''

    def wait_timeout(self):
        if self.restart_at:
            return max(0, self.restart_at - time.monotonic())
        return .2 if self.child else None

    def publish(self):
        self.emit(type='state', available=bool(shutil.which('wlsunset')), state=self.state,
                  error=self.error, desired=self.desired, temperature=self.temperature,
                  appliedTemperature=self.applied_temperature)

    def command(self, request):
        data = request.get('data', {})
        if request['action'] == 'configure':
            temperature = max(2500, min(6000, int(data.get('temperature', 4000))))
            unchanged = self.desired and bool(data.get('enabled', False)) and self.temperature == temperature
            self.desired = bool(data.get('enabled', False))
            self.temperature = temperature
            if unchanged and self.child and not self.failed and self.state in ('on', 'starting') and not self.restart_at:
                self.publish()
                return
            self.failed = False
            self.error = ''
            if self.desired:
                self.state = 'starting'
                self.restart_at = time.monotonic() + .15
            else:
                self.restart_at = 0
                self.stop()
                self.state = 'off'
        self.publish()

    def stop(self):
        if self.child:
            self.child.terminate()
            try:
                self.child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()
            self.selector.unregister(self.child.stderr)
            self.child.stderr.close()
            self.child = None
        self.submitted_at = None
        self.applied_temperature = None

    def read_log(self, source):
        data = os.read(source.fileno(), 32768)
        if not data:
            return
        self.log = (self.log + data.decode('utf-8', 'replace'))[-16384:]
        # WAYLAND_DEBUG traces the real gamma request, rather than the earlier
        # informational "setting temperature" line (which can occur on failure).
        if re.search(r'zwlr_gamma_control_v1[#@].*\.set_gamma\(', self.log):
            if self.submitted_at is None:
                self.submitted_at = time.monotonic()
        if re.search(r'\.failed\(|gamma control.*failed|doesn.t support|failed to create display', self.log, re.I):
            self.failed = True
            self.error = 'Gamma control is unavailable or another color manager owns this output.'

    def tick(self):
        now = time.monotonic()
        if self.restart_at and now >= self.restart_at:
            self.restart_at = 0
            self.stop()
            self.state = 'off'
            if self.desired:
                if not shutil.which('wlsunset'):
                    self.error = 'Install wlsunset to use Night Shift.'
                    self.state = 'unavailable'
                else:
                    env = dict(os.environ, WAYLAND_DEBUG='client')
                    self.log = ''
                    self.failed = False
                    self.error = ''
                    try:
                        self.child = subprocess.Popen(['wlsunset', '-T', str(self.temperature + 1), '-t', str(self.temperature), '-S', '00:00', '-s', '23:59', '-d', '0'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, preexec_fn=protect_child)
                        self.selector.register(self.child.stderr, selectors.EVENT_READ, self.read_log)
                        self.started_at = now
                        self.state = 'starting'
                    except OSError as error:
                        self.state = 'error'
                        self.error = 'Could not start Night Shift: ' + str(error)
            self.publish()
        if self.child and not self.restart_at:
            if self.child.poll() is not None or self.failed or self.state == 'starting' and now - self.started_at > 5:
                self.stop()
                self.state = 'error'
                self.error = self.error or 'No gamma request was accepted. Check Wayland gamma support and other color managers.'
                self.publish()
            elif self.state == 'starting' and self.submitted_at is not None and now - self.submitted_at > 1:
                self.state = 'on'
                self.applied_temperature = self.temperature
                self.publish()

    def close(self):
        self.stop()


if __name__ == '__main__':
    NightShift().run()
