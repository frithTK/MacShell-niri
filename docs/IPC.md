# MacShell-niri IPC

Команды адресуются уже работающей оболочке. Установленная обёртка выбирает её runtime и каталог настроек:

```bash
~/.local/bin/macshell-niri ipc call TARGET METHOD [ARGUMENTS...]
```

Ниже указан хвост команды после `ipc call`. Имена чувствительны к регистру; логические аргументы — `true` или `false`. Отключённая в Settings функция может не открывать свой интерфейс.

## Панели и приложения

| Команда | Действие |
| --- | --- |
| `controlcenter toggle` / `controlcenter open` | Переключить Control Center на активном мониторе; сейчас обе команды имеют одинаковое поведение |
| `controlcenter close` | Закрыть Control Center |
| `controlcenter page NAME` | Открыть конкретное подменю |
| `spotlight toggle` | Открыть Spotlight |
| `spotlight clipboard` / `spotlight emoji` / `spotlight apps` | Открыть соответствующий раздел Spotlight |
| `spotlight preview PATH` | Открыть Quick Look для абсолютного локального файла |
| `spotlight convert PATH` | Открыть конвертер для абсолютного локального файла |
| `trash open` | Открыть окно корзины Dock |
| `trash state` | JSON: есть ли содержимое, число элементов, открыто ли окно |
| `appmenu state` | JSON: экспортирует ли активное окно меню, источник, appId, pid |

В Spotlight запрос от двух символов ищет разделы Settings по имени и ключам (RU/EN). Выбор открывает этот раздел, в том числе если окно настроек уже открыто. Отключённые Settings в выдачу не попадают. Тот же запрос ищет файлы по имени через localsearch, иначе `fd`, иначе `find` (не индекс всего диска; не `find "$HOME"` через `sh -c`). Префиксы `file`/`find` по-прежнему показывают только файлы. Пути уходят аргументом хелперу, не склейкой glob. Кнопка папки в Spotlight открывает домашнюю папку через `xdg-open` (`filesCmd`).

У файла и приложения Enter по-прежнему выполняет основное действие. Стрелка вправо, › и правая кнопка мыши открывают список действий; Escape и стрелка влево возвращают к результатам. Для файла доступны «Показать в папке», «Копировать путь», Quick Look (изображения, PDF и обычный текст; слишком большой или неизвестный тип показывается явным сообщением) и «Преобразовать». Ctrl+Y открывает Quick Look, не закрывая Spotlight; пробел в поле поиска остаётся вводом. Из Spotlight можно перетащить один выбранный локальный файл (`text/uri-list`). Для приложения то же меню, что у Dock: открыть, закрепить/открепить, показать расположение и сведения. Пакетные действия есть только у однозначного источника: повторный клик подтверждает имя, пакет и действие; pacman идёт через pkexec, пользовательский Flatpak — без него, `--delete-data` не передаётся. Перед применением источник проверяется снова. Pacman-обновление — полное системное (`-Syu`), не частичная установка пакета. Пути передаются аргументами, не через сборку shell-команды.

Пробел в Nautilus вызывает его собственный предпросмотр (обычно GNOME Sushi), а не окно MacShell: без расширения Nautilus этот вызов перехватить нельзя. Альтернатива — Spotlight, Ctrl+Y или `spotlight preview PATH`. В окне Quick Look Escape, пробел и Ctrl+W закрывают его; Open открывает файл в приложении по умолчанию.
| `settings open` | Открыть Settings → General |
| `settings pane ID` | Открыть раздел Settings, например `battery`, `displays`, `menubar`, `barlayout`, `activity`, `widgets`, `appearance`, `sound` или `wallpaper` |
| `clock open` | Открыть Clock |
| `clock tab NAME` | Открыть вкладку `world`, `alarms`, `stopwatch` или `timers` |
| `clock stop` / `clock snooze` | Остановить текущий сигнал или отложить его |
| `calculator open` | Открыть Calculator |
| `calculator expression TEXT` | Открыть Calculator и вычислить выражение, переданное одним аргументом |
| `notes open` | Открыть Notes |
| `stickies open` | Создать и открыть записку Stickies |
| `reminders open` | Открыть Reminders |
| `utilities open NAME` | Открыть встроенную утилиту `calculator`, `clock`, `notes`, `stickies`, `reminders` или `droptools` |
| `droptools open` | Открыть окно конвертера, в которое можно перетащить файлы |
| `droptools files PATH` | Открыть конвертер для абсолютного локального файла |
| `notifications open` / `notifications close` | Открыть или закрыть Notification Center |
| `notifications clear` | Очистить уведомления |
| `notifications dismiss ID` | Удалить уведомление по числовому ID |
| `session menu` | Переключить Control Center |
| `session lock` | Запустить установленный MacLock |
| `session save` / `session status` / `session inspect` | Запросить сохранение, сводку или полный снимок сеанса |
| `session restorePlan` / `session restore` | Запросить план или восстановление открытых окон |
| `session state` / `session result` | Состояние и последний завершённый ответ асинхронного запроса |

