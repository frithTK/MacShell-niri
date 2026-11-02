# MacShell-niri

[English](README.md) · Русский

Рабочий стол в духе macOS для **niri** — с Dock, Spotlight и Liquid Glass.

[Установка](#установка) · [Галерея](#поближе) · [Руководства](#руководства)

![Рабочий стол MacShell с Liquid Glass, виджетами, Dock и Control Center](docs/images/showcase-cc-dark.png)

[Светлая тема](docs/images/showcase-cc-light.png) · Для съёмки — демонстрационные данные и усиленное стекло. [За кадром](docs/SCREENSHOTS.md).

## В движении

![Открытие Control Center, Spotlight, приложений и Activity в MacShell](docs/images/showcase-demo.gif)

[Посмотреть в 30 fps](docs/images/showcase-demo.mp4)

## Поближе

**Быстро найти нужное**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-spotlight-dark.png"><img src="docs/images/showcase-detail-spotlight-dark.png" alt="Поиск Spotlight, тёмная тема" width="420"></a> | <a href="docs/images/showcase-detail-spotlight-light.png"><img src="docs/images/showcase-detail-spotlight-light.png" alt="Поиск Spotlight, светлая тема" width="420"></a> |

**Виджеты на свой вкус**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-widgets-dark.png"><img src="docs/images/showcase-detail-widgets-dark.png" alt="Настройки виджетов, тёмная тема" width="420"></a> | <a href="docs/images/showcase-detail-widgets-light.png"><img src="docs/images/showcase-detail-widgets-light.png" alt="Настройки виджетов, светлая тема" width="420"></a> |

**Нагрузка с первого взгляда**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-stats-dark.png"><img src="docs/images/showcase-detail-stats-dark.png" alt="Графики Activity, тёмная тема" width="420"></a> | <a href="docs/images/showcase-detail-stats-light.png"><img src="docs/images/showcase-detail-stats-light.png" alt="Графики Activity, светлая тема" width="420"></a> |

<details>
<summary>Ещё скриншоты</summary>

**Приложения**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-apps-dark.png"><img src="docs/images/showcase-detail-apps-dark.png" alt="Приложения, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-apps-light.png"><img src="docs/images/showcase-detail-apps-light.png" alt="Приложения, светлая" width="420"></a> |

**Wi-Fi**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-wifi-dark.png"><img src="docs/images/showcase-detail-wifi-dark.png" alt="Wi-Fi, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-wifi-light.png"><img src="docs/images/showcase-detail-wifi-light.png" alt="Wi-Fi, светлая" width="420"></a> |

**Bluetooth**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-bt-dark.png"><img src="docs/images/showcase-detail-bt-dark.png" alt="Bluetooth, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-bt-light.png"><img src="docs/images/showcase-detail-bt-light.png" alt="Bluetooth, светлая" width="420"></a> |

**Звук**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-vol-dark.png"><img src="docs/images/showcase-detail-vol-dark.png" alt="Звук, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-vol-light.png"><img src="docs/images/showcase-detail-vol-light.png" alt="Звук, светлая" width="420"></a> |

**Батарея**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-battery-dark.png"><img src="docs/images/showcase-detail-battery-dark.png" alt="Батарея, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-battery-light.png"><img src="docs/images/showcase-detail-battery-light.png" alt="Батарея, светлая" width="420"></a> |

**Мировое время**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-clock-dark.png"><img src="docs/images/showcase-detail-clock-dark.png" alt="Мировое время, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-clock-light.png"><img src="docs/images/showcase-detail-clock-light.png" alt="Мировое время, светлая" width="420"></a> |

**Меню-бар**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-detail-barlayout-dark.png"><img src="docs/images/showcase-detail-barlayout-dark.png" alt="Меню-бар, тёмная" width="420"></a> | <a href="docs/images/showcase-detail-barlayout-light.png"><img src="docs/images/showcase-detail-barlayout-light.png" alt="Меню-бар, светлая" width="420"></a> |

**Рабочий стол**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-desktop-dark.png"><img src="docs/images/showcase-desktop-dark.png" alt="Рабочий стол, тёмная" width="420"></a> | <a href="docs/images/showcase-desktop-light.png"><img src="docs/images/showcase-desktop-light.png" alt="Рабочий стол, светлая" width="420"></a> |

**Control Center**

| Тёмная | Светлая |
| --- | --- |
| <a href="docs/images/showcase-cc-dark.png"><img src="docs/images/showcase-cc-dark.png" alt="Control Center, тёмная" width="420"></a> | <a href="docs/images/showcase-cc-light.png"><img src="docs/images/showcase-cc-light.png" alt="Control Center, светлая" width="420"></a> |

</details>

## Установка

Нужны niri 26.04+, Qt 6.9+ и совместимая сборка Quickshell.

```bash
git clone https://github.com/frithTK/MacShell-niri.git
cd MacShell-niri
bash install.sh --check
```

Дальше — [установка отдельного сеанса **Niri (MacShell)**](docs/INSTALL.ru.md). Там же описаны обновление, резервные копии и откат.

## Руководства

**Язык и регион** в настройках переключает русский/английский интерфейс оболочки и MacLock сразу. Язык приложений применяется после выхода и нового входа; региональные форматы выбираются отдельно. [Руководство](docs/LOCALIZATION.md).

[Виджеты](docs/WIDGETS.md) · [Утилиты](docs/UTILITIES.md) · [Меню-бар](docs/BAR_LAYOUT.md) · [Activity](docs/ACTIVITY_SETTINGS.md) · [Control Center](docs/CONTROL_CENTER.md) · [MacLock](MacLock/README.md)

Для [AirPlay](docs/CONTROL_CENTER.md#повтор-экрана--airplay) и [AirDrop](docs/AIRDROP.md) нужны дополнительные компоненты. Настройка и совместимость — в руководствах.

[Релизы](https://github.com/frithTK/MacShell-niri/releases) · [IPC](docs/IPC.md) · [Разработка](CONTRIBUTING.md) · [Безопасность](SECURITY.md) · [Изменения](CHANGELOG.md)

---

На основе [MacShell от 0-ss / Rickky](https://github.com/0-ss/MacShell). Порт на niri — [frithTK](https://github.com/frithTK). [MIT](LICENSE) · [Сторонние компоненты](THIRD_PARTY_NOTICES.md)

[![CI](https://github.com/frithTK/MacShell-niri/actions/workflows/ci.yml/badge.svg)](https://github.com/frithTK/MacShell-niri/actions/workflows/ci.yml)
