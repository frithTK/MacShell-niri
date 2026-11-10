#!/usr/bin/env python3
"""Tiny nested-only GTK window used by the Dock bounce check."""
import os
import sys
from pathlib import Path

os.environ.setdefault("GDK_BACKEND", "wayland")

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk

GLib.set_prgname("org.macshell.DockProbe")
GLib.set_application_name("org.macshell.DockProbe")

loop = GLib.MainLoop()
window = Gtk.Window(title="MacShell Dock Probe")
window.set_default_size(240, 140)
window.set_child(Gtk.Label(label="MacShell Dock Probe"))
window.connect("close-request", lambda *_: loop.quit() or False)
window.present()
marker = os.environ.get("MACSHELL_DOCK_PROBE_PID")
if marker:
    Path(marker).write_text(str(os.getpid()))
loop.run()