Значения `controlcenter page`: `cc`, `wifi`, `bt`, `focus`, `awake`, `night`, `vol`, `stats`, `battery`, `record`, `airplay`. Страница `record` подготавливает выбор записи; сама запись начинается кнопкой Start после выбора источника. Страница `airplay` открывает меню повтора экрана и поиск устройств; передача и приём включаются отдельными действиями.

Команды снимка возвращают ID запроса, `-1` если служба не готова и `-2` если занята. Дождитесь `busy: false` в `session state`, затем получите ответ через `session result`; пока новый запрос выполняется, сохраняется предыдущий ответ. Подробнее: [Session snapshot](SESSION_SNAPSHOT.md).

## Повтор экрана / AirPlay

| Команда | Действие |
| --- | --- |
| `mirroring open` | Открыть Screen Mirroring |
| `mirroring receive true` / `mirroring receive false` | Включить или выключить приём AirPlay через UxPlay |
| `mirroring stop` | Остановить исходящую передачу и собственный приёмник |
| `mirroring state` | Получить JSON: доступность backend, состояния передачи/приёма, режим Mirror/Extend, `extendAvailable`/`extendOutput`/`extendMethod` (`virtual`/`output`/`dummy`) / `virtualOutputsSupported`/`extendCapture`, обнаруженные устройства и активные потоки; PIN и пароли в ответ не входят |

