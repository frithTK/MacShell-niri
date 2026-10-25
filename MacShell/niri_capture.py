#!/usr/bin/env python3
"""Shared niri window thumbnails through Mutter ScreenCast and PipeWire.

Never invokes screenshot actions: capturing must not replace the clipboard.
Streams pause after 800 ms without demand and are closed after five seconds.
"""
import json
import os
import math
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time


def emit(value):
    with output_lock:
        print(json.dumps(value, separators=(",", ":")), flush=True)


output_lock = threading.Lock()
try:
    import gi
    gi.require_version("Gst", "1.0")
    gi.require_version("GstVideo", "1.0")
    from gi.repository import Gio, GLib, Gst, GstVideo
    from PIL import Image
except (ImportError, ValueError) as error:
    emit({"error": f"Window previews need python-gobject, python-pillow, gst-python and gst-plugin-pipewire: {error}", "fatal": True})
    sys.exit(1)

BUS = "org.gnome.Mutter.ScreenCast"
SESSION = BUS + ".Session"
STREAM = BUS + ".Stream"
Gst.init(None)


def preview_filters(size):
    # niri captures use square pixels, but PipeWire can leave their aspect
    # ratio unspecified. Normalize it before videoscale fixates dimensions.
    # Bound both axes: portrait windows must not produce taller thumbnails.
    return (
        'capssetter caps="video/x-raw,pixel-aspect-ratio=1/1" ! '
        f"videoscale ! video/x-raw,width=(int)[1,{size}],height=(int)[1,{size}],pixel-aspect-ratio=1/1 ! "
        "videoconvert ! video/x-raw,format=BGRA ! appsink name=frames emit-signals=true max-buffers=1 drop=true sync=false"
    )


def preview_stream_properties():
    # Classify the stream before PipeWire negotiates its first format. Without
    # this it can become an audio capture stream and cannot link to niri video.
    return Gst.Structure.new_from_string(
        "props,application.name=(string)macshell-preview,node.name=(string)macshell-preview,"
        "media.type=(string)Video,media.category=(string)Capture,media.role=(string)Screen"
    )


class Capture:
    def __init__(self, manager, wid):
        self.manager = manager
        self.wid = wid
        self.session = None
        self.subscription = None
        self.pipeline = None
        self.converter = None
        self.poll_timer = None
        self.last_submitted = 0
        self.last_request = time.monotonic()
        self.last_frame = 0
        self.serial = 0
        self.paused = False
        self.closed = False

    def start(self):
        self.session = self.manager.call("/org/gnome/Mutter/ScreenCast", BUS, "CreateSession", GLib.Variant("(a{sv})", ({},)))[0]
        stream = self.manager.call(self.session, SESSION, "RecordWindow", GLib.Variant("(a{sv})", ({
            "window-id": GLib.Variant("t", self.wid), "cursor-mode": GLib.Variant("u", 0),
        },)))[0]
        self.subscription = self.manager.bus.signal_subscribe(BUS, STREAM, "PipeWireStreamAdded", stream, None,
                                                             Gio.DBusSignalFlags.NONE, self.on_stream)
        self.manager.call(self.session, SESSION, "Start")

    def on_stream(self, _bus, _sender, _path, _interface, _signal, parameters, *_unused):
        if self.closed:
            return
        node = parameters.unpack()[0]
        self.pipeline = Gst.parse_launch(
            f"pipewiresrc name=source path={node} client-name=macshell-preview do-timestamp=true ! video/x-raw ! queue max-size-buffers=1 leaky=downstream ! "
            "appsink name=latest max-buffers=1 drop=true sync=false"
        )
        self.pipeline.get_by_name("source").set_property("stream-properties", preview_stream_properties())
        # Damage-driven streams can deliver their final update inside a rate
        # limiting interval. A dropping videorate/encoder then loses that update
        # forever, until the next window damage. Sample the newest queued buffer
        # on a timer, and scale/encode only that buffer at the configured cadence.
        self.converter = Gst.parse_launch("appsrc name=input format=time is-live=true ! " + preview_filters(self.manager.width))
        self.converter.get_by_name("frames").connect("new-sample", self.on_sample)
        for pipeline in (self.pipeline, self.converter):
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", self.on_error)
        self.converter.set_state(Gst.State.PLAYING)
        self.pipeline.set_state(Gst.State.PLAYING)
        self.poll_timer = GLib.timeout_add(math.ceil(1000 / self.manager.fps), self.poll)

    def poll(self):
        if self.closed:
            return False
        now = time.monotonic()
        if now - self.last_request > .8 or now - self.last_submitted < 1 / self.manager.fps:
            return True
        sample = self.pipeline.get_by_name("latest").emit("try-pull-sample", 0)
        if sample:
            source = self.converter.get_by_name("input")
            source.set_property("caps", sample.get_caps())
            source.emit("push-buffer", sample.get_buffer())
            self.last_submitted = now
        return True

    def on_error(self, _bus, message):
        if self.closed:
            return
        error, _debug = message.parse_error()
        emit({"id": self.wid, "error": str(error)})
        self.manager.drop(self.wid)

    def on_sample(self, sink):
        sample = sink.emit("pull-sample")
        now = time.monotonic()
        if self.closed or not sample or now - self.last_request > .8:
            return Gst.FlowReturn.OK
        buffer = sample.get_buffer()
        info = GstVideo.VideoInfo.new_from_caps(sample.get_caps())
        success, mapped = buffer.map(Gst.MapFlags.READ)
        if success:
            try:
                image = Image.frombytes("RGBA", (info.width, info.height), mapped.data, "raw", "BGRA", info.stride[0])
                slot = self.serial % 3
                destination = Path(self.manager.directory.name) / f"{self.wid}-{slot}.png"
                temporary = destination.with_suffix(".tmp")
                image.save(temporary, format="PNG", compress_level=1)
                os.replace(temporary, destination)
                self.serial += 1
                self.last_frame = now
                emit({"id": self.wid, "url": destination.as_uri(), "width": info.width, "height": info.height})
            except (OSError, ValueError) as error:
                emit({"id": self.wid, "error": str(error)})
            finally:
                buffer.unmap(mapped)
        return Gst.FlowReturn.OK

    def request(self):
        self.last_request = time.monotonic()
        if self.pipeline and self.paused:
            self.pipeline.set_state(Gst.State.PLAYING)
            self.paused = False

    def close(self):
        self.closed = True
        if self.poll_timer is not None:
            GLib.source_remove(self.poll_timer)
            self.poll_timer = None
        for pipeline in (self.pipeline, self.converter):
            if pipeline:
                pipeline.set_state(Gst.State.NULL)
                pipeline.get_bus().remove_signal_watch()
        if self.subscription is not None:
            self.manager.bus.signal_unsubscribe(self.subscription)
        if self.session:
            try:
                self.manager.call(self.session, SESSION, "Stop")
            except GLib.Error:
                pass
        for image in Path(self.manager.directory.name).glob(f"{self.wid}-*"):
            image.unlink(missing_ok=True)


