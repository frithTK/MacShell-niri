# Convert

Локальное преобразование изображений и PDF рядом с оригиналом, без отдельного окна.

Tangerine — проприетарная программа для macOS и в MacShell не входит. [DragShift](https://github.com/llamaboi55/DragShift) — MIT, Python; его код не вендорится и не вызывается. На X11 DragShift перехватывает Shift+drag; **на Wayland этого жеста нет**, в том числе в niri. Рабочий вход — **контекстное меню файлового менеджера**: ПКМ по файлу → **Convert** / **Преобразовать** → PNG, JPEG, PDF или поворот на 90°. Установщик кладёт пункты в Nautilus (Scripts → Convert), Nemo, Caja, Dolphin (подменю Convert) и Thunar.

Тип берётся из magic bytes, не только из расширения. Оригинал не перезаписывается; новый файл — `имя-действие.ext` рядом, при занятом имени `имя-действие-1.ext`. Пакет до 8 файлов, до 40 МиБ каждый. Для PDF пункты PNG/JPEG дают первую страницу, если в PATH есть `pdftoppm`. Автоудаления нет.

```bash
~/.local/bin/macshell-convert --op png /abs/path/photo.jpg
~/.config/quickshell/MacShell-niri/drop-tools.sh --convert --op jpeg /abs/path/photo.png
```

## Форматы

| Источник | Действия | Инструмент |
| --- | --- | --- |
| PNG, JPEG, GIF, BMP | PNG, JPEG, PDF (одна страница), поворот 90° | встроенный Rust (`image`) |
| PDF | первая страница в PNG или JPEG | `pdftoppm` (Poppler); без него пункты видны, но недоступны |
| WebP, SVG, прочее | нет конвертации в этой версии | явное «нельзя преобразовать» |

Подмена `pdftoppm` для тестов: `MACSHELL_PDFTOPPM=/abs/path`. Живой сеанс этим не пользуйтесь.

Проверка без оболочки: `cargo test --locked --offline --manifest-path native/drop-tools/Cargo.toml`.
