#!/usr/bin/env python3
"""Small, event-driven niri IPC bridge. Standard library only."""
import json
import os
import select
import socket
import sys
import time


def request(value, socket_path=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(socket_path or os.environ["NIRI_SOCKET"])
        connection.sendall((json.dumps(value) + "\n").encode())
        response = json.loads(connection.makefile("rb").readline())
        if "Err" in response:
            raise RuntimeError(response["Err"])
        return response.get("Ok")


class State:
    def __init__(self):
        self.windows = {}
        self.workspaces = {}
        self.outputs = {}
        self.keyboard = {"names": [], "current_idx": 0}
        self.overview = False

    def apply(self, event):
        name, data = next(iter(event.items()))
        if name == "WindowsChanged":
            self.windows = {w["id"]: w for w in data["windows"]}
        elif name == "WindowOpenedOrChanged":
            window = data["window"]
            previous = self.windows.get(window["id"])
            # Streaming terminals/media apps can change a title every frame.
            # Keep those changes out of the geometry/workspace snapshot path.
            title_only = (previous is not None and previous.keys() == window.keys()
                          and all(key == "title" or previous[key] == window[key] for key in previous))
            if title_only:
                self.windows[window["id"]] = window
                return "title"
            if window.get("is_focused"):
                for existing in self.windows.values():
                    existing["is_focused"] = False
            self.windows[window["id"]] = window
        elif name == "WindowClosed":
            self.windows.pop(data["id"], None)
        elif name == "WindowFocusChanged":
            for window in self.windows.values():
                window["is_focused"] = window["id"] == data["id"]
        elif name == "WindowLayoutsChanged":
            for wid, layout in data["changes"]:
                if wid in self.windows:
                    self.windows[wid]["layout"] = layout
        elif name == "WindowUrgencyChanged" and data["id"] in self.windows:
            self.windows[data["id"]]["is_urgent"] = data["urgent"]
        elif name == "WindowFocusTimestampChanged" and data["id"] in self.windows:
            self.windows[data["id"]]["focus_timestamp"] = data["focus_timestamp"]
        elif name == "WorkspacesChanged":
            self.workspaces = {w["id"]: w for w in data["workspaces"]}
        elif name == "WorkspaceActivated":
            target = self.workspaces.get(data["id"])
            if target:
                for workspace in self.workspaces.values():
                    if workspace.get("output") == target.get("output"):
                        workspace["is_active"] = workspace["id"] == target["id"]
                    if data.get("focused"):
                        workspace["is_focused"] = workspace["id"] == target["id"]
        elif name == "WorkspaceActiveWindowChanged":
            if data["workspace_id"] in self.workspaces:
                self.workspaces[data["workspace_id"]]["active_window_id"] = data["active_window_id"]
        elif name == "WorkspaceUrgencyChanged" and data["id"] in self.workspaces:
            self.workspaces[data["id"]]["is_urgent"] = data["urgent"]
        elif name == "KeyboardLayoutsChanged":
            self.keyboard = data["keyboard_layouts"]
        elif name == "KeyboardLayoutSwitched":
            self.keyboard["current_idx"] = data["idx"]
        elif name == "OverviewOpenedOrClosed":
            self.overview = data["is_open"]

    def snapshot(self):
        monitors = []
        for index, (name, output) in enumerate(sorted(self.outputs.items())):
            logical = output.get("logical")
            if not logical:
                continue
            modes = output.get("modes", [])
            mode_index = output.get("current_mode")
            mode = modes[mode_index] if mode_index is not None and mode_index < len(modes) else {}
            active = next((w for w in self.workspaces.values()
                           if w.get("output") == name and w.get("is_active")), {})
            monitors.append({
                "make": output.get("make") or "", "model": output.get("model") or "", "serial": output.get("serial") or "",
                "id": index, "name": name, "x": logical.get("x", 0), "y": logical.get("y", 0),
                "logicalRect": {"x": logical.get("x", 0), "y": logical.get("y", 0), "width": logical["width"], "height": logical["height"]},
                "transform": logical.get("transform", "Normal"),
                "pixelWidth": mode.get("width", round(logical["width"] * logical.get("scale", 1))),
                "pixelHeight": mode.get("height", round(logical["height"] * logical.get("scale", 1))),
                "width": round(logical["width"] * logical.get("scale", 1)),
                "height": round(logical["height"] * logical.get("scale", 1)), "scale": logical.get("scale", 1),
                "modeWidth": mode.get("width", logical["width"]), "modeHeight": mode.get("height", logical["height"]),
                "refreshRate": mode.get("refresh_rate", 60000) / 1000,
                "availableModes": [f'{m["width"]}x{m["height"]}@{m["refresh_rate"] / 1000:.3f}' for m in modes],
                "activeWorkspace": {"id": active.get("id", -1), "name": active.get("name") or str(active.get("idx", ""))},
                "specialWorkspace": {"id": 0}, "focused": active.get("is_focused", False),
            })
        by_name = {m["name"]: m for m in monitors}
        windows = []
        for window in self.windows.values():
            workspace = self.workspaces.get(window.get("workspace_id"), {})
            monitor = by_name.get(workspace.get("output"), {})
            layout = window.get("layout") or {}
            position = layout.get("tile_pos_in_workspace_view")
            offset = layout.get("window_offset_in_tile") or [0, 0]
            size = layout.get("window_size") or layout.get("tile_size") or [0, 0]
            # niri 26.04 has no explicit fullscreen flag in Window. Infer only
            # an exact output-sized window; never infer from "maximized" width.
            logical = self.outputs.get(workspace.get("output"), {}).get("logical") or {}
            covers_output = position is not None and abs(position[0] + offset[0]) < 2 and abs(position[1] + offset[1]) < 2 and abs(size[0] - logical.get("width", 0)) < 2 and abs(size[1] - logical.get("height", 0)) < 2
            windows.append({
                **window, "address": str(window["id"]), "class": window.get("app_id") or "",
                "workspace": {"id": workspace.get("id", -1), "name": workspace.get("name") or str(workspace.get("idx", ""))},
                "output": workspace.get("output") or "", "monitor": monitor.get("id", -1),
                "at": [(position or [0, 0])[0] + offset[0] + monitor.get("x", 0),
                       (position or [0, 0])[1] + offset[1] + monitor.get("y", 0)],
                "size": size, "geometryKnown": position is not None,
                "workspaceActive": workspace.get("is_active", False),
                "mapped": True, "hidden": not workspace.get("is_active", False) or position is None,
                "floating": window.get("is_floating", False), "fullscreen": int(window.get("is_fullscreen", covers_output)),
                "focusHistoryID": 0 if window.get("is_focused") else 1,
            })
        return {"monitors": monitors, "windows": windows,
                "workspaces": list(self.workspaces.values()), "keyboard": self.keyboard,
                "overview": self.overview}


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def watch():
    retry = 1
    while True:
        try:
            state = State()
            state.outputs = (request("Outputs") or {}).get("Outputs", {})
            with socket.socket(socket.AF_UNIX) as connection:
                connection.connect(os.environ["NIRI_SOCKET"])
                connection.sendall(b'"EventStream"\n')
                connection.setblocking(False)
                buffer = b""
                input_buffer = b""
                inputs = [connection, sys.stdin.fileno()]
                dirty = False
                titles = {}
                last_emit = 0
                output_due = time.monotonic() + 30
                retry = 1
                while True:
                    now = time.monotonic()
                    readable, _, _ = select.select(inputs, [], [], 0.034 if dirty or titles else max(0, output_due - now))
                    if sys.stdin.fileno() in readable:
                        chunk = os.read(sys.stdin.fileno(), 65536)
                        if not chunk:
                            return
                        input_buffer += chunk
                        while b"\n" in input_buffer:
                            line, input_buffer = input_buffer.split(b"\n", 1)
                            try:
                                commands = json.loads(line)
                                for command in commands if isinstance(commands, list) else [commands]:
                                    request(command)
                            except (ValueError, RuntimeError, OSError) as error:
                                print(f"niri action failed: {error}", file=sys.stderr, flush=True)
                    if connection in readable:
                        chunk = connection.recv(262144)
                        if not chunk:
                            raise ConnectionError("niri closed the event stream")
                        buffer += chunk
                        while b"\n" in buffer:
                            line, buffer = buffer.split(b"\n", 1)
                            event = json.loads(line)
                            if "Ok" in event:
                                continue
                            if "Err" in event:
                                raise RuntimeError(event["Err"])
                            change = state.apply(event)
                            name = next(iter(event))
                            if name in {"WorkspacesChanged", "ConfigLoaded"}:
                                output_due = min(output_due, time.monotonic() + .15)
                            if change == "title":
                                window = event[name]["window"]
                                titles[str(window["id"])] = window.get("title") or ""
                            elif name not in {"ScreenshotCaptured", "CastsChanged", "CastStartedOrChanged", "CastStopped"}:
                                dirty = True
                    now = time.monotonic()
                    if now >= output_due:
                        state.outputs = (request("Outputs") or {}).get("Outputs", {})
                        output_due = now + 30
                        dirty = True
                    if dirty and now - last_emit >= .033:
                        emit({"connected": True, "state": state.snapshot()})
                        last_emit = now
                        dirty = False
                        titles = {}
                    elif titles and now - last_emit >= .033:
                        emit({"connected": True, "titles": titles})
                        last_emit = now
                        titles = {}
        except (OSError, ValueError, RuntimeError, KeyError, ConnectionError) as error:
            emit({"connected": False, "error": str(error)})
            time.sleep(retry)
            retry = min(30, retry * 2)


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "request":
            emit(request(json.loads(sys.argv[2])))
        else:
            watch()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
