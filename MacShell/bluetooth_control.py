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
APPLE_COMPANY = 0x004C
APPLE_PROXIMITY = 0x07
APPLE_SINGLE_NIBBLE = {0x09, 0x0A}
APPLE_SINGLE_MODEL = {0x0520, 0x1020, 0x0620, 0x0320}
AAP_PSM = 0x1001
AAP_HANDSHAKE = bytes.fromhex("00000400010002000000000000000000")
AAP_FEATURES = bytes.fromhex("040004004d00d700000000000000")
AAP_NOTIFY = bytes.fromhex("040004000f00ffffffff")
AAP_BATTERY = bytes.fromhex("04000400050001")


def call(bus, path, interface, method, parameters=None, timeout=3000):
    return bus.call_sync("org.bluez", path, interface, method, parameters, None,
                         Gio.DBusCallFlags.NONE, timeout, None)


def managed_objects(bus):
    return call(bus, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects").unpack()[0]


def manufacturer_bytes(device, company=APPLE_COMPANY):
    data = device.get("ManufacturerData") or {}
    payload = data.get(company)
    if payload is None:
        payload = data.get(int(company))
    if payload is None:
        return None
    if isinstance(payload, (bytes, bytearray)):
        return bytes(payload)
    if isinstance(payload, memoryview):
        return payload.tobytes()
    if isinstance(payload, (list, tuple)):
        try:
            return bytes(int(value) & 0xFF for value in payload)
        except (TypeError, ValueError):
            return None
    return None


def apple_nibble(value):
    return value * 10 if 0 <= value <= 10 else -1


def parse_apple_manufacturer(payload):
    if not payload or payload[0] != APPLE_PROXIMITY or len(payload) < 8:
        return None
    flip = ((payload[5] >> 4) & 0x02) == 0
    high, low = payload[6] >> 4, payload[6] & 0x0F
    left_raw, right_raw = (high, low) if flip else (low, high)
    charge, case_raw = payload[7] >> 4, payload[7] & 0x0F
    charge_left = bool(charge & (0b10 if flip else 0b01))
    charge_right = bool(charge & (0b01 if flip else 0b10))
    charge_case = bool(charge & 0b100)
    charge_single = bool(charge & 0b01)
    model = (payload[3] << 8) | payload[4]
    if (payload[3] & 0x0F) in APPLE_SINGLE_NIBBLE or model in APPLE_SINGLE_MODEL:
        battery = apple_nibble(low)
        return None if battery < 0 else {"left": -1, "right": -1, "case": -1, "battery": battery,
                                         "charging": charge_single}
    left, right, case = apple_nibble(left_raw), apple_nibble(right_raw), apple_nibble(case_raw)
    charging = (left >= 0 and charge_left) or (right >= 0 and charge_right) or (case >= 0 and charge_case)
    pods = [value for value in (left, right) if value >= 0]
    battery = min(pods) if pods else case
    if battery < 0:
        return None
    return {"left": left, "right": right, "case": case, "battery": battery, "charging": charging}


def apple_audio(device):
    modalias = str(device.get("Modalias") or "")
    if re.search(r"v004[Cc]", modalias):
        return True
    name = str(device.get("Alias") or device.get("Name") or "")
    return bool(re.search(r"airpods|beats|powerbeats", name, re.I))


def apply_apple(row, parsed, keep_battery=False):
    if not parsed:
        return
    if parsed["left"] >= 0:
        row["batteryLeft"] = parsed["left"]
    if parsed["right"] >= 0:
        row["batteryRight"] = parsed["right"]
    if parsed["case"] >= 0:
        row["batteryCase"] = parsed["case"]
    if parsed["charging"]:
        row["charging"] = True
    else:
        row.pop("charging", None)
    if not keep_battery and row.get("battery", -1) < 0 and parsed["battery"] >= 0:
        row["battery"] = parsed["battery"]


def apple_from_device(device):
    payload = manufacturer_bytes(device)
    return parse_apple_manufacturer(payload) if payload else None


def parse_aap_battery(frame):
    if not frame or len(frame) < 8:
        return None
    for start in range(0, len(frame) - 7):
        if frame[start:start + 4] == b"\x04\x00\x04\x00" and frame[start + 4] == 0x04:
            parsed = _parse_aap_at(frame[start:])
            if parsed:
                return parsed
    return None


def _parse_aap_at(frame):
    if not frame or len(frame) < 8 or frame[:4] != b"\x04\x00\x04\x00" or frame[4] != 0x04:
        return None
    count = frame[6]
    if count < 1 or count > 4 or len(frame) < 7 + count * 5:
        return None
    left = right = case = single = -1
    charging = False
    for index in range(count):
        rec = frame[7 + index * 5:7 + (index + 1) * 5]
        if rec[1] != 0x01 or rec[4] != 0x01:
            continue
        status = rec[3]
        if status == 0x04:
            continue
        level = rec[2]
        if not 0 <= level <= 100:
            continue
        charging = charging or status == 0x01
        if rec[0] == 0x02:
            right = level
        elif rec[0] == 0x04:
            left = level
        elif rec[0] == 0x08:
            case = level
        else:
            single = level
    pods = [value for value in (left, right) if value >= 0]
    battery = min(pods) if pods else (case if case >= 0 else single)
    if battery < 0:
        return None
    return {"left": left, "right": right, "case": case, "battery": battery, "charging": charging}


def has_parts(row):
    return row.get("batteryLeft", -1) >= 0 or row.get("batteryRight", -1) >= 0 or row.get("batteryCase", -1) >= 0


def attach_nearby_apple_battery(known, objects):
    need = [row for row in known["devices"]
            if row.get("connected") and not has_parts(row)
            and apple_audio(objects.get(row["path"], {}).get(DEVICE, {}))]
    ads = [row for row in known.get("others") or [] if has_parts(row)]
    if len(need) != 1 or not ads:
        return
    source = max(ads, key=lambda row: sum(row.get(key, -1) >= 0 for key in ("batteryLeft", "batteryRight", "batteryCase")))
    dest = need[0]
    keep = dest.get("battery", -1) >= 0
    parsed = {"left": source.get("batteryLeft", -1), "right": source.get("batteryRight", -1),
              "case": source.get("batteryCase", -1), "battery": source.get("battery", -1),
              "charging": bool(source.get("charging"))}
    apply_apple(dest, parsed, keep_battery=keep)


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
        row = {"path": path, "address": str(device.get("Address", "")),
               "name": str(device.get("Alias") or device.get("Name") or device.get("Address", "Device")),
               "icon": str(device.get("Icon", "bluetooth")),
               "connected": bool(device.get("Connected", False)),
               "blocked": bool(device.get("Blocked", False)),
               "adapterEnabled": enabled[adapter], "adapterName": next(a["name"] for a in adapters if a["path"] == adapter),
               "battery": int(battery) if battery is not None and 0 <= battery <= 100 else -1}
        apply_apple(row, apple_from_device(device), keep_battery=row["battery"] >= 0)
        if apple_audio(device):
            row["appleAudio"] = True
        devices.append(row)
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
