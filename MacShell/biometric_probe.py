#!/usr/bin/env python3
"""Read fprintd's devices and this user's enrolled fingers; never claim a device."""
import json
import os
import pwd
import sys

BUS = "net.reactivated.Fprint"
MANAGER = "/net/reactivated/Fprint/Manager"
DEVICE = BUS + ".Device"


def inspect(bus, variant, timeout=3000, service=BUS):
    if service != BUS:
        raise ValueError("invalid fingerprint service")
    def call(path, interface, method, args=None):
        return bus.call_sync(service, path, interface, method, args, None, 0, timeout, None).unpack()

    try:
        paths = call(MANAGER, BUS + ".Manager", "GetDevices")[0]
    except Exception:
        return {"status": "service_unavailable", "devices": []}
    devices = []
    username = pwd.getpwuid(os.getuid()).pw_name
    for path in paths[:8]:
        try:
            properties = call(path, "org.freedesktop.DBus.Properties", "GetAll", variant("(s)", (DEVICE,)))[0]
            name = str(properties.get("name", ""))
        except Exception:
            continue
        try:
            fingers = call(path, DEVICE, "ListEnrolledFingers", variant("(s)", (username,)))[0]
            devices.append({"path": path, "name": name, "fingers": list(fingers), "enrollment": "ok", "scanType": str(properties.get("scan-type", ""))})
        except Exception as error:
            message = str(error)
            if "NoEnrolledPrints" in message:
                devices.append({"path": path, "name": name, "fingers": [], "enrollment": "ok", "scanType": str(properties.get("scan-type", ""))})
            else:
                devices.append({"path": path, "name": name, "fingers": [], "enrollment": "unknown", "scanType": str(properties.get("scan-type", ""))})
    return {"status": "ok" if devices else ("device_error" if paths else "no_device"), "devices": devices}


def main():
    try:
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        result = inspect(bus, GLib.Variant)
    except Exception:
        result = {"status": "service_unavailable", "devices": []}
    print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
