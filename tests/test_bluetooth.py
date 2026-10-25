import contextlib
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from MacShell import bluetooth_control as bluetooth

ADAPTER_PATH = "/org/bluez/hci0"
DEVICE_PATH = ADAPTER_PATH + "/dev_AA_BB_CC_DD_EE_FF"


class BluetoothTests(unittest.TestCase):
    def objects(self):
        return {
            ADAPTER_PATH: {bluetooth.ADAPTER: {"Alias": "Laptop", "Powered": True}},
            DEVICE_PATH: {bluetooth.DEVICE: {"Alias": "Headphones : 🎧", "Address": "AA:BB:CC:DD:EE:FF",
                                            "Adapter": ADAPTER_PATH, "Paired": True, "Connected": True},
                          bluetooth.BATTERY: {"Percentage": 0}},
        }

    def test_preserves_names_and_zero_battery(self):
        state = bluetooth.snapshot(self.objects())
        self.assertEqual(state["connected"], 1)
        self.assertTrue(state["enabled"])
        self.assertEqual(state["devices"][0]["name"], "Headphones : 🎧")
        self.assertEqual(state["devices"][0]["battery"], 0)

    def test_hides_unpaired_scan_results_and_stale_adapters(self):
        objects = self.objects()
        objects["nearby"] = {bluetooth.DEVICE: {"Adapter": ADAPTER_PATH, "Name": "Stranger"}}
        objects["stale"] = {bluetooth.DEVICE: {"Adapter": "/org/bluez/hci99", "Paired": True}}
        self.assertEqual(len(bluetooth.snapshot(objects)["devices"]), 1)

    def test_keeps_bonded_and_connected_devices(self):
        for flag in ("Bonded", "Connected"):
            with self.subTest(flag=flag):
                objects = self.objects()
                objects[DEVICE_PATH][bluetooth.DEVICE] = {"Adapter": ADAPTER_PATH, flag: True}
                self.assertEqual(len(bluetooth.snapshot(objects)["devices"]), 1)

    def test_missing_battery_is_not_shown_as_zero(self):
        objects = self.objects()
        del objects[DEVICE_PATH][bluetooth.BATTERY]
        self.assertEqual(bluetooth.snapshot(objects)["devices"][0]["battery"], -1)

    def test_connected_first_then_names_and_paths(self):
        objects = self.objects()
        for path, name in (("z", "Zulu"), ("a", "Alpha")):
            objects[path] = {bluetooth.DEVICE: {"Alias": name, "Adapter": ADAPTER_PATH, "Paired": True}}
        self.assertEqual([d["path"] for d in bluetooth.snapshot(objects)["devices"]], [DEVICE_PATH, "a", "z"])

    def test_multiple_adapters_keep_device_power_state(self):
        objects = self.objects()
        second = "/org/bluez/hci1"
        objects[second] = {bluetooth.ADAPTER: {"Alias": "USB", "Powered": False}}
        objects["second-device"] = {bluetooth.DEVICE: {"Adapter": second, "Paired": True}}
        state = bluetooth.snapshot(objects)
        self.assertTrue(state["enabled"])
        self.assertFalse(state["devices"][1]["adapterEnabled"])
        self.assertEqual(state["devices"][1]["adapterName"], "USB")

    def test_no_adapter_and_powered_off_are_distinct(self):
        self.assertFalse(bluetooth.snapshot({})["available"])
        state = bluetooth.snapshot({ADAPTER_PATH: {bluetooth.ADAPTER: {"Powered": False}}})
        self.assertTrue(state["available"])
        self.assertFalse(state["enabled"])

    def test_connection_targets_correct_adapter_and_is_bounded(self):
        bus = Mock()
        target = DEVICE_PATH.replace("hci0", "hci1")
        bluetooth.act(bus, "connect", target)
        args = bus.call_sync.call_args.args
        self.assertEqual(args[1:4], (target, bluetooth.DEVICE, "Connect"))
        self.assertEqual(args[-2], 20000)
        bluetooth.act(bus, "disconnect", target)
        self.assertEqual(bus.call_sync.call_args.args[3], "Disconnect")

    def test_rejects_invalid_paths_and_actions_without_dbus_mutation(self):
        bus = Mock()
        for action, target in (("connect", "/org/bluez/hci0"), ("pair", DEVICE_PATH),
                               ("power", "yes"), ("connect", DEVICE_PATH + ";echo nope")):
            with self.subTest(action=action, target=target), self.assertRaises(ValueError):
                bluetooth.act(bus, action, target)
        bus.call_sync.assert_not_called()

    def test_device_state_changed_by_another_client_is_success(self):
        for action, detail in (("connect", "org.bluez.Error.AlreadyConnected"),
                               ("disconnect", "org.bluez.Error.NotConnected")):
            with self.subTest(action=action):
                bus = Mock(call_sync=Mock(side_effect=bluetooth.GLib.Error(detail)))
                bluetooth.act(bus, action, DEVICE_PATH)

    def test_power_only_changes_adapters_that_need_it(self):
        bus = Mock()
        objects = self.objects()
        objects["/org/bluez/hci1"] = {bluetooth.ADAPTER: {"Powered": False}}
        with patch.object(bluetooth, "managed_objects", return_value=objects):
            bluetooth.act(bus, "power", "on")
        args = bus.call_sync.call_args.args
        self.assertEqual(args[1], "/org/bluez/hci1")
        self.assertEqual(args[2:4], ("org.freedesktop.DBus.Properties", "Set"))
        self.assertEqual(args[4].unpack(), (bluetooth.ADAPTER, "Powered", True))

    def test_errors_are_actionable(self):
        for detail, expected in (("org.bluez.Error.NotReady", "off or blocked"),
                                 ("org.bluez.Error.AuthenticationFailed", "pair the device again"),
                                 ("br-connection-page-timeout", "did not respond"),
                                 ("org.freedesktop.DBus.Error.ServiceUnknown", "service is unavailable"),
                                 ("org.bluez.Error.NotAuthorized", "access was denied")):
            with self.subTest(detail=detail):
                self.assertIn(expected, bluetooth.error_message(Exception(detail)).lower())

    def test_failed_request_outputs_json_and_nonzero_exit(self):
        bus = SimpleNamespace(call_sync=Mock(side_effect=bluetooth.GLib.Error("org.bluez.Error.NotReady")))
        with patch.object(bluetooth.Gio, "bus_get_sync", return_value=bus), contextlib.redirect_stdout(io.StringIO()) as output:
            code = bluetooth.main(["connect", DEVICE_PATH])
        self.assertEqual(code, 1)
        self.assertIn("off or blocked", json.loads(output.getvalue())["error"])


if __name__ == "__main__":
    unittest.main()
