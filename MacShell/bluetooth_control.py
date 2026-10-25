#!/usr/bin/env python3
"""Small, bounded BlueZ requests shared by the panel and system settings."""
import json
import re
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
BATTERY = "org.bluez.Battery1"


def call(bus, path, interface, method, parameters=None, timeout=3000):
    return bus.call_sync("org.bluez", path, interface, method, parameters, None,
                         Gio.DBusCallFlags.NONE, timeout, None)


def managed_objects(bus):
    return call(bus, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects").unpack()[0]


def snapshot(objects):
    adapters = [{"path": path, "name": str(interfaces[ADAPTER].get("Alias", "Bluetooth")),
                 "enabled": bool(interfaces[ADAPTER].get("Powered", False))}
                for path, interfaces in sorted(objects.items()) if ADAPTER in interfaces]
    enabled = {adapter["path"]: adapter["enabled"] for adapter in adapters}
    devices = []
    for path, interfaces in objects.items():
        device = interfaces.get(DEVICE, {})
        # The quick picker is for devices the user has already paired or connected.
        if not (device.get("Paired") or device.get("Bonded") or device.get("Connected")):
            continue
        adapter = device.get("Adapter", "")
        if adapter not in enabled:
            continue
        battery = interfaces.get(BATTERY, {}).get("Percentage")
        devices.append({"path": path, "address": str(device.get("Address", "")),
                        "name": str(device.get("Alias") or device.get("Name") or device.get("Address", "Device")),
                        "icon": str(device.get("Icon", "bluetooth")),
                        "connected": bool(device.get("Connected", False)),
                        "blocked": bool(device.get("Blocked", False)),
                        "adapterEnabled": enabled[adapter], "adapterName": next(a["name"] for a in adapters if a["path"] == adapter),
                        "battery": int(battery) if battery is not None and 0 <= battery <= 100 else -1})
    devices.sort(key=lambda device: (not device["connected"], device["name"].casefold(), device["path"]))
    return {"available": bool(adapters), "enabled": any(enabled.values()), "adapters": adapters,
            "devices": devices, "connected": sum(device["connected"] for device in devices)}


def act(bus, action, target):
    if action == "power":
        if target not in ("on", "off"):
            raise ValueError("Invalid Bluetooth power state.")
        adapters = snapshot(managed_objects(bus))["adapters"]
        if not adapters:
            raise ValueError("No Bluetooth adapter found.")
        for adapter in adapters:
            if adapter["enabled"] != (target == "on"):
                call(bus, adapter["path"], "org.freedesktop.DBus.Properties", "Set",
                     GLib.Variant("(ssv)", (ADAPTER, "Powered", GLib.Variant("b", target == "on"))), 5000)
    elif action in ("connect", "disconnect"):
        if not re.fullmatch(r"/org/bluez/hci\d+/dev_(?:[0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2}", target):
            raise ValueError("Invalid Bluetooth device.")
        try:
            call(bus, target, DEVICE, "Connect" if action == "connect" else "Disconnect", timeout=20000)
        except GLib.Error as error:
            # Another client can reach the requested state after our last snapshot.
            reached = "org.bluez.Error.AlreadyConnected" if action == "connect" else "org.bluez.Error.NotConnected"
            if reached not in str(error):
                raise
    else:
        raise ValueError("Unknown Bluetooth action.")


def error_message(error):
    message = str(error)
    if "NotReady" in message or "Blocked" in message or "rfkill" in message.lower():
        return "Bluetooth is off or blocked by the hardware switch."
    if "NotAuthorized" in message or "AccessDenied" in message:
        return "Bluetooth access was denied."
    if "Authentication" in message:
        return "Pairing needs attention. Pair the device again using your Bluetooth manager."
    if "InProgress" in message:
        return "This device is already connecting. Try again in a moment."
    if "UnknownObject" in message or "DoesNotExist" in message:
        return "This device is no longer available."
    if any(part in message.lower() for part in ("timeout", "timed out", "page-timeout")):
        return "The device did not respond. Check that it is on and nearby."
    if any(part in message for part in ("ServiceUnknown", "NameHasNoOwner", "Could not connect")):
        return "The Bluetooth service is unavailable."
    return re.sub(r"^.*?GDBus\.Error:[\w.]+:\s*", "", message)[:240] or "Bluetooth request failed."


def main(args):
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        if args == ["status"]:
            result = snapshot(managed_objects(bus))
        elif len(args) == 2:
            act(bus, *args)
            result = {"ok": True}
        else:
            raise ValueError("Invalid Bluetooth request.")
    except (GLib.Error, ValueError) as error:
        print(json.dumps({"error": error_message(error)}), flush=True)
        return 1
    print(json.dumps(result), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
