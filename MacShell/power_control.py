#!/usr/bin/env python3
"""Confirmed power-profiles-daemon state and scoped Game Mode profile holds."""
from dbus_service import Service, Gio, GLib, PROPS, run

CURRENT = ('org.freedesktop.UPower.PowerProfiles', '/org/freedesktop/UPower/PowerProfiles')
LEGACY = ('net.hadess.PowerProfiles', '/net/hadess/PowerProfiles')


def endpoint(bus):
    def dbus(method, parameters=None):
        return bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                             method, parameters, None, Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
    for name, path in (CURRENT, LEGACY):
        if dbus('NameHasOwner', GLib.Variant('(s)', (name,))):
            return name, path
    activatable = dbus('ListActivatableNames')
    return LEGACY if LEGACY[0] in activatable and CURRENT[0] not in activatable else CURRENT


class PowerService(Service):
    def __init__(self):
        self.destination, self.path = endpoint(Gio.bus_get_sync(Gio.BusType.SYSTEM, None))
        self.interface = self.destination
        self.pending = False
        self.profile = ''
        self.profiles = []
        self.inhibited = ''
        self.degraded = ''
        self.error = ''
        self.game = False
        self.game_override = False
        self.hold = None
        super().__init__()
        self.bus.signal_subscribe(self.destination, PROPS, 'PropertiesChanged', self.path,
                                  self.interface, Gio.DBusSignalFlags.NONE, self.changed)
        self.bus.signal_subscribe(self.destination, self.interface, 'ProfileReleased', self.path,
                                  None, Gio.DBusSignalFlags.NONE, self.released)
        GLib.timeout_add_seconds(15, self.tick)

    def appeared(self, connection, name, owner):
        super().appeared(connection, name, owner)
        self.snapshot()
        self.reconcile_game()

    def vanished(self, connection, name):
        self.pending = False
        self.hold = None
        self.profile = ''
        self.profiles = []
        super().vanished(connection, name)

    def changed(self, *args):
        self.snapshot()

    def released(self, connection, sender, path, interface, signal, parameters):
        if parameters.unpack()[0] == self.hold:
            self.hold = None
            self.game_override = self.game
            self.snapshot()

    def tick(self):
        if self.owner:
            self.snapshot()
        return True

    def snapshot(self):
        if not self.owner:
            return
        try:
            props = self.props(self.path, self.interface)
            self.profile = props.get('ActiveProfile', '')
            self.profiles = [p['Profile'] for p in props.get('Profiles', []) if p.get('Profile')]
            self.inhibited = props.get('PerformanceInhibited', '')
            self.degraded = props.get('PerformanceDegraded', '')
            self.emit(type='state', available=True, profile=self.profile, profiles=self.profiles,
                      inhibited=self.inhibited, degraded=self.degraded, busy=self.pending,
                      gameHold=self.hold is not None, error=self.error)
        except GLib.Error as error:
            self.emit(type='unavailable', error=self.friendly_error(error))

    def complete(self, error=None):
        self.pending = False
        self.error = self.friendly_error(error) if error else ''
        self.snapshot()
        if error is None:
            self.reconcile_game()

    def release(self, then):
        if self.hold is None:
            then(None)
            return
        cookie = self.hold
        def done(value, error):
            if error is None and self.hold == cookie:
                self.hold = None
            then(error)
        self.async_call(self.path, self.interface, 'ReleaseProfile', GLib.Variant('(u)', (cookie,)), done)

    def reconcile_game(self):
        if self.pending or not self.owner:
            return
        if not self.game and self.hold is not None:
            self.pending = True
            self.snapshot()
            self.release(self.complete)
        elif self.game and not self.game_override and self.hold is None:
            if 'performance' not in self.profiles or self.inhibited:
                self.game_override = True
                self.error = 'Performance profile is unavailable' + (': ' + self.inhibited if self.inhibited else '.')
                self.snapshot()
                return
            self.pending = True
            self.snapshot()
            def held(value, error):
                if error:
                    self.game_override = True
                else:
                    self.hold = value[0]
                self.complete(error)
            self.async_call(self.path, self.interface, 'HoldProfile',
                            GLib.Variant('(sss)', ('performance', 'Game Mode', 'org.macshell.niri')), held)

    def select(self, profile):
        if self.pending:
            raise ValueError('A power profile change is already in progress.')
        if not self.owner:
            raise ValueError('The power profiles service is unavailable.')
        if profile not in self.profiles:
            raise ValueError('This power profile is not supported on this device.')
        if profile == 'performance' and self.inhibited:
            raise ValueError('Performance is unavailable: ' + self.inhibited)
        self.pending = True
        self.game_override = self.game
        self.error = ''
        self.snapshot()
        def set_profile(error):
            if error:
                self.complete(error)
                return
            def done(value, error):
                if error is None:
                    try:
                        actual = self.props(self.path, self.interface).get('ActiveProfile')
                        if actual != profile:
                            error = ValueError('The system did not activate the requested power profile.')
                    except GLib.Error as exc:
                        error = exc
                self.complete(error)
            self.async_call(self.path, PROPS, 'Set',
                            GLib.Variant('(ssv)', (self.interface, 'ActiveProfile', GLib.Variant('s', profile))), done)
        self.release(set_profile)

    def command(self, request):
        action, data = request['action'], request.get('data', {})
        if action == 'refresh':
            self.snapshot()
        elif action == 'select':
            self.select(data.get('profile', ''))
        elif action == 'game':
            desired = bool(data.get('enabled', False))
            if desired != self.game:
                self.game = desired
                self.game_override = False
            self.reconcile_game()
            self.snapshot()
        else:
            raise ValueError('Unknown power operation.')


if __name__ == '__main__':
    run(PowerService)
