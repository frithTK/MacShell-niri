#!/usr/bin/env python3
"""One quiet JSON-lines owner for the new Activity appearance settings."""
import copy
import os
from pathlib import Path

from activity_preferences import DEFAULTS, FIELDS, Preferences
from line_service import LineService


class PreferencesService(LineService):
    def __init__(self):
        super().__init__()
        home = Path(os.environ.get('MACSHELL_SETTINGS_HOME') or os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
        self.preferences = Preferences(home / 'macbar/activity-appearance.json')

    def wait_timeout(self):
        return None

    def state(self, state):
        self.emit(type='state', fields=FIELDS, **state)

    def command(self, request):
        action, data = request.get('action'), request.get('data', {})
        try:
            if action == 'load':
                self.state(self.preferences.load())
            elif action in ('commit', 'recover'):
                values = copy.deepcopy(DEFAULTS) if action == 'recover' else data.get('values')
                result = self.preferences.commit(values, data.get('token'), recover=action == 'recover')
                self.state(result.pop('state'))
                self.emit(type='result', id=request.get('id'), **result)
            else:
                raise ValueError('Unknown Activity preferences action')
        except (OSError, ValueError) as error:
            self.emit(type='result', id=request.get('id'), success=False,
                      error='Activity settings could not be saved. ' + str(error)[:120])


if __name__ == '__main__':
    PreferencesService().run()
