#!/usr/bin/env python3
"""One current-user fprintd operation, supervised by the settings pane.

The helper never handles fingerprint images or accepts a username. A closed stdin
cancels the operation; D-Bus disconnection releases a claim even if killed.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

from gi.repository import Gio, GLib

BUS = "net.reactivated.Fprint"
MANAGER = "/net/reactivated/Fprint/Manager"
DEVICE = BUS + ".Device"
FINGERS = tuple(side + "-" + finger for side in ("left", "right") for finger in
                ("thumb", "index-finger", "middle-finger", "ring-finger", "little-finger"))


def emit(**message):
    print(json.dumps(message, separators=(",", ":")), flush=True)


def error_code(error):
    text = str(error)
    for name, code in (("AlreadyInUse", "busy"), ("PermissionDenied", "permission"),
                       ("NoEnrolledPrints", "no_finger"), ("NoSuchDevice", "device_gone"),
                       ("InvalidFingername", "invalid_finger"), ("TimedOut", "timeout")):
        if name in text:
            return code
    return "service_error"


class Operation:
    def __init__(self, bus, operation, path, finger, done, service=BUS):
        if (operation not in ("enroll", "verify", "delete") or finger not in FINGERS
                or service != BUS):
            raise ValueError("invalid operation, finger or service")
        self.bus, self.operation, self.path, self.finger, self.done = bus, operation, path, finger, done
        self.service = service
        self.claimed = False
        self.active = False
        self.pending = False
        self.cancellation = None
        self.finished = False
        self.stage = 0
        self.total = 0
        self.subscription = 0
        self.presence_subscription = 0
        self.finger_present = None
        self.presence_seen = False
        self.owner_subscription = 0
        self.starting = False
        self.early_signals = []
        self.cleanup_failed = False
        self.authorizer = None
        self.auth_watch = 0

    def call(self, path, interface, method, args, callback):
        self.pending = True
        def completed(connection, result, _data):
            self.pending = False
            if self.finished:
                return
            try:
                value = connection.call_finish(result).unpack()
            except Exception as error:
                callback(None, error)
            else:
                callback(value, None)
        self.bus.call(self.service, path, interface, method, args, None,
                      Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 10000, None, completed, None)

    def start(self):
        self.owner_subscription = self.bus.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
            "/org/freedesktop/DBus", self.service, Gio.DBusSignalFlags.NONE, self.owner_changed, None)
        emit(type="status", code="checking")
        self.call(MANAGER, BUS + ".Manager", "GetDevices", None, self.got_devices)

    def owner_changed(self, _connection, _sender, _path, _interface, _signal, parameters, _data):
        _name, old, new = parameters.unpack()
        # fprintd may idle-exit while the user is answering PolicyKit. It can be
        # activated again on Claim; only a lost claimed/active device is fatal.
        if old and old != new and not self.finished and (self.claimed or self.active or self.starting):
            self.claimed = False
            self.active = False
            self.finish(False, "service_error")

    def got_devices(self, result, error):
        if error:
            return self.finish(False, error_code(error))
        if self.cancellation:
            return self.finish(False, self.cancellation)
        if self.path not in result[0]:
            return self.finish(False, "device_gone")
        if self.operation in ("enroll", "delete") and shutil.which("pkcheck"):
            return self.authorize()
        self.claim()

    def authorize(self):
        # Ask before claiming the reader, so a human has time to enter a password
        # and can cancel the prompt without leaving an active fprintd operation.
        try:
            self.authorizer = subprocess.Popen(
                ["pkcheck", "--action-id", "net.reactivated.fprint.device.enroll",
                 "--system-bus-name", self.bus.get_unique_name(), "--allow-user-interaction"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            return self.finish(False, "permission")
        emit(type="status", code="checking")
        self.auth_watch = GLib.timeout_add(100, self.check_authorization)

    def check_authorization(self):
        if self.finished or not self.authorizer:
            self.auth_watch = 0
            return False
        result = self.authorizer.poll()
        if result is None:
            return True
        self.authorizer = None
        self.auth_watch = 0
        if self.cancellation:
            self.finish(False, self.cancellation)
        elif result != 0:
            self.finish(False, "permission")
        else:
            self.claim()
        return False

    def claim(self):
        self.call(self.path, DEVICE, "Claim", GLib.Variant("(s)", ("",)), self.got_claim)

    def got_claim(self, _result, error):
        if error:
            return self.finish(False, self.cancellation or error_code(error))
        self.claimed = True
        if self.cancellation:
            return self.finish(False, self.cancellation)
        # Always inspect again while holding the claim. Never silently replace an
        # existing finger or delete/verify one that is no longer registered.
        self.call(self.path, DEVICE, "ListEnrolledFingers", GLib.Variant("(s)", ("",)), self.got_fingers)

    def got_fingers(self, result, error):
        if self.cancellation:
            return self.finish(False, self.cancellation)
        if error and "NoEnrolledPrints" not in str(error):
            return self.finish(False, error_code(error))
        fingers = [] if error else result[0]
        if self.operation == "enroll" and self.finger in fingers:
            return self.finish(False, "already_enrolled")
        if self.operation != "enroll" and self.finger not in fingers:
            return self.finish(False, "no_finger")
        if self.operation == "delete":
            return self.call(self.path, DEVICE, "DeleteEnrolledFinger", GLib.Variant("(s)", (self.finger,)), self.deleted)
        self.subscription = self.bus.signal_subscribe(self.service, DEVICE, self.operation.capitalize() + "Status", self.path, None,
                                                      Gio.DBusSignalFlags.NONE, self.on_signal, None)
        self.presence_subscription = self.bus.signal_subscribe(
            self.service, "org.freedesktop.DBus.Properties", "PropertiesChanged", self.path, DEVICE,
            Gio.DBusSignalFlags.NONE, self.on_properties_changed, None)
        self.call(self.path, "org.freedesktop.DBus.Properties", "GetAll", GLib.Variant("(s)", (DEVICE,)), self.got_properties)

    def got_properties(self, result, _error):
        if self.cancellation:
            return self.finish(False, self.cancellation)
        if result:
            properties = result[0]
            try: self.total = max(0, min(100, int(properties.get("num-enroll-stages", 0))))
            except (TypeError, ValueError): self.total = 0
            if not self.presence_seen and type(properties.get("finger-present")) is bool:
                self.finger_present = properties["finger-present"]
        self.begin()

    def on_properties_changed(self, _connection, _sender, _path, _interface, _signal, parameters, _data):
        if self.finished or self.cancellation or (not self.active and not self.starting and not self.pending):
            return
        interface, changed, invalidated = parameters.unpack()
        if interface != DEVICE:
            return
        if 'finger-present' in invalidated:
            self.finger_present = None
        elif type(changed.get('finger-present')) is bool:
            self.finger_present = changed['finger-present']
        else:
            return
        self.presence_seen = True
        if self.active:
            emit(type="finger-presence", present=self.finger_present)

    def begin(self):
        self.starting = True
        self.call(self.path, DEVICE, self.operation.capitalize() + "Start", GLib.Variant("(s)", (self.finger,)), self.started)

    def started(self, _result, error):
        self.starting = False
        if error:
            return self.finish(False, self.cancellation or error_code(error))
        self.active = True
        if self.cancellation:
            return self.finish(False, self.cancellation)
        emit(type="status", code="scan", stage=self.stage, total=self.total)
        if self.presence_seen or self.finger_present is not None:
            emit(type="finger-presence", present=self.finger_present)
        for code, done in self.early_signals:
            if not self.active:
                break
            self.handle_signal(code, done)
        self.early_signals.clear()

    def deleted(self, _result, error):
        # A completed delete cannot be cancelled retroactively.
        self.finish(error is None, "deleted" if error is None else error_code(error))

    def on_signal(self, _connection, _sender, _path, _interface, _signal, parameters, _data):
        if self.finished:
            return
        code, done = parameters.unpack()
        if self.starting:
            self.early_signals.append((code, done))
            return
        if not self.active:
            return
        self.handle_signal(code, done)

    def handle_signal(self, code, done):
        if code == "enroll-stage-passed":
            self.stage += 1
        if code.endswith("-disconnected"):
            self.active = False
            self.claimed = False
            # fprintd uses this status for both physical removal and a driver
            # protocol error. Query the manager, never the failed device.
            return self.call(MANAGER, BUS + ".Manager", "GetDevices", None, self.after_disconnect)
        if done:
            success = code in ("enroll-completed", "verify-match")
            return self.finish(success, code)
        emit(type="status", code=code, stage=self.stage, total=self.total)

    def after_disconnect(self, result, error):
        code = "driver_error" if not error and self.path in result[0] else "device_gone"
        self.finish(False, self.cancellation or code)

    def cancel(self, reason="cancelled"):
        if self.finished:
            return
        self.cancellation = reason
        self.stop_authorizer()
        if not self.pending:
            self.finish(False, reason)

    def stop_authorizer(self):
        if not self.authorizer:
            return
        try:
            self.authorizer.terminate()
            try:
                self.authorizer.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                self.authorizer.kill()
                self.authorizer.wait(timeout=.5)
        except (OSError, subprocess.TimeoutExpired):
            pass
        self.authorizer = None

    def finish(self, success, code):
        if self.finished:
            return
        self.stop_authorizer()
        if self.active:
            self.active = False
            return self.call(self.path, DEVICE, self.operation.capitalize() + "Stop", None,
                             lambda _r, error: self.cleanup_done(error, success, code))
        if self.claimed:
            self.claimed = False
            return self.call(self.path, DEVICE, "Release", None, lambda _r, error: self.cleanup_done(error, success, code))
        self.finished = True
        if self.subscription:
            self.bus.signal_unsubscribe(self.subscription)
        if self.presence_subscription:
            self.bus.signal_unsubscribe(self.presence_subscription)
        if self.owner_subscription:
            self.bus.signal_unsubscribe(self.owner_subscription)
        if self.auth_watch:
            GLib.source_remove(self.auth_watch)
            self.auth_watch = 0
        result = dict(type="result", success=success, code=code)
        if self.cleanup_failed:
            result["cleanupFailed"] = True
        emit(**result)
        self.done()

    def cleanup_done(self, error, success, code):
        if error:
            self.cleanup_failed = True
        self.finish(success, code)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("enroll", "verify", "delete"))
    parser.add_argument("device")
    parser.add_argument("finger", choices=FINGERS)
    args = parser.parse_args()
    loop = GLib.MainLoop()
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    except Exception:
        emit(type="result", success=False, code="service_error")
        return
    operation = Operation(bus, args.operation, args.device, args.finger, loop.quit)
    buffer = bytearray()
    def input_ready(_source, condition):
        if condition & (GLib.IO_HUP | GLib.IO_ERR):
            operation.cancel()
            return False
        try: chunk = os.read(sys.stdin.fileno(), 4096)
        except OSError: chunk = b""
        if not chunk:
            operation.cancel()
            return False
        buffer.extend(chunk)
        if len(buffer) > 4096:
            operation.cancel()
            return False
        while b"\n" in buffer:
            line, _, remainder = buffer.partition(b"\n")
            buffer[:] = remainder
            if line == b"cancel": operation.cancel()
        return True
    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, input_ready)
    GLib.timeout_add_seconds(120, lambda: (operation.cancel("timeout"), False)[1])
    operation.start()
    loop.run()


if __name__ == "__main__":
    main()
