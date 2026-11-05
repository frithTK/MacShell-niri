# Project screenshots and demonstration

The README gallery uses the production QML components, captured in an isolated nested niri session at **1440 × 900**. The background, media, devices, resource readings and date are demonstration data. The glass is rendered by MacShell's real shader and compositor effects.

The newer Notes, Stickies, Reminders, Clock and Timer images use separate English and Russian captures. The English Notes and Reminders images use disposable data and a nested niri session; from an existing Wayland/niri session they can be reproduced with:

```bash
mkdir -p /tmp/macshell-readme-en
MACSHELL_README_CAPTURE_EN=1 MACSHELL_NOTES_CAPTURE=/tmp/macshell-readme-en python3 scripts/check-notes-native.py
MACSHELL_README_CAPTURE_EN=1 MACSHELL_REMINDERS_CAPTURE=/tmp/macshell-readme-en python3 scripts/check-reminders-native.py
bash scripts/preview-timer-widget.sh en /tmp/macshell-readme-en
MACSHELL_STICKIES_LANG=en MACSHELL_STICKIES_CAPTURE=/tmp/macshell-readme-en/stickies-en.png python3 scripts/check-stickies-native.py
MACSHELL_STICKIES_LANG=ru MACSHELL_STICKIES_CAPTURE=/tmp/macshell-readme-en/stickies-ru.png python3 scripts/check-stickies-native.py
```

The app checks capture both themes as `notes-{dark,light}.png` and `reminders-{dark,light}.png`; the English README uses the dark captures with an `-en-` suffix. Timer previews use `timer-widget-en-{dark,light}.png`. Pass `ru` to the timer preview script for Russian images. The existing Russian app captures use the same tests without `MACSHELL_README_CAPTURE_EN`.

## Liquid Glass showcase

Run deliberately from an active niri session with the repository's compatible Quickshell/Qt runtime, `niri`, `grim`, `wf-recorder` and `ffmpeg` installed:

```bash
python3 scripts/capture-showcase.py --output-dir /tmp/macshell-showcase --gif
```

The script creates a private nested compositor and identifies its host window by PID before resizing only that window. It copies the current source into a temporary profile; configuration, HOME, caches, desktop entries, D-Bus, PipeWire and PulseAudio endpoints are isolated. Network, Bluetooth, power, brightness, battery, weather, media and Activity are fixtures. No installed profile is activated or edited. Audio is not recorded. Temporary processes and files are cleaned up on exit.

The scene uses an Apple menu logo, five demonstration applications, four Liquid widgets and original vector wallpapers: [light](showcase/wallpaper.svg), [dark](showcase/wallpaper-dark.svg), [sample artwork](showcase/album.svg). These project-authored SVGs use the repository's MIT license. Application icons are read from the installed icon themes; their assets are not copied into the repository. The runner checks the icon paths explicitly.

| Presentation parameter | Value |
| --- | --- |
| Menu bar / Dock material | Liquid Glass |
| Refraction strength | 2.4 / 240% |
| Rim highlights | 0.9 |
| Tint / translucency | 0.24 |
| Shader blur | 4; widgets retain their built-in +11 offset |
| Nested compositor blur | 3 passes, offset 1.2 |
| Grain | 0.02 |
| Menu bar height | 30 px |
| Dock icons | 52 px |

