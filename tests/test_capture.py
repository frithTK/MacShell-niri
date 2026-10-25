import contextlib
import io
import json
from pathlib import Path
import tempfile
import time
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from MacShell.niri_capture import Capture, Gst, GstVideo, Image, preview_filters, preview_stream_properties


class CaptureTests(unittest.TestCase):
    def test_final_damage_frame_is_coalesced_instead_of_dropped(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = Capture(SimpleNamespace(fps=5, width=512, directory=SimpleNamespace(name=directory)), 42)
            capture.pipeline = Gst.parse_launch('appsrc name=input format=time ! appsink name=latest emit-signals=true max-buffers=1 drop=true sync=false')
            capture.converter = Gst.parse_launch('appsrc name=input format=time is-live=true ! ' + preview_filters(512))
            capture.converter.get_by_name('frames').connect('new-sample', capture.on_sample)
            received, encoded = threading.Event(), threading.Event()
            incoming = []
            def arrived(sink):
                incoming.append(True)
                received.set()
                return Gst.FlowReturn.OK
            capture.pipeline.get_by_name('latest').connect('new-sample', arrived)
            for pipeline in (capture.pipeline, capture.converter):
                pipeline.get_bus().add_signal_watch()
                pipeline.set_state(Gst.State.PLAYING)
            source = capture.pipeline.get_by_name('input')
            source.set_property('caps', Gst.Caps.from_string('video/x-raw,format=BGRA,width=16,height=8,framerate=60/1,pixel-aspect-ratio=1/1'))
            def push(index, color):
                buffer = Gst.Buffer.new_wrapped(bytes(color) * 128)
                buffer.pts = index * Gst.SECOND // 60
                buffer.duration = Gst.SECOND // 60
                source.emit('push-buffer', buffer)
            try:
                with patch('MacShell.niri_capture.emit', side_effect=lambda message: encoded.set()):
                    push(0, [10, 20, 30, 255]); self.assertTrue(received.wait(2))
                    capture.poll(); self.assertTrue(encoded.wait(2)); encoded.clear()
                    push(1, [40, 50, 60, 255]); push(2, [70, 80, 90, 255])
                    deadline = time.monotonic() + 2
                    while len(incoming) < 3 and time.monotonic() < deadline:
                        time.sleep(.005)
                    self.assertEqual(len(incoming), 3)
                    capture.poll()
                    self.assertEqual(capture.serial, 1, 'Sampling exceeded the configured rate')
                    time.sleep(.22)
                    capture.poll(); self.assertTrue(encoded.wait(2))
                self.assertEqual(capture.serial, 2)
                with Image.open(Path(directory) / '42-1.png') as image:
                    self.assertEqual(image.getpixel((0, 0)), (90, 80, 70, 255))
            finally:
                capture.close()

    def test_pipewire_stream_declares_video_before_format_negotiation(self):
        properties = preview_stream_properties()
        self.assertEqual(properties.get_string("media.type"), "Video")
        self.assertEqual(properties.get_string("media.category"), "Capture")
        self.assertEqual(properties.get_string("media.role"), "Screen")

    def test_pipeline_bounds_both_axes_and_normalizes_pipewire_pixel_aspect(self):
        for width, height in ((936, 1020), (1920, 1052), (16, 8)):
            for pixel_aspect in ("1/1", "0/1"):
                with self.subTest(size=(width, height), pixel_aspect=pixel_aspect), tempfile.TemporaryDirectory() as directory:
                    pipeline = Gst.parse_launch("appsrc name=input format=time ! " + preview_filters(512))
                    try:
                        source = pipeline.get_by_name("input")
                        source.set_property("caps", Gst.Caps.from_string(
                            f"video/x-raw,format=BGRA,width={width},height={height},framerate=60/1,pixel-aspect-ratio={pixel_aspect}"))
                        pipeline.set_state(Gst.State.PLAYING)
                        buffer = Gst.Buffer.new_wrapped(bytes([10, 20, 30, 123]) * (width * height))
                        buffer.pts = 0
                        buffer.duration = Gst.SECOND // 60
                        source.emit("push-buffer", buffer)
                        source.emit("end-of-stream")
                        sample = pipeline.get_by_name("frames").emit("try-pull-sample", 2 * Gst.SECOND)
                        self.assertIsNotNone(sample, "Preview pipeline failed to negotiate the capture format")
                        info = GstVideo.VideoInfo.new_from_caps(sample.get_caps())
                        self.assertLessEqual(max(info.width, info.height), 512)
                        self.assertLessEqual(abs(info.width * height - info.height * width), max(width, height))
                        if max(width, height) <= 512:
                            self.assertEqual((info.width, info.height), (width, height))
                        capture = Capture(SimpleNamespace(fps=5, directory=SimpleNamespace(name=directory)), 42)
                        with contextlib.redirect_stdout(io.StringIO()):
                            capture.on_sample(SimpleNamespace(emit=lambda _: sample))
                        with Image.open(Path(directory) / "42-0.png") as image:
                            self.assertEqual(image.size, (info.width, info.height))
                            self.assertEqual(image.getpixel((0, 0)), (30, 20, 10, 123))
                    finally:
                        pipeline.set_state(Gst.State.NULL)

    def test_real_gstreamer_buffer_becomes_alpha_png(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = SimpleNamespace(fps=5, directory=SimpleNamespace(name=directory))
            capture = Capture(manager, 42)
            buffer = Gst.Buffer.new_wrapped(bytes([10, 20, 30, 255]) * (16 * 8))
            caps = Gst.Caps.from_string("video/x-raw,format=BGRA,width=16,height=8,framerate=5/1")
            sample = Gst.Sample.new(buffer, caps, None, None)
            sink = SimpleNamespace(emit=lambda _: sample)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(capture.on_sample(sink), Gst.FlowReturn.OK)
            message = json.loads(output.getvalue())
            self.assertEqual((message["width"], message["height"]), (16, 8))
            with Image.open(Path(directory) / "42-0.png") as image:
                self.assertEqual(image.getpixel((0, 0)), (30, 20, 10, 255))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                capture.on_sample(sink)
            self.assertNotEqual(output.getvalue(), "")  # Sampling, rather than encoding, limits the frame rate.

    def test_inactive_window_has_no_encoding_work(self):
        capture = Capture(SimpleNamespace(fps=5), 42)
        capture.last_request = time.monotonic() - 2
        with contextlib.redirect_stdout(io.StringIO()) as output:
            capture.on_sample(SimpleNamespace(emit=lambda _: object()))
        self.assertEqual(output.getvalue(), "")

    def test_closed_window_does_not_read_buffer(self):
        capture = Capture(SimpleNamespace(fps=5), 42)
        capture.closed = True
        self.assertEqual(capture.on_sample(SimpleNamespace(emit=lambda _: object())), Gst.FlowReturn.OK)


if __name__ == "__main__":
    unittest.main()