class Manager:
    def __init__(self):
        self.fps = max(1, min(10, int(os.environ.get("MACSHELL_CAPTURE_FPS", "5"))))
        self.width = max(160, min(1024, int(os.environ.get("MACSHELL_CAPTURE_WIDTH", "512"))))
        self.limit = max(1, min(12, int(os.environ.get("MACSHELL_CAPTURE_LIMIT", "6"))))
        self.directory = tempfile.TemporaryDirectory(prefix="macshell-niri-", dir=os.environ.get("XDG_RUNTIME_DIR"))
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.loop = GLib.MainLoop()
        self.streams = {}
        self.failed = {}
        self.buffer = b""

    def call(self, path, interface, method, parameters=None):
        result = self.bus.call_sync(BUS, path, interface, method, parameters, None, Gio.DBusCallFlags.NONE, 2000, None)
        return result.unpack() if result else ()

    def drop(self, wid):
        stream = self.streams.pop(wid, None)
        if stream:
            stream.close()
        self.failed[wid] = time.monotonic() + 10

    def read(self, _fd, condition):
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            self.loop.quit()
            return False
        self.buffer += chunk
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                wid = int(json.loads(line)["id"])
                if wid <= 0 or self.failed.get(wid, 0) > time.monotonic():
                    continue
                if wid in self.streams:
                    self.streams[wid].request()
                    continue
                if len(self.streams) >= self.limit:
                    idle = min(self.streams.values(), key=lambda stream: stream.last_request)
                    if time.monotonic() - idle.last_request < .8:
                        continue
                    self.streams.pop(idle.wid).close()
                stream = Capture(self, wid)
                self.streams[wid] = stream
                stream.start()
            except GLib.Error as error:
                self.drop(wid)
                emit({"id": wid, "error": str(error)})
            except (ValueError, KeyError, TypeError):
                continue
        return True

    def collect(self):
        now = time.monotonic()
        for wid, stream in list(self.streams.items()):
            age = now - stream.last_request
            if age > 5:
                self.streams.pop(wid).close()
            elif age > .8 and stream.pipeline and not stream.paused:
                stream.pipeline.set_state(Gst.State.PAUSED)
                stream.paused = True
        self.failed = {wid: deadline for wid, deadline in self.failed.items() if deadline > now}
        return True

    def run(self):
        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, self.read)
        GLib.timeout_add(500, self.collect)
        for sig in (signal.SIGTERM, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, lambda: (self.loop.quit(), False)[1])
        try:
            self.loop.run()
        finally:
            for stream in list(self.streams.values()):
                stream.close()
            self.directory.cleanup()


if __name__ == "__main__":
    try:
        Manager().run()
    except (GLib.Error, OSError, ValueError) as error:
        emit({"error": str(error), "fatal": True})
