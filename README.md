# MacShell-niri

English · [Русский](README.ru.md)

A macOS-inspired desktop for **niri**, with a Dock, Spotlight and Liquid Glass.

[Get started](#get-started) · [Gallery](#a-closer-look) · [Guides](#guides)

![MacShell desktop with Liquid Glass widgets, Dock and Control Center](docs/images/showcase-cc-dark.png)

[Light theme](docs/images/showcase-cc-light.png) · Demo data and stronger glass for the showcase. [Behind the screenshots](docs/SCREENSHOTS.md).

## In motion

![Opening Control Center, Spotlight, applications and Activity in MacShell](docs/images/showcase-demo.gif)

[Watch in 30 fps](docs/images/showcase-demo.mp4)

## A closer look

**Find what you need**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-spotlight-dark.png"><img src="docs/images/showcase-detail-spotlight-dark.png" alt="Spotlight search, dark theme" width="420"></a> | <a href="docs/images/showcase-detail-spotlight-light.png"><img src="docs/images/showcase-detail-spotlight-light.png" alt="Spotlight search, light theme" width="420"></a> |

**Arrange your widgets**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-widgets-dark.png"><img src="docs/images/showcase-detail-widgets-dark.png" alt="Widget settings, dark theme" width="420"></a> | <a href="docs/images/showcase-detail-widgets-light.png"><img src="docs/images/showcase-detail-widgets-light.png" alt="Widget settings, light theme" width="420"></a> |

**A glance at your system**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-stats-dark.png"><img src="docs/images/showcase-detail-stats-dark.png" alt="Activity graphs, dark theme" width="420"></a> | <a href="docs/images/showcase-detail-stats-light.png"><img src="docs/images/showcase-detail-stats-light.png" alt="Activity graphs, light theme" width="420"></a> |

<details>
<summary>More screenshots</summary>

**Applications**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-apps-dark.png"><img src="docs/images/showcase-detail-apps-dark.png" alt="Applications, dark" width="420"></a> | <a href="docs/images/showcase-detail-apps-light.png"><img src="docs/images/showcase-detail-apps-light.png" alt="Applications, light" width="420"></a> |

**Wi-Fi**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-wifi-dark.png"><img src="docs/images/showcase-detail-wifi-dark.png" alt="Wi-Fi, dark" width="420"></a> | <a href="docs/images/showcase-detail-wifi-light.png"><img src="docs/images/showcase-detail-wifi-light.png" alt="Wi-Fi, light" width="420"></a> |

**Bluetooth**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-bt-dark.png"><img src="docs/images/showcase-detail-bt-dark.png" alt="Bluetooth, dark" width="420"></a> | <a href="docs/images/showcase-detail-bt-light.png"><img src="docs/images/showcase-detail-bt-light.png" alt="Bluetooth, light" width="420"></a> |

**Sound**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-vol-dark.png"><img src="docs/images/showcase-detail-vol-dark.png" alt="Sound, dark" width="420"></a> | <a href="docs/images/showcase-detail-vol-light.png"><img src="docs/images/showcase-detail-vol-light.png" alt="Sound, light" width="420"></a> |

**Battery**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-battery-dark.png"><img src="docs/images/showcase-detail-battery-dark.png" alt="Battery, dark" width="420"></a> | <a href="docs/images/showcase-detail-battery-light.png"><img src="docs/images/showcase-detail-battery-light.png" alt="Battery, light" width="420"></a> |

**World Clock**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-clock-dark.png"><img src="docs/images/showcase-detail-clock-dark.png" alt="World Clock, dark" width="420"></a> | <a href="docs/images/showcase-detail-clock-light.png"><img src="docs/images/showcase-detail-clock-light.png" alt="World Clock, light" width="420"></a> |

**Menu bar**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-detail-barlayout-dark.png"><img src="docs/images/showcase-detail-barlayout-dark.png" alt="Menu bar, dark" width="420"></a> | <a href="docs/images/showcase-detail-barlayout-light.png"><img src="docs/images/showcase-detail-barlayout-light.png" alt="Menu bar, light" width="420"></a> |

**Desktop**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-desktop-dark.png"><img src="docs/images/showcase-desktop-dark.png" alt="Desktop, dark" width="420"></a> | <a href="docs/images/showcase-desktop-light.png"><img src="docs/images/showcase-desktop-light.png" alt="Desktop, light" width="420"></a> |

**Control Center**

| Dark | Light |
| --- | --- |
| <a href="docs/images/showcase-cc-dark.png"><img src="docs/images/showcase-cc-dark.png" alt="Control Center, dark" width="420"></a> | <a href="docs/images/showcase-cc-light.png"><img src="docs/images/showcase-cc-light.png" alt="Control Center, light" width="420"></a> |

</details>

## Get started

Requires niri 26.04+, Qt 6.9+ and a compatible Quickshell build.

```bash
git clone https://github.com/frithTK/MacShell-niri.git
cd MacShell-niri
bash install.sh --check
```

Then follow the [installation guide](docs/INSTALL.md) to add a **Niri (MacShell)** login session. It also covers updates, backups and rollback.

## Guides

[Widgets](docs/WIDGETS.md) · [Menu bar](docs/BAR_LAYOUT.md) · [Activity](docs/ACTIVITY_SETTINGS.md) · [Control Center](docs/CONTROL_CENTER.md) · [MacLock](MacLock/README.md)

[AirPlay](docs/CONTROL_CENTER.md#повтор-экрана--airplay) and [AirDrop](docs/AIRDROP.md) need additional components; see the guides for setup and compatibility.

[Release 1.0.0](https://github.com/frithTK/MacShell-niri/releases/tag/v1.0.0) · [Performance](docs/PERFORMANCE.md) · [Roadmap](docs/CUSTOMIZATION_PROGRESS.md) · [IPC](docs/IPC.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changes](CHANGELOG.md)

---

Based on [MacShell by 0-ss / Rickky](https://github.com/0-ss/MacShell). niri port by [frithTK](https://github.com/frithTK). [MIT](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)

[![CI](https://github.com/frithTK/MacShell-niri/actions/workflows/ci.yml/badge.svg)](https://github.com/frithTK/MacShell-niri/actions/workflows/ci.yml)