This is a stronger presentation preset than the defaults. Both themes use the same glass settings, with a matching wallpaper for each. Wallpaper refraction runs in the empty desktop scenes. Windowed Settings follows the actual geometry/capture policy; these captures do not establish physical multi-monitor or live application-window capture support. [niri's backdrop configuration](https://niri-wm.github.io/niri/Overview.html#backdrop-customization) explains the transparent workspace background used with the wallpaper layer.

Every still starts with a native full-output capture. Menu close-ups are native region captures using the component's actual geometry; Settings/Clock close-ups use niri's window screenshot by owned window ID. Pixels are not retouched or composited. `showcase-*-{dark,light}.png` are full scenes, and `showcase-detail-*-{dark,light}.png` are close-ups. The console must report `MACSHELL_SHOWCASE_PASS` with no QML binding/type errors.

The silent tour opens Control Center, Spotlight search, Applications and Activity using the shell's real transitions. The GIF is scaled to **960 × 600 at 12 fps**, with a full-scene palette and looping playback. The **1440 × 900, 30 fps MP4** preserves smooth motion and colors. Encoding changes the media format, not the UI or its animation timing.

For a short recapture:

```bash
python3 scripts/capture-showcase.py --output-dir /tmp/macshell-showcase --scenes desktop cc spotlight stats --themes dark light
python3 scripts/capture-showcase.py --output-dir /tmp/macshell-showcase --scenes desktop --themes dark --gif
python3 scripts/capture-showcase.py --output-dir /tmp/macshell-clock-ru --scenes clock --themes dark light --language ru
```

The READMEs reference 24 stills, the GIF and MP4. Copy only referenced showcase files from the completed run:

```bash
python3 - <<'PY'
from pathlib import Path
import re
import shutil

source = Path('/tmp/macshell-showcase')
text = Path('README.md').read_text() + Path('README.ru.md').read_text()
names = set(re.findall(r'docs/images/(showcase-[^"\s)]+)', text))
for name in sorted(names):
    if '-clock-ru-' not in name:
        shutil.copyfile(source / name, Path('docs/images') / name)
for theme in ('dark', 'light'):
    shutil.copyfile(Path('/tmp/macshell-clock-ru') / f'showcase-detail-clock-{theme}.png',
                    Path('docs/images') / f'showcase-detail-clock-ru-{theme}.png')
PY
```

## Theme regression captures

The older `theme-*` and widget-editor screenshots remain useful in the feature guides. They come from isolated native regression checks; the small four-widget gallery uses simplified preview glass.

### Reproduce the regression captures

From the repository root, in an active niri session with the documented Qt/Quickshell runtime and Qt Test:

```bash
python3 scripts/check-theme-native.py --capture-dir /tmp/macshell-screenshots
```

This runs the real shell with temporary preferences and isolated service endpoints. It opens temporary windows, exercises light/dark themes and widget editing, and writes the captures after rendering. Settings uses a 720-pixel window for the widget-manager images so the full action row fits. The Player appearance example uses a fixed sample track and artwork color.

Copy these regression images into the feature guides without retouching or compositing:

```bash
python3 - <<'PY'
from pathlib import Path
import shutil

source = Path('/tmp/macshell-screenshots')
target = Path('docs/images')
for theme in ('dark', 'light'):
    names = {
        f'theme-widgets-{theme}.png': f'theme-widgets-{theme}.png',
        f'theme-controls-{theme}.png': f'theme-controls-{theme}.png',
        f'theme-widget-instances-{theme}.png': f'widgets-settings-{theme}.png',
        f'theme-player-appearance-{theme}.png': f'widgets-appearance-native-{theme}.png',
        f'theme-clock-appearance-{theme}.png': f'widgets-clock-seconds-{theme}.png',
    }
    for original, published in names.items():
        shutil.copyfile(source / original, target / published)
PY
```

The native check also covers draft/Apply/reset, matching appearance in desktop cards and glass mirrors, theme/font inheritance, Clock seconds modes, the Configure link and preservation of ClockApp timers/alarms while widgets are disabled. The console must report `MACSHELL_THEME_NATIVE_PASS`.

## Portable previews

Existing feature guides also use these isolated examples:

```bash
bash scripts/preview-stats.sh
bash scripts/preview-bar-layout.sh
```

They update `stats-menu-{dark,light}.png` and `bar-layout-{dark,light}.png` under `docs/images`. Graphs include separate network receive/send and disk read/write series; their values are simulated.

Other guides have their own examples:

```bash
bash scripts/preview-widgets.sh
bash scripts/preview-activity-settings.sh
bash scripts/preview-airdrop.sh
```

Portable previews use the Qt software renderer. Native Player captures show the effects, media glyphs and scrolling text that require the graphical renderer. The `widgets-appearance-native-*` pair remains available for the widget appearance guide.

## Before publishing

Inspect both themes at their original dimensions, confirm that labels and actions fit, and retain descriptive alt text in both READMEs. Publish images of the current checkout with fixture data and identify simplified previews in their captions. Demonstration graphs are not performance measurements.

The README showcase was captured on 25 October 2026 for version 1.0.0 with the strong-glass presentation preset, 24 native stills and a recorded tour. Future interface changes are tracked in [the changelog](../CHANGELOG.md).
