#!/usr/bin/env python3
"""Read existing wallpaper state without modifying the previous shell."""
import json
import os
from pathlib import Path
import subprocess
import tomllib


def discover():
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    cache = Path(os.environ.get("MACSHELL_WALLPAPER_CACHE_HOME", os.environ.get("XDG_CACHE_HOME", home / ".cache")))
    result = {}
    for path in (cache / "noctalia/wallpapers.json", config / "noctalia/wallpapers.json"):
        try:
            data = json.loads(path.read_text())
            for output, modes in data.get("wallpapers", {}).items():
                image = modes.get("dark") or modes.get("light") if isinstance(modes, dict) else modes
                if image and Path(image).is_file():
                    result["wallpaper.monitors." + output if output else "wallpaper.default"] = image
            image = data.get("defaultWallpaper")
            if image and Path(image).is_file():
                result.setdefault("wallpaper.default", image)
        except (OSError, ValueError, TypeError):
            continue
    for path in (config / "noctalia/settings.toml", config / "noctalia/config.toml"):
        try:
            data = tomllib.loads(path.read_text()).get("wallpaper", {})
            for key in ("last", "default"):
                image = data.get(key, {}).get("path")
                if image and Path(image).is_file():
                    result.setdefault("wallpaper." + key, image)
            for output, value in data.get("monitors", {}).items():
                image = value.get("path")
                if image and Path(image).is_file():
                    result.setdefault("wallpaper.monitors." + output, image)
        except (OSError, ValueError, TypeError):
            continue
    if not result:
        for tool in ("awww", "swww"):
            try:
                query = subprocess.run([tool, "query"], capture_output=True, text=True, timeout=2)
                for line in query.stdout.splitlines():
                    if "image: " in line:
                        image = line.split("image: ", 1)[1]
                        if Path(image).is_file():
                            result.setdefault("wallpaper.default", image)
            except (OSError, subprocess.TimeoutExpired):
                pass
    return result


if __name__ == "__main__":
    for key, image in discover().items():
        print(key + "\t" + image)
