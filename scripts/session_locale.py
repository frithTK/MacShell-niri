#!/usr/bin/env python3
"""Export only validated locale assignments for a new MacShell login."""
from pathlib import Path
import sys

# Installed next to locale_preferences.py in the profile, also usable in a checkout.
if not (Path(__file__).resolve().parent / "locale_preferences.py").is_file():
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "MacShell"))
from locale_preferences import LocaleError, session_environment


def main():
    try:
        for key, value in session_environment().items():
            print(key + "=" + value)
    except (OSError, ValueError) as error:
        code = error.code if isinstance(error, LocaleError) else "io_error"
        print("MacShell locale could not be applied: " + code, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
