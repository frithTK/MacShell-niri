"""Selector-based JSON-lines transport for owned subprocess helpers."""
import ctypes
import json
import os
import selectors
import signal
import sys
import time


_libc = ctypes.CDLL(None, use_errno=True)


def protect_child():
    # All callers fork from a single-threaded helper. Linux kills only this
    # helper's children if Quickshell terminates the helper before cleanup.
    _libc.prctl(1, signal.SIGINT)
    if os.getppid() == 1:
        os._exit(1)


class LineService:
    def __init__(self):
        self.selector = selectors.DefaultSelector()
        self.selector.register(sys.stdin, selectors.EVENT_READ, self.input)
        self.buffer = b''
        self.generation = None
        self.running = True
        self.signal_read, self.signal_write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        self.previous_wakeup = signal.set_wakeup_fd(self.signal_write)
        self.selector.register(self.signal_read, selectors.EVENT_READ, self.drain_signal)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda *_: setattr(self, 'running', False))

    def drain_signal(self, source):
        try:
            os.read(source, 4096)
        except BlockingIOError:
            pass

    def emit(self, **data):
        if self.generation is not None:
            data['generation'] = self.generation
        try:
            print(json.dumps(data), flush=True)
        except BrokenPipeError:
            self.running = False

    def input(self, source):
        data = os.read(source.fileno(), 65536)
        if not data:
            self.running = False
            return
        self.buffer += data
        if len(self.buffer) > 1048576:
            self.running = False
            return
        while b'\n' in self.buffer:
            raw, self.buffer = self.buffer.split(b'\n', 1)
            try:
                request = json.loads(raw)
                if not isinstance(request, dict) or not isinstance(request.get('data', {}), dict):
                    raise ValueError('Invalid service request')
                self.generation = request['generation']
                self.command(request)
            except (ValueError, TypeError, KeyError, OSError) as error:
                self.emit(type='error', error=str(error)[:200])

    def wait_timeout(self):
        return .2

    def tick(self):
        pass

    def close(self):
        pass

    def run(self):
        self.emit(type='ready')
        try:
            while self.running:
                for key, mask in self.selector.select(self.wait_timeout()):
                    key.data(key.fileobj)
                if self.running:
                    self.tick()
        finally:
            try:
                self.close()
            finally:
                signal.set_wakeup_fd(self.previous_wakeup)
                self.selector.close()
                os.close(self.signal_read)
                os.close(self.signal_write)
