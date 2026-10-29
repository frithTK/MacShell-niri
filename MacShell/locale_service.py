#!/usr/bin/env python3
"""Private locale writer; no systemd/DBus changes or forced logout on Save."""
from line_service import LineService
from locale_preferences import LocaleError, Preferences, installed_locales
from subprocess import SubprocessError


class LocaleService(LineService):
    def __init__(self):
        super().__init__()
        self.preferences = Preferences(locales=[])

    def wait_timeout(self):
        return None

    def command(self, request):
        try:
            action = request.get("action")
            data = request.get("data") or {}
            # Locale packages can be installed or removed while Settings is open.
            # Validate every load/save against the current registry, not startup data.
            try:
                self.preferences.locales = installed_locales()
            except (OSError, SubprocessError):
                raise LocaleError("locale_query_failed")
            if action == "load":
                state = self.preferences.load()
            elif action == "save" and isinstance(data, dict):
                state = self.preferences.save(data.get("values"), data.get("token"))
            else:
                raise LocaleError("invalid_selection")
            self.emit(type="state", **state)
            self.emit(type="result", id=request.get("id"), success=True)
        except LocaleError as error:
            self.emit(type="result", id=request.get("id"), success=False, code=error.code, detail=error.detail)
        except (OSError, ValueError) as error:
            self.emit(type="result", id=request.get("id"), success=False, code="io_error", detail="")


if __name__ == "__main__":
    LocaleService().run()
