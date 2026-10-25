"""Small Gio JSON-lines transport. No user secrets are written to argv or stderr."""
import json
import os
import sys
import gi

gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

PROPS = 'org.freedesktop.DBus.Properties'


class Service:
    destination = ''

    def __init__(self):
        self.loop = GLib.MainLoop()
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.buffer = b''
        self.closed = False
        self.generation = None
        self.owner = ''
        self.watch = Gio.bus_watch_name_on_connection(self.bus, self.destination, Gio.BusNameWatcherFlags.NONE,
                                                      self.appeared, self.vanished)
        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, self.input)

    def emit(self, **data):
        if self.generation is not None:
            data['generation'] = self.generation
        try:
            print(json.dumps(data), flush=True)
        except BrokenPipeError:
            self.close()

    def sync(self, path, interface, method, parameters=None, timeout=2000):
        return self.bus.call_sync(self.destination, path, interface, method, parameters, None,
                                  Gio.DBusCallFlags.NONE, timeout, None).unpack()

    def props(self, path, interface):
        return self.sync(path, PROPS, 'GetAll', GLib.Variant('(s)', (interface,)))[0]

    def async_call(self, path, interface, method, parameters, callback, timeout=15000):
        owner = self.owner
        def done(bus, result):
            if self.owner != owner or self.closed:
                return
            try:
                value, error = bus.call_finish(result).unpack(), None
            except GLib.Error as exc:
                value, error = None, exc
            callback(value, error)
        self.bus.call(self.destination, path, interface, method, parameters, None,
                      Gio.DBusCallFlags.NONE, timeout, None, done)

    def input(self, fd, condition):
        data = os.read(fd, 65536)
        if not data:
            self.close()
            return False
        self.buffer += data
        if len(self.buffer) > 1048576:
            self.close()
            return False
        while b'\n' in self.buffer:
            line, self.buffer = self.buffer.split(b'\n', 1)
            try:
                request = json.loads(line)
                if not isinstance(request, dict) or not isinstance(request.get('data', {}), dict):
                    raise ValueError('Invalid service request')
                self.generation = request.get('generation')
                self.command(request)
            except (ValueError, KeyError, TypeError, GLib.Error) as error:
                self.emit(type='error', id=request.get('id') if isinstance(locals().get('request'), dict) else None,
                          error=self.friendly_error(error))
        return True

    def friendly_error(self, error):
        return str(error).split(': ', 1)[-1][:220]

    def appeared(self, connection, name, owner):
        self.owner = owner
        self.emit(type='ready')

    def vanished(self, connection, name):
        self.owner = ''
        self.emit(type='unavailable', error='System service is unavailable.')

    def command(self, request):
        raise ValueError('Unknown request')

    def close(self):
        self.closed = True
        self.loop.quit()

    def run(self):
        self.loop.run()


def run(service_type):
    try:
        service_type().run()
    except GLib.Error:
        print(json.dumps({'type': 'unavailable', 'error': 'Cannot reach the system D-Bus service.'}), flush=True)
        # Exit so the frontend retries with backoff, rather than pretending to be ready.
        sys.exit(1)
