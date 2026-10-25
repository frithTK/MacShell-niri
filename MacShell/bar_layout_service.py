#!/usr/bin/env python3
"""Quiet, transactional owner for common and per-display menu bar layouts."""
import os
from pathlib import Path

from bar_layout import CATALOG, Preferences, defaults
from line_service import LineService


class LayoutService(LineService):
    def __init__(self):
        super().__init__()
        home = Path(os.environ.get('MACSHELL_SETTINGS_HOME') or os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
        self.preferences = Preferences(home / 'macbar/layout.json')

    def wait_timeout(self):
        return None

    def command(self, request):
        action, data = request.get('action'), request.get('data', {})
        try:
            if action == 'load':
                self.preferences.defaults = defaults(data.get('legacy'))
                self.emit(type='state', catalog=CATALOG, **self.preferences.load())
            elif action in ('commit', 'recover'):
                result = self.preferences.commit(defaults() if action == 'recover' else data.get('values'), data.get('token'), recover=action == 'recover')
                self.emit(type='state', catalog=CATALOG, **result.pop('state'))
                self.emit(type='result', id=request.get('id'), **result)
            else:
                raise ValueError('Unknown menu bar action')
        except (OSError, ValueError) as error:
            self.emit(type='result', id=request.get('id'), success=False, error='Menu bar settings could not be saved. ' + str(error)[:120])


if __name__ == '__main__':
    LayoutService().run()
