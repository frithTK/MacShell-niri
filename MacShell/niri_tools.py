#!/usr/bin/env python3
"""User-initiated desktop operations, without changing unrelated niri files."""
import json
import os
from pathlib import Path
import subprocess
import sys
import re


def input_config(values):
    def flag(name, setting):
        return setting + ";" if values[name] else ""
    def clamp(name, lower, upper):
        return max(lower, min(upper, float(values[name])))
    return f'''// Generated only when input preferences change in MacShell.
input {{
    keyboard {{ repeat-rate {int(clamp("repeatRate", 1, 200))}; repeat-delay {int(clamp("repeatDelay", 100, 2000))}; }}
    mouse {{ accel-speed {clamp("mouseSens", -1, 1):.2f}; {flag("mouseNatural", "natural-scroll")} }}
    touchpad {{
        {flag("tpNatural", "natural-scroll")}
        {flag("tpTap", "tap")}
        {flag("tpDwt", "dwt")}
        scroll-factor {clamp("tpScroll", .1, 5):.2f}
    }}
}}
'''


def without_input_preferences(text):
    # Mask comments and strings so braces inside them cannot affect nesting.
    token = r'/\*.*?\*/|//[^\n]*|r(#+)".*?"\1|"(?:\\.|[^"\\])*"'
    masked = re.sub(token, lambda m: "".join("\n" if c == "\n" else " " for c in m[0]), text, flags=re.DOTALL)
    stack = []
    removals = []
    fields = {"keyboard": {"repeat-rate", "repeat-delay"}, "mouse": {"accel-speed", "natural-scroll"}, "touchpad": {"natural-scroll", "tap", "dwt", "scroll-factor"}}
    for match in re.finditer(r'[A-Za-z_][\w-]*|[{}]', masked):
        word = match[0]
        if word == "{":
            before = masked[:match.start()].rstrip()
            node = re.search(r'([\w-]+)\s*$', before)
            stack.append(node[1] if node else "")
        elif word == "}":
            if stack:
                stack.pop()
        elif len(stack) >= 2 and stack[-2] == "input" and word in fields.get(stack[-1], set()):
            end = match.end()
            while end < len(masked) and masked[end] not in ";\n}":
                end += 1
            if end < len(masked) and masked[end] == ";":
                end += 1
            removals.append((match.start(), end))
    for start, end in reversed(removals):
        text = text[:start] + text[end:]
    return text


def write_input(values):
    fragment = os.environ.get("MACSHELL_INPUT_FRAGMENT")
    if not fragment:
        raise RuntimeError("Input settings need the generated niri profile. Run install.sh --activate first.")
    path = Path(fragment)
    profile = Path(os.environ.get("MACSHELL_NIRI_PROFILE", path.parent))
    if not (profile / "config.kdl").is_file():
        raise RuntimeError("Activate the generated niri profile before changing input preferences.")
    previous = {file: file.read_bytes() for file in profile.rglob("*.kdl")}
    candidate = path.with_suffix(".candidate.kdl")
    candidate.write_text(input_config(values))
    validation = subprocess.run(["niri", "validate", "-c", str(candidate)], capture_output=True, text=True)
    if validation.returncode:
        candidate.unlink(missing_ok=True)
        raise RuntimeError(validation.stderr)
    try:
        for file in previous:
            if file != path:
                file.write_text(without_input_preferences(file.read_text()))
        os.replace(candidate, path)
        validation = subprocess.run(["niri", "validate", "-c", str(profile / "config.kdl")], capture_output=True, text=True)
        if validation.returncode:
            raise RuntimeError(validation.stderr)
    except Exception:
        for file, content in previous.items():
            file.write_bytes(content)
        candidate.unlink(missing_ok=True)
        raise


def pick_color():
    result = subprocess.run(["niri", "msg", "-j", "pick-color"], capture_output=True, text=True, check=True)
    color = json.loads(result.stdout)
    if not color:
        return
    channels = color.get("rgb") or color.get("color")
    if isinstance(channels, dict):
        channels = [channels.get(key, 0) for key in ("r", "g", "b")]
    if not channels:
        channels = [color[key] for key in ("r", "g", "b")]
    value = "#" + "".join(f"{max(0, min(255, round(component * 255))):02X}" for component in channels[:3])
    subprocess.run(["wl-copy", value], check=True)
    subprocess.run(["notify-send", "Color copied", value], check=False)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "input":
            write_input(json.loads(sys.argv[2]))
        elif sys.argv[1] == "color":
            pick_color()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        subprocess.run(["notify-send", "MacShell", str(error)], check=False)
        sys.exit(1)
