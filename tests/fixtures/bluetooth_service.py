import json
import sys
import time
state = {'type': 'state', 'available': True, 'enabled': True, 'connected': 0, 'adapters': [{'path': '/org/bluez/hci0', 'enabled': True}], 'devices': [{'path': '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF', 'name': 'Test headphones', 'connected': False, 'adapterEnabled': True, 'blocked': False, 'battery': 0, 'icon': 'audio-headset'}]}
print(json.dumps({'type': 'ready'}), flush=True)
attempts = 0
for line in sys.stdin:
    request = json.loads(line)
    action = request['action']
    if action == 'connect':
        attempts += 1
        time.sleep(.1)
        print(json.dumps({'type': 'result', 'id': request['id'], 'generation': request['generation'], 'error': 'Test connection failure'}), flush=True)
    elif action == 'power':
        state['enabled'] = False
        print(json.dumps({'type': 'result', 'id': request['id'], 'generation': request['generation'], 'ok': attempts == 1, 'error': '' if attempts == 1 else 'Duplicate connection'}), flush=True)
    print(json.dumps(dict(state, generation=request['generation'])), flush=True)
