import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fingerprint_operation', Path(__file__).resolve().parents[1] / 'MacShell/fingerprint_operation.py')
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)


class Reply:
    def __init__(self, value=(), error=None):
        self.value, self.error = value, error
    def unpack(self):
        if self.error: raise RuntimeError(self.error)
        return self.value


class Bus:
    def __init__(self):
        self.queue, self.calls, self.signals = [], [], {}
        self.destinations, self.subscriptions = [], []
        self.next_id = 0
    def call(self, dest, path, interface, method, args, reply, flags, timeout, cancellable, callback, data):
        self.destinations.append(dest)
        self.calls.append((path, method, args.unpack() if args else None))
        self.queue.append((method, callback))
    def call_finish(self, result): return result
    def signal_subscribe(self, sender, interface, signal, path, arg, flags, callback, data):
        self.subscriptions.append((sender, interface, signal, arg))
        self.next_id += 1; self.signals[self.next_id] = (signal, callback); return self.next_id
    def signal_unsubscribe(self, id): self.signals.pop(id, None)
    def respond(self, expected, value=(), error=None):
        method, callback = self.queue.pop(0)
        assert method == expected, (method, expected)
        callback(self, Reply(value, error), None)
    def signal(self, signal, value):
        for name, callback in list(self.signals.values()):
            signature = '(sa{sv}as)' if signal == 'PropertiesChanged' else '(sb)' if signal.endswith('Status') else '(sss)'
            if name == signal: callback(self, None, None, None, signal, fp.GLib.Variant(signature, value), None)


