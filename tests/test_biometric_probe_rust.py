"""Read-only Rust fprintd discovery against a private synthetic D-Bus service."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from gi.repository import Gio, GLib

ROOT = Path(__file__).resolve().parents[1]
SERVICE = "net.reactivated.Fprint"
MANAGER = "/net/reactivated/Fprint/Manager"
DEVICE = "/net/reactivated/Fprint/Device/0"
DEVICE_IFACE = SERVICE + ".Device"


class FprintBus:
    def __init__(self, devices=None, fingers=None, list_error=None):
        self.daemon = subprocess.Popen(
            ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        self.address = self.daemon.stdout.readline().strip()
        self.connection = Gio.DBusConnection.new_for_address_sync(
            self.address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None,
            None,
        )
        self.devices = list(devices if devices is not None else [DEVICE])
        self.fingers = list(fingers if fingers is not None else ["left-index-finger"])
        self.list_error = list_error
        self.calls = []
        self.registrations = []
        manager_xml = """<node><interface name="net.reactivated.Fprint.Manager">
            <method name="GetDevices"><arg type="ao" direction="out"/></method>
        </interface></node>"""
        device_xml = """<node><interface name="net.reactivated.Fprint.Device">
            <method name="ListEnrolledFingers"><arg type="s" direction="in"/><arg type="as" direction="out"/></method>
            <property name="name" type="s" access="read"/>
            <property name="scan-type" type="s" access="read"/>
        </interface></node>"""
        self.registrations.append(self.connection.register_object(
            MANAGER, Gio.DBusNodeInfo.new_for_xml(manager_xml).interfaces[0], self.method, None, None))
        self.registrations.append(self.connection.register_object(
            DEVICE, Gio.DBusNodeInfo.new_for_xml(device_xml).interfaces[0], self.method, self.prop, None))
        self.connection.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            GLib.Variant("(su)", (SERVICE, 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()

    def prop(self, _connection, _sender, _path, _interface, name):
        return {"name": GLib.Variant("s", "Fixture reader"),
                "scan-type": GLib.Variant("s", "swipe")}[name]

    def method(self, _connection, _sender, path, _interface, method, parameters, invocation):
        values = parameters.unpack() if parameters else ()
        self.calls.append((path, method, values))
        if method == "GetDevices":
            invocation.return_value(GLib.Variant("(ao)", (self.devices,)))
        elif method == "ListEnrolledFingers":
            if self.list_error:
                invocation.return_dbus_error("net.reactivated.Fprint.Error." + self.list_error, "fixture error")
            else:
                invocation.return_value(GLib.Variant("(as)", (self.fingers,)))
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "unknown")

    def close(self):
        self.loop.quit()
        self.thread.join(timeout=3)
        for registration in self.registrations:
            self.connection.unregister_object(registration)
        self.connection.close_sync(None)
        self.daemon.terminate()
        self.daemon.wait(timeout=3)
        self.daemon.stdout.close()


class BiometricProbeRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="biometric-probe-build-")
        cls.addClassCleanup(cls.build.cleanup)
        subprocess.run([
            "cargo", "build", "--offline", "--locked", "--manifest-path",
            str(ROOT / "native/biometric-probe/Cargo.toml"), "--target-dir", cls.build.name,
        ], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / "debug/macshell-biometric-probe"

    def run_probe(self, bus):
        result = subprocess.run(
            [str(self.binary)],
            env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=bus.address),
            capture_output=True,
            text=True,
            check=True,
            timeout=8,
        )
        return json.loads(result.stdout)

    def test_reads_current_user_and_never_claims_device(self):
        bus = FprintBus()
        self.addCleanup(bus.close)
        result = self.run_probe(bus)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["devices"], [{"path": DEVICE, "name": "Fixture reader", "fingers": ["left-index-finger"], "enrollment": "ok", "scanType": "swipe"}])
        self.assertEqual([method for _path, method, _values in bus.calls], ["GetDevices", "ListEnrolledFingers"])
        self.assertEqual(bus.calls[-1][2][0], os.environ.get("USER", ""))

    def test_empty_and_unknown_enrollment_are_distinct(self):
        empty = FprintBus(devices=[])
        self.addCleanup(empty.close)
        self.assertEqual(self.run_probe(empty), {"status": "no_device", "devices": []})
        unknown = FprintBus(list_error="PermissionDenied")
        self.addCleanup(unknown.close)
        self.assertEqual(self.run_probe(unknown)["devices"][0]["enrollment"], "unknown")

    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        with tempfile.TemporaryDirectory(prefix="biometric-launcher-") as directory:
            root = Path(directory)
            launcher = root / "biometric-probe.sh"
            launcher.write_text((ROOT / "MacShell/biometric-probe.sh").read_text())
            (root / "biometric_probe.py").write_text("print('python')\n")
            binary = root / "biometric-probe-rust"
            binary.write_text("#!/bin/sh\nif [ \"${1-}\" = --protocol-version ]; then echo 'macshell-biometric-probe 1'; else echo rust; fi\n")
            binary.chmod(0o755)
            self.assertEqual(subprocess.check_output(["sh", str(launcher)], text=True).strip(), "rust")
            binary.write_text("#!/bin/sh\necho wrong\n")
            self.assertEqual(subprocess.check_output(["sh", str(launcher)], text=True).strip(), "python")

    def test_operation_launcher_checks_protocol_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory(prefix="fingerprint-launcher-") as directory:
            root = Path(directory)
            launcher = root / "fingerprint-operation.sh"
            launcher.write_text((ROOT / "MacShell/fingerprint-operation.sh").read_text())
            (root / "fingerprint_operation.py").write_text("import sys; print('python', *sys.argv[1:])\n")
            binary = root / "fingerprint-operation-rust"
            binary.write_text("#!/bin/sh\nif [ \"${1-}\" = --protocol-version ]; then echo 'macshell-fingerprint-operation 1'; else echo rust \"$@\"; fi\n")
            binary.chmod(0o755)
            command = ["sh", str(launcher), "verify", "/reader/0", "right-index-finger"]
            self.assertEqual(subprocess.check_output(command, text=True).strip(), "rust verify /reader/0 right-index-finger")
            binary.write_text("#!/bin/sh\necho wrong\n")
            self.assertEqual(subprocess.check_output(command, text=True).strip(), "python verify /reader/0 right-index-finger")


if __name__ == "__main__":
    unittest.main()
