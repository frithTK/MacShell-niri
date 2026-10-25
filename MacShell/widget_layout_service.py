#!/usr/bin/env python3
"""One quiet writer for widget instances and their common defaults."""
import os
from pathlib import Path

from line_service import LineService
from widget_layout import Preferences, defaults


def settings_path():
    # Keep the original MacWidgets fallback; it predates XDG_CONFIG_HOME.
    home = Path(os.environ.get('MACSHELL_SETTINGS_HOME') or Path.home() / '.config')
    return home / 'macwidgets/settings.json'


class WidgetService(LineService):
    def __init__(self):
        super().__init__()
        self.preferences = Preferences(settings_path())

    def wait_timeout(self):
        return None

    def command(self, request):
        action, data = request.get('action'), request.get('data', {})
        try:
            if not isinstance(data, dict):
                raise ValueError('Expected widget action data')
            if action == 'load':
                self.preferences.origin = data.get('origin') or {}
                state = self.preferences.load()
                if state['migrationPending'] and not state['readOnly']:
                    migrated = self.preferences.commit(state['values'], state['token'])
                    state = migrated.pop('state')
                    if not migrated['success']:
                        state.update(readOnly=True, notice=migrated['error'])
                self.emit(type='state', **state)
            elif action in ('commit', 'recover'):
                result = self.preferences.commit(defaults() if action == 'recover' else data.get('values'), data.get('token'), recover=action == 'recover')
                self.emit(type='state', **result.pop('state'))
                self.emit(type='result', id=request.get('id'), **result)
            else:
                raise ValueError('Unknown widget action')
        except (OSError, ValueError) as error:
            self.emit(type='result', id=request.get('id'), success=False, error='Widget settings could not be saved. ' + str(error)[:120])


if __name__ == '__main__':
    WidgetService().run()