class FingerprintOperationTests(unittest.TestCase):
    def setUp(self):
        self.bus = Bus(); self.messages = []; self.done = []
        self.emit = patch.object(fp, 'emit', side_effect=lambda **m: self.messages.append(m)); self.emit.start(); self.addCleanup(self.emit.stop)
        which_patch = patch.object(fp.shutil, 'which', return_value=None)
        self.which = which_patch.start(); self.addCleanup(which_patch.stop)
    def op(self, action='enroll', path='/reader/0', finger='right-index-finger'):
        return fp.Operation(self.bus, action, path, finger, lambda: self.done.append(True))
    def claim(self, op):
        op.start(); self.bus.respond('GetDevices', (['/reader/0'],)); self.bus.respond('Claim')
    def finish_enroll_setup(self, enrolled=()):
        self.bus.respond('ListEnrolledFingers', (list(enrolled),))
        self.bus.respond('GetAll', ({'num-enroll-stages': 3},))
    def result(self): return [x for x in self.messages if x['type'] == 'result'][-1]

    def test_enroll_progress_and_cleanup(self):
        op = self.op(); self.claim(op); self.finish_enroll_setup()
        self.bus.respond('EnrollStart'); self.bus.signal('EnrollStatus', ('enroll-stage-passed', False)); self.bus.signal('EnrollStatus', ('enroll-completed', True))
        self.bus.respond('EnrollStop'); self.bus.respond('Release')
        self.assertEqual(self.result(), {'type':'result', 'success':True, 'code':'enroll-completed'})
        self.assertEqual([c[1] for c in self.bus.calls], ['GetDevices','Claim','ListEnrolledFingers','GetAll','EnrollStart','EnrollStop','Release'])
        self.assertEqual(self.bus.calls[1][2], ('',)); self.assertEqual(self.bus.calls[2][2], ('',))
        self.assertTrue(any(m.get('stage') == 1 and m.get('total') == 3 for m in self.messages)); self.assertEqual(len(self.done),1)

    def test_early_terminal_signal_is_not_lost(self):
        op=self.op(); self.claim(op); self.finish_enroll_setup()
        self.bus.signal('EnrollStatus', ('enroll-completed', True)); self.bus.respond('EnrollStart')
        self.bus.respond('EnrollStop'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'enroll-completed')

    def test_cancel_during_claim_and_after_start_releases(self):
        op=self.op(); op.start(); self.bus.respond('GetDevices', (['/reader/0'],)); op.cancel(); self.bus.respond('Claim'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'cancelled'); self.assertNotIn('EnrollStart',[x[1] for x in self.bus.calls])
        self.setUp(); op=self.op(); self.claim(op); self.finish_enroll_setup(); self.bus.respond('EnrollStart'); op.cancel('timeout')
        self.bus.respond('EnrollStop'); self.bus.respond('Release'); self.assertEqual(self.result()['code'],'timeout')

    def test_duplicate_and_unknown_finger_do_not_mutate(self):
        op=self.op(); self.claim(op); self.bus.respond('ListEnrolledFingers', (['right-index-finger'],)); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'already_enrolled'); self.assertNotIn('EnrollStart',[x[1] for x in self.bus.calls])
        with self.assertRaises(ValueError): self.op(finger='any')
        with self.assertRaises(ValueError): self.op(action='delete-all')

    def test_delete_specific_finger_and_verify(self):
        op=self.op('delete'); self.claim(op); self.bus.respond('ListEnrolledFingers', (['right-index-finger'],))
        self.bus.respond('DeleteEnrolledFinger'); self.bus.respond('Release')
        self.assertEqual(self.bus.calls[-2][2], ('right-index-finger',)); self.assertEqual(self.result()['code'],'deleted')
        self.setUp(); op=self.op('verify'); self.claim(op); self.bus.respond('ListEnrolledFingers', (['right-index-finger'],)); self.bus.respond('GetAll', ({},)); self.bus.respond('VerifyStart')
        self.bus.signal('VerifyStatus', ('verify-no-match', True)); self.bus.respond('VerifyStop'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'verify-no-match'); self.assertFalse(self.result()['success'])

    def test_verify_retry_remains_pending_until_terminal_status(self):
        op = self.op('verify'); self.claim(op)
        self.bus.respond('ListEnrolledFingers', (['right-index-finger'],))
        self.bus.respond('GetAll', ({},))
        self.bus.respond('VerifyStart')
        self.bus.signal('VerifyStatus', ('verify-finger-not-centered', False))
        self.assertEqual(self.messages[-1]['code'], 'verify-finger-not-centered')
        self.assertFalse(any(message['type'] == 'result' for message in self.messages))
        self.assertEqual([call[1] for call in self.bus.calls].count('VerifyStart'), 1)
        self.bus.signal('VerifyStatus', ('verify-match', True))
        self.bus.respond('VerifyStop'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'verify-match')
        self.assertTrue(self.result()['success'])

    def test_late_match_cannot_replace_terminal_no_match(self):
        op = self.op('verify'); self.claim(op)
        self.bus.respond('ListEnrolledFingers', (['right-index-finger'],))
        self.bus.respond('GetAll', ({},))
        self.bus.respond('VerifyStart')
        self.bus.signal('VerifyStatus', ('verify-no-match', True))
        self.bus.signal('VerifyStatus', ('verify-match', True))
        self.bus.respond('VerifyStop'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'verify-no-match')
        self.assertFalse(self.result()['success'])
        self.assertEqual(sum(message['type'] == 'result' for message in self.messages), 1)

    def test_only_system_service_is_used(self):
        op = fp.Operation(self.bus, 'verify', '/reader/0', 'right-index-finger',
                          lambda: self.done.append(True))
        self.claim(op)
        self.bus.respond('ListEnrolledFingers', (['right-index-finger'],))
        self.bus.respond('GetAll', ({},)); self.bus.respond('VerifyStart')
        self.bus.signal('VerifyStatus', ('verify-no-match', True))
        self.bus.respond('VerifyStop'); self.bus.respond('Release')
        self.assertTrue(all(destination == fp.BUS for destination in self.bus.destinations))
        self.assertTrue(any(sender == fp.BUS for sender, *_ in self.bus.subscriptions))
        self.assertTrue(any(signal == 'NameOwnerChanged' and arg == fp.BUS
                            for _sender, _interface, signal, arg in self.bus.subscriptions))
        with self.assertRaises(ValueError):
            fp.Operation(self.bus, 'verify', '/reader/0', 'right-index-finger', lambda: None, 'arbitrary')

    def test_errors_release_and_no_wrong_device(self):
        op=self.op(); op.start(); self.bus.respond('GetDevices', (['/reader/other'],))
        self.assertEqual(self.result()['code'],'device_gone'); self.assertEqual(len(self.bus.calls),1)
        self.setUp(); op=self.op(); op.start(); self.bus.respond('GetDevices', (['/reader/0'],)); self.bus.respond('Claim', error='AlreadyInUse')
        self.assertEqual(self.result()['code'],'busy'); self.assertNotIn('Release',[x[1] for x in self.bus.calls])
        self.setUp(); op=self.op(); self.claim(op); self.bus.respond('ListEnrolledFingers', error='PermissionDenied'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'],'permission')

    def test_daemon_disappearance_is_terminal_and_late_reply_ignored(self):
        op=self.op(); self.claim(op); self.bus.signal('NameOwnerChanged', (fp.BUS, ':1.12', ''))
        self.assertEqual(self.result()['code'],'service_error'); self.bus.respond('ListEnrolledFingers', ([],))
        self.assertEqual(len(self.done),1); self.assertNotIn('EnrollStart',[x[1] for x in self.bus.calls])

    def test_cleanup_failure_is_reported_without_hiding_completed_enrollment(self):
        op=self.op(); self.claim(op); self.finish_enroll_setup(); self.bus.respond('EnrollStart')
        self.bus.signal('EnrollStatus', ('enroll-completed', True))
        self.bus.respond('EnrollStop', error='Internal'); self.bus.respond('Release')
        self.assertTrue(self.result()['success']); self.assertTrue(self.result()['cleanupFailed'])

    def test_storage_full_is_reported_and_never_triggers_delete(self):
        op=self.op(); self.claim(op); self.finish_enroll_setup(); self.bus.respond('EnrollStart')
        self.bus.signal('EnrollStatus', ('enroll-data-full', True))
        self.bus.respond('EnrollStop'); self.bus.respond('Release')
        self.assertEqual(self.result()['code'], 'enroll-data-full')
        self.assertFalse(any('Delete' in c[1] for c in self.bus.calls))

    def test_disconnected_signal_distinguishes_driver_error_from_removal(self):
        for devices, expected in ((['/reader/0'], 'driver_error'), ([], 'device_gone')):
            with self.subTest(expected=expected):
                self.setUp()
                op=self.op(); self.claim(op); self.finish_enroll_setup(); self.bus.respond('EnrollStart')
                self.bus.signal('EnrollStatus', ('enroll-disconnected', True))
                self.bus.respond('GetDevices', (devices,))
                self.assertEqual(self.result()['code'], expected)
                self.assertNotIn('EnrollStop', [x[1] for x in self.bus.calls])
                self.assertNotIn('Release', [x[1] for x in self.bus.calls])

    def test_authorization_can_be_cancelled_before_claim(self):
        self.which.return_value = '/usr/bin/pkcheck'
        self.bus.get_unique_name = lambda: ':1.123'
        with patch.object(fp.subprocess, 'Popen') as popen, patch.object(fp.GLib, 'timeout_add', return_value=456), patch.object(fp.GLib, 'source_remove'):
            process = popen.return_value
            op = self.op(); op.start(); self.bus.respond('GetDevices', (['/reader/0'],))
            command = popen.call_args.args[0]
            self.assertEqual(command, ['pkcheck', '--action-id', 'net.reactivated.fprint.device.enroll', '--system-bus-name', ':1.123', '--allow-user-interaction'])
            self.assertNotIn('Claim', [c[1] for c in self.bus.calls])
            self.bus.signal('NameOwnerChanged', (fp.BUS, ':1.12', ''))
            self.assertFalse(op.finished, 'fprintd may idle-exit while the user answers PolicyKit')
            op.cancel()
            process.terminate.assert_called_once()
            self.assertEqual(self.result()['code'], 'cancelled')


if __name__ == '__main__': unittest.main()