Для передачи нужен Doubletake, для приёма — UxPlay. Команды управляют только экземплярами, запущенными MacShell. Детали — в [руководстве AirPlay](CONTROL_CENTER.md#повтор-экрана--airplay).

## Громкость, яркость и Night Shift

| Команда | Действие |
| --- | --- |
| `volume increase` / `volume decrease` | Изменить громкость выхода на 5 процентных пунктов в пределах 0–150% и показать индикатор |
| `volume muteOutput` | Переключить выключение звука выхода и показать индикатор |
| `volume muteInput` | Переключить выключение микрофона и показать индикатор |
| `brightness increase` / `brightness decrease` | Изменить яркость на 5 процентных пунктов и показать индикатор |
| `nightshift toggle` / `nightshift on` / `nightshift off` | Переключить, включить или выключить Night Shift |
| `nightshift temperature KELVIN` | Изменить температуру в пределах 2500–6000 K; при включённом режиме применить её |

Громкость использует PipeWire; яркость — `brightnessctl`; Night Shift — `wlsunset` и Wayland gamma-control. Индикатор показывается поверх полноэкранных окон, без захвата ввода. Ползунки оболочки не вызывают дополнительный индикатор.

Для собственных мультимедийных привязок niri используйте абсолютный путь к установленной команде, например:

```kdl
binds {
    XF86AudioRaiseVolume allow-when-locked=true { spawn "/home/USER/.local/bin/macshell-niri" "ipc" "call" "volume" "increase"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "/home/USER/.local/bin/macshell-niri" "ipc" "call" "brightness" "decrease"; }
}
```

Замените `USER` и используйте свободные клавиши. Установщик сохраняет существующие привязки и переводит известные вызовы Noctalia на IPC MacShell.

## Питание, стекло и медиа

| Команда | Действие |
| --- | --- |
| `power open` | Открыть меню батареи и питания |
| `power select PROFILE` | Выбрать поддерживаемый профиль: `power-saver`, `balanced` или `performance` |
| `gaming toggle` / `gaming on` / `gaming off` | Управлять Game Mode |
| `glass captures true` / `glass captures false` | Включить или выключить превью окон Dock |
| `glass style COMPONENT MODE` | Переключить материал без перезапуска: компонент `dock` или `bar`, режим `blur` или `liquid` |
| `glass tune SETTING VALUE` | Точная настройка: `blur` (0–80, включая глобальную силу размытия niri), `refraction` (0–2.5, только для доступной линзы) или `frosting` (0.1–0.85) |
| `glass preset NAME` | Готовый вид: `clear`, `standard`, `vibrant` или `frosted` |
| `media playPause` / `media next` / `media previous` | Управлять активным MPRIS-плеером |

Профиль питания отображается после подтверждения системным сервисом. Game Mode использует временный запрос Performance; ручной выбор профиля отменяет этот запрос. Возможность Performance зависит от оборудования и сервиса питания.

Отключение превью Dock командой `glass captures false` не отключает захват, необходимый стеклу. Во время записи и Game Mode захват для стекла приостанавливается. Доступность преломления зависит от геометрии и кадров окон; подробности — в [руководстве по стеклу](CONTROL_CENTER.md#фон-стекла-в-niri).

## Окна, обои, снимки и виджеты

| Команда | Действие |
| --- | --- |
| `switcher next` / `switcher prev` | Открыть переключатель приложений и изменить выбор |
| `calendar open` | Открыть локальный календарь |
| `switcher commit` / `switcher cancel` | Подтвердить или отменить выбор |
| `wallpapers toggle` / `wallpapers open` / `wallpapers close` | Управлять выбором обоев |
| `wallpapers set PATH` | Применить обои из файла; путь с пробелами передавайте одним аргументом |
| `wallpapers appearance MODE` | Выбрать `auto`, `light`, `dark` или `dynamic` |
| `screenshot region` | Выбрать область для снимка |
| `screenshot screen` | Сделать снимок экранов |
| `screenshot window` | Сделать снимок активного окна при доступной геометрии |
| `widgets refresh` | Обновить данные виджетов |
| `widgets edit true` / `widgets edit false` | Включить или выключить редактирование виджетов |

## Диагностика

Эти команды возвращают JSON и не меняют настройки:

| Команда | Содержимое ответа |
| --- | --- |
| `bar layout` | Геометрия блоков панели и overflow по экранам: локальные координаты в логических пикселях, ширины и компактные формы |
| `status state` | Подключение к niri, число окон, доступность/активность захвата и число готовых кадров |
| `widgets resources` | Потребители desktop/зеркал по ID, общие источники, баланс acquire/release, режим и интервал часов, polling Player, расписание Weather и PID запросов; без города и метаданных трека |
| `glass state` | Режим стекла для каждого монитора: `refraction`, `compositor` или `disabled`; стили, шейдеры, значения `blur`/`refraction` и `nativeBlur` с доступностью, применённым уровнем и ошибкой |
| `osd state` | Видимость, тип и значение индикатора; текущие громкость, яркость и mute |
| `nightshift state` | Доступность, желаемое/подтверждённое включение, выбранная/применённая температура и ошибка |
| `power state` | Подтверждённый профиль, поддерживаемые профили, временный запрос Game Mode, ошибка и состояние батареи |

Например:

```bash
~/.local/bin/macshell-niri ipc call nightshift state
~/.local/bin/macshell-niri ipc call power state
```

Громкость и яркость в `osd state` передаются долями (`0.5` означает 50%, `1.5` — 150%). Значение индикатора громкости ограничено 0–1.5, яркости и микрофона — 0–1. Температура передаётся в K, процент батареи в `power state` — в пределах 0–100. `nightshift state` подтверждает температуру после отправки новой gamma-таблицы без наблюдаемой ошибки композитора. Оценка батареи может оставаться неопределённой до расчёта UPower.

Реализация команд: [shell.qml](../MacShell/shell.qml), [MacBar.qml](../MacShell/MacBar.qml), [MacWidgets.qml](../MacShell/MacWidgets.qml). Для установленного MacLock используется отдельная обёртка `~/.local/bin/maclock-niri`; подробности — в [руководстве MacLock](../MacLock/README.md).
