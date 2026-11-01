# Third-party notices

## Original MacShell

This port is based on [0-ss/MacShell](https://github.com/0-ss/MacShell) at commit [`dbaf3f4`](https://github.com/0-ss/MacShell/commit/dbaf3f4). The original QML components, shaders, animations and bundled artwork are retained from that project. Rickky's MIT copyright notice remains intact in [LICENSE](LICENSE). Version 1.0.0 starts a new Git history; [source provenance and the archived history](docs/HISTORY.md) are documented separately.

The credits images in `MacShell/assets/credits/` are inherited from upstream. Screenshots in both project overviews and `docs/images/` show this port with demonstration data or a synthetic test window.

Clock's bundled sounds in `MacShell/sounds/` are synthesized by `scripts/generate-clock-sounds.py` from mathematical waveforms; they contain no third-party recordings and are covered by the project's MIT license.

## Runtime dependencies and services

Localized emoji, currency and city data includes Unicode CLDR 48 at revision `acd6d88ae493633240e19a87a721076a8a75c310`, under the [Unicode License v3](docs/licenses/unicode-cldr.txt). The generated subset and source hashes are in `MacShell/Locale/UnicodeData.js`.

Quickshell, Qt, niri, GStreamer, PipeWire and the other system programs used by this project retain their own licenses. They are installed separately, not downloaded or bundled by `install.sh`.

Optional AirPlay integration controls [Doubletake](https://github.com/omarroth/doubletake) through a private JSON control socket and [UxPlay](https://github.com/FDH2/UxPlay) through its command line and process events. Both are separate programs with their own licenses; their implementation and binaries are not included in this repository.

Some widgets request external data: weather from Open-Meteo, IP-based location from ipwho.is/ipapi.co, and lyrics from LRCLIB. These are external services with their own terms and availability. Requests are implemented in `MacShell/widget_fetch.py` and owned by the QML widget controller; weather/location and media metadata may be sent to the selected service.

Apple, macOS, Tahoe and related names and logos belong to their respective owners. This community project is not affiliated with Apple. The project's MIT license covers its code and does not grant rights to third-party trademarks.
