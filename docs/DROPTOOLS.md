# Convert

Локальное преобразование изображений и PDF в духе Tangerine / DragShift, без обещания глобального жеста на Wayland.

Tangerine — проприетарная программа для macOS и в MacShell не входит. [DragShift](https://github.com/llamaboi55/DragShift) — MIT, Python; его код не вендорится и не вызывается. На X11 DragShift перехватывает Shift+drag; **на Wayland этого жеста нет**, в том числе в niri. Рабочие входы:

- Spotlight: действие **Convert** / **Преобразовать** у локального файла
- Apps / Dock: утилита **Convert**
- обычное окно с зоной перетаскивания (`text/uri-list`) — удобно из Nautilus
- IPC: `droptools open`, `droptools files PATH`, `spotlight convert PATH`

Круговое меню: стрелки / Tab, Enter, Escape. Действия зависят от magic bytes, не только от расширения. Оригинал не перезаписывается; новый файл — `имя-действие.ext` рядом, при занятом имени `имя-действие-1.ext`. Пакет до 8 файлов, до 40 МиБ каждый; частичный успех и отмена сообщаются отдельно. Автоудаления нет.

## Форматы

| Источник | Действия | Инструмент |
| --- | --- | --- |
| PNG, JPEG, GIF, BMP | PNG, JPEG, PDF (одна страница), поворот 90° | встроенный Rust (`image`) |
| PDF | первая страница в PNG или JPEG | `pdftoppm` (Poppler); без него пункты видны, но недоступны |
| WebP, SVG, прочее | нет конвертации в этой версии | явное «нельзя преобразовать» |

Подмена `pdftoppm` для тестов: `MACSHELL_PDFTOPPM=/abs/path`. Живой сеанс этим не пользуйтесь.

Проверка без оболочки: `cargo test --locked --offline --manifest-path native/drop-tools/Cargo.toml`.
