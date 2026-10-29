import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("biometric_probe", Path(__file__).resolve().parents[1] / "MacShell/biometric_probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class Result:
    def __init__(self, value):
        self.value = value

    def unpack(self):
        return self.value


class Bus:
    def __init__(self, devices=("/reader/0",), fingers=("left-index-finger",), error=None):
        self.devices = devices
        self.fingers = fingers
        self.error = error
        self.calls = []
        self.destinations = []

    def call_sync(self, dest, path, interface, method, args, reply, flags, timeout, cancel):
        self.destinations.append(dest)
        self.calls.append((path, method, args, timeout))
        if method == "GetDevices":
            if self.error == "service":
                raise RuntimeError("bus down")
            return Result((list(self.devices),))
        if method == "GetAll":
            if self.error == "properties":
                raise RuntimeError("device gone")
            return Result(({"name": "Fixture reader"},))
        if method == "ListEnrolledFingers":
            if self.error == "empty":
                raise RuntimeError("net.reactivated.Fprint.Error.NoEnrolledPrints")
            if self.error == "denied":
                raise RuntimeError("access denied")
            return Result((list(self.fingers),))
        raise AssertionError("Unexpected operation " + method)


class BiometricProbeTests(unittest.TestCase):
    def inspect(self, bus):
        return probe.inspect(bus, lambda signature, value: (signature, value))

    def test_only_reads_current_user_and_never_claims(self):
        bus = Bus()
        with patch.object(probe.os, "getuid", return_value=123), patch.object(probe.pwd, "getpwuid") as user:
            user.return_value.pw_name = "current-user"
            result = self.inspect(bus)
        self.assertEqual(result["devices"][0]["fingers"], ["left-index-finger"])
        self.assertEqual(bus.calls[-1][2], ("(s)", ("current-user",)))
        self.assertEqual([call[1] for call in bus.calls], ["GetDevices", "GetAll", "ListEnrolledFingers"])
        self.assertTrue(all(call[3] == 3000 for call in bus.calls))

    def test_absence_permission_error_and_device_error_are_distinct(self):
        self.assertEqual(self.inspect(Bus(devices=()))["status"], "no_device")
        self.assertEqual(self.inspect(Bus(error="service"))["status"], "service_unavailable")
        self.assertEqual(self.inspect(Bus(error="properties"))["status"], "device_error")
        self.assertEqual(self.inspect(Bus(error="denied"))["devices"][0]["enrollment"], "unknown")
        empty = self.inspect(Bus(error="empty"))["devices"][0]
        self.assertEqual((empty["enrollment"], empty["fingers"]), ("ok", []))

    def test_limits_device_queries(self):
        bus = Bus(devices=["/reader/" + str(i) for i in range(100)])
        self.assertEqual(len(self.inspect(bus)["devices"]), 8)
        self.assertEqual(len(bus.calls), 17)

    def test_only_the_system_service_is_allowed(self):
        bus = Bus()
        result = probe.inspect(bus, lambda signature, value: (signature, value))
        self.assertEqual(result['status'], 'ok')
        self.assertTrue(all(destination == probe.BUS for destination in bus.destinations))
        with self.assertRaises(ValueError):
            probe.inspect(bus, lambda signature, value: (signature, value), service='arbitrary')


if __name__ == "__main__":
    unittest.main()
