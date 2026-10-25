# Приёмник AirPlay: исправление PIN в UxPlay 1.73.7

MacShell использует отдельный процесс [UxPlay](https://github.com/FDH2/UxPlay). Установщик оболочки сохраняет существующие backend-программы; обновление QML само по себе не пересобирает UxPlay.

В стабильном теге `v1.73.7` обработчик `pair-setup-pin` требует длину подтверждения, равную 64 байтам. При этом `pairing.h` выбирает SRP-SHA1, клиентское подтверждение и ответ сервера имеют длину 20 байт. Из-за этого правильный код отклоняется с RTSP 470, и iPhone снова спрашивает код. Появление кода после исправления сетевого экрана ещё не означает успешное сопряжение.

[uxplay-1.73.7-pin-proof.patch](uxplay-1.73.7-pin-proof.patch) меняет буфер подтверждения на 20 байт. Существующая проверка точной длины и ограниченное копирование сохраняются; проверка кода не отключается. Это патч к внешнему проекту, а не изменение протокола в MacShell. Он проверен на теге `v1.73.7`; применять его к другой версии без проверки нельзя.

## Воспроизведение

Установите зависимости сборки из [руководства UxPlay](https://github.com/FDH2/UxPlay#building-uxplay), включая CMake, компилятор C/C++, OpenSSL, libplist, Avahi и GStreamer. Затем из checkout MacShell:

```bash
macshell_checkout="$PWD"
git clone --branch v1.73.7 --depth 1 https://github.com/FDH2/UxPlay.git /tmp/uxplay-macshell-src
git -C /tmp/uxplay-macshell-src apply "$macshell_checkout/docs/uxplay-1.73.7-pin-proof.patch"
cmake -S /tmp/uxplay-macshell-src -B /tmp/uxplay-macshell-build -DNO_X11_DEPS=ON -DNO_MARCH_NATIVE=ON
cmake --build /tmp/uxplay-macshell-build --parallel 4
python3 scripts/check-uxplay-pin-native.py --source /tmp/uxplay-macshell-src --binary /tmp/uxplay-macshell-build/uxplay
```

Нативный тест создаёт временные ключи, случайный тестовый PIN и свободные порты, использует fakesink и подключается через loopback. Клиент SRP собирается из временной копии `srp.c/h` UxPlay с включёнными upstream-блоками клиента и сохранёнными notices. Проверяются правильный код и ответ сервера, неверный код, длины 0/19/21/64/4096, отсутствие падения и повторный правильный код после отказа. Тест не управляет текущим приёмником MacShell и не доказывает наличие изображения/звука с физического телефона. На исходной сборке 1.73.7 правильный код воспроизводимо отклоняется; сборка с патчем проходит проверку.

Перед заменой установленного бинарника остановите приёмник, сохраните исходную программу и её build metadata. Для пользовательского runtime программа находится в `~/.local/share/macshell-niri/runtime/bin/uxplay`; при заданном `XDG_DATA_HOME` используйте его вместо `~/.local/share`. Если UxPlay найден раньше в PATH, будет запущен именно он. Сохраните лицензии и исходные notices UxPlay, патч и его происхождение рядом с бинарником. `receiver.pem` удалять для этого исправления не требуется.

Сетевой экран настраивается отдельно: [диагностика подключения](CONTROL_CENTER.md#iphone-видит-приёмник-но-не-подключается). MacShell использует фиксированные 7100–7102 TCP/UDP и не меняет правила автоматически.
