import os
import sys
import tempfile
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))
import network_control as net
import bluetooth_service as bt
import recording_control as rec
from gi.repository import GLib


class Invocation:
    def __init__(self):
        self.value = None
        self.error = None
    def return_value(self, value): self.value = value.unpack() if value else ()
    def return_dbus_error(self, name, text): self.error = name


class NetworkTests(unittest.TestCase):
    def service(self):
        s = net.NetworkService.__new__(net.NetworkService)
        s.pending, s.secret_request, s.owner = None, None, 'nm-owner'
        s.agent_ready = True
        s.snapshot_due = float('inf')
        s.networks, s.profiles, s.messages, s.calls = {}, {}, [], []
        s.emit = lambda **v: s.messages.append(v)
        s.async_call = lambda *args: s.calls.append(args)
        s.snapshot = lambda: None
        return s

    def profile(self, uuid, timestamp=0, kind='wpa-psk', interface='wlan0', ssid=b'net'):
        return {'connection': {'uuid': uuid, 'timestamp': timestamp, 'interface-name': interface}, '802-11-wireless': {'ssid': ssid}, '802-11-wireless-security': {'key-mgmt': kind}}

    def test_profiles_match_bytes_security_interface_and_choose_deterministically(self):
        profiles = {'/one': self.profile('a', 1), '/two': self.profile('b', 10), '/wrong': self.profile('c', 100, interface='other')}
        self.assertEqual(net.choose_profile(profiles, b'net', 'wpa-psk', 'wlan0', '/one'), '/one')
        self.assertEqual(net.choose_profile(profiles, b'net', 'wpa-psk', 'wlan0', ''), '/two')
        self.assertEqual(net.choose_profile(profiles, b'net\xff', 'wpa-psk', 'wlan0', ''), '')
        self.assertEqual(net.choose_profile(profiles, b'net', 'sae', 'wlan0', ''), '')

    def test_security_covers_sae_open_owe_enterprise(self):
        for flags, expected in [(0, 'open'), (0x100, 'wpa-psk'), (0x400, 'sae'), (0x200, 'enterprise'), (0x2000, 'enterprise'), (0x800, 'owe'), (0x1000, 'owe')]:
            self.assertEqual(net.security({'RsnFlags': flags}), expected)
        self.assertEqual(net.security({'Flags': 1}), 'unsupported')

    def test_personal_profile_keeps_raw_ssid_and_restricts_to_current_user(self):
        profile = net.make_profile({'ssid': 'display', 'rawSsid': [255, 0, 58], 'security': 'wpa-psk', 'interface': 'wlan0'}, 'test pass')
        self.assertEqual(profile['802-11-wireless']['ssid'].unpack(), [255, 0, 58])
        self.assertTrue(profile['connection']['permissions'].unpack()[0].startswith('user:'))
        self.assertEqual(profile['802-11-wireless-security']['psk-flags'].unpack(), 0)
        with self.assertRaises(ValueError): net.make_profile({'security': 'enterprise'}, '')
        with self.assertRaises(ValueError): net.make_profile({'security': 'wpa-psk'}, 'short')

    def test_activation_method_reply_is_not_connected(self):
        s = self.service()
        s.networks['/ap'] = {'id': '/ap', 'supported': True, 'saved': True, 'profile': '/profile', 'device': '/dev', 'ap': '/ap', 'uuid': 'uuid'}
        s.command({'action': 'join', 'data': {'network': '/ap'}, 'id': 5})
        self.assertIsNotNone(s.pending)
        s.calls[0][4](('/active',), None)
        self.assertEqual(s.pending['active'], '/active')
        self.assertFalse(s.messages)
        s.props = lambda *args: {'State': 2}
        s.tick()
        self.assertIsNone(s.pending)
        self.assertEqual(s.messages[-1]['state'], 'connected')

    def test_cancel_waits_for_own_active_connection_and_does_not_tear_down_success(self):
        s = self.service()
        s.pending = {'id': 5, 'active': None}
        s.cancel(999)
        self.assertNotIn('cancel', s.pending)
        s.cancel(5)
        self.assertTrue(s.pending['cancel'])
        s.pending['active'] = '/own'
        s.props = lambda *args: {'State': 2}
        s.cancel(5)
        self.assertFalse(s.calls)
        s.pending = {'id': 6, 'active': '/own'}
        s.props = lambda *args: {'State': 1}
        s.cancel(6)
        self.assertEqual(s.calls[0][2], 'DeactivateConnection')
        self.assertEqual(s.calls[0][3].unpack(), ('/own',))

    def test_secret_agent_rejects_other_connections_and_senders(self):
        s = self.service()
        s.pending = {'id': 1, 'uuid': 'selected', 'network': {}}
        for sender, uuid in [('unknown', 'selected'), ('nm-owner', 'external')]:
            invocation = Invocation()
            params = GLib.Variant('(a{sa{sv}}osasu)', ({'connection': {'uuid': GLib.Variant('s', uuid)}}, '/profile', '802-11-wireless-security', [], 1))
            s.agent(None, sender, '', '', 'GetSecrets', params, invocation)
            self.assertIsNotNone(invocation.error)
        self.assertIsNone(s.secret_request)


    def test_idle_tick_does_not_requery_networks_but_pending_activation_still_completes(self):
        s = self.service()
        s.snapshot = Mock()
        s.tick()
        s.snapshot.assert_not_called()
        s.pending = {'id': 8, 'active': '/own'}
        s.props = lambda *args: {'State': 2}
        s.tick()
        self.assertEqual(s.messages[-1]['state'], 'connected')
        s.snapshot.assert_not_called()
        s.snapshot_due = 0
        s.tick()
        s.snapshot.assert_called_once()
        self.assertTrue(s.profiles_dirty)

    def test_signal_bursts_are_coalesced_and_irrelevant_statistics_are_ignored(self):
        s = self.service()
        s.snapshot_timer, s.profiles_dirty = 0, False
        stats = GLib.Variant('(sa{sv}as)', (net.NM + '.Device.Statistics', {'RxBytes': GLib.Variant('t', 42)}, []))
        strength = GLib.Variant('(sa{sv}as)', (net.AP, {'Strength': GLib.Variant('y', 80)}, []))
        with patch.object(net.GLib, 'timeout_add', return_value=123) as schedule:
            s.changed(None, s.owner, net.ROOT + '/Devices/1', net.PROPS, 'PropertiesChanged', stats)
            s.changed(None, 'other-owner', net.ROOT + '/AccessPoint/1', net.PROPS, 'PropertiesChanged', strength)
            schedule.assert_not_called()
            for _ in range(5):
                s.changed(None, s.owner, net.ROOT + '/AccessPoint/1', net.PROPS, 'PropertiesChanged', strength)
            schedule.assert_called_once()
            self.assertFalse(s.profiles_dirty)
            s.changed(None, s.owner, net.ROOT + '/Settings/1', net.CON, 'Updated', GLib.Variant('()', ()))
            self.assertTrue(s.profiles_dirty)
            self.assertEqual(s.snapshot_timer, 123)

    def test_snapshots_cache_profiles_deduplicate_state_and_honor_explicit_refresh(self):
        s = self.service()
        del s.snapshot
        s.profiles_dirty, s.last_state = True, None
        s.sync = Mock(side_effect=lambda path, iface, method: (['/profile'],) if method == 'ListConnections' else (self.profile('saved'),))
        values = {(net.ROOT, net.NM): {'Devices': ['/dev'], 'WirelessEnabled': True},
                  ('/dev', net.DEV): {'DeviceType': 2, 'Interface': 'wlan0'},
                  ('/dev', net.WIFI): {'AccessPoints': ['/ap']},
                  ('/ap', net.AP): {'Ssid': list(b'net'), 'RsnFlags': 0x100, 'Strength': 70}}
        s.props = lambda path, iface: values[(path, iface)]
        s.snapshot()
        s.snapshot()
        self.assertEqual(s.sync.call_count, 2)
        self.assertEqual(len(s.messages), 1)
        self.assertTrue(s.messages[0]['networks'][0]['saved'])
        values[('/ap', net.AP)]['Strength'] = 75
        s.snapshot()
        self.assertEqual(s.sync.call_count, 2)
        self.assertEqual(s.messages[-1]['networks'][0]['signal'], 75)
        s.command({'action': 'refresh', 'data': {}, 'id': 9})
        self.assertEqual(s.sync.call_count, 4)
        self.assertEqual(len(s.messages), 3)


class BluetoothAgentTests(unittest.TestCase):
    def service(self):
        s = bt.BluetoothService.__new__(bt.BluetoothService)
        s.pending = {'id': 1, 'path': '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF', 'name': 'Keyboard', 'action': 'pair'}
        s.prompt, s.prompt_sequence, s.owner, s.messages = None, 0, 'bluez', []
        s.emit = lambda **v: s.messages.append(v)
        return s

    def ask(self, s, method, signature, args, sender='bluez'):
        invocation = Invocation()
        s.agent(None, sender, '', '', method, GLib.Variant(signature, args), invocation)
        return invocation

    def test_confirmation_needs_user_and_preserves_leading_zeros(self):
        s = self.service()
        invocation = self.ask(s, 'RequestConfirmation', '(ou)', (s.pending['path'], 42))
        self.assertIsNone(invocation.value)
        self.assertEqual(s.messages[-1]['prompt']['code'], '000042')
        s.respond({'prompt': s.prompt['id'] + 1, 'accept': True})
        self.assertIsNone(invocation.value)
        s.respond({'prompt': s.prompt['id'], 'accept': True})
        self.assertEqual(invocation.value, ())
        self.assertIsNone(s.prompt)

    def test_pin_and_passkey_validation(self):
        for method, text, expected in [('RequestPinCode', '001234', ('001234',)), ('RequestPasskey', '000042', (42,))]:
            s = self.service()
            invocation = self.ask(s, method, '(o)', (s.pending['path'],))
            s.respond({'prompt': s.prompt['id'], 'accept': True, 'value': text})
            self.assertEqual(invocation.value, expected)
        s = self.service()
        self.ask(s, 'RequestPasskey', '(o)', (s.pending['path'],))
        with self.assertRaises(ValueError): s.respond({'prompt': s.prompt['id'], 'accept': True, 'value': 'abc'})

    def test_unsolicited_authorization_and_wrong_sender_are_rejected(self):
        s = self.service()
        for sender, path in [('other', s.pending['path']), ('bluez', '/org/bluez/hci0/dev_FF_FF_FF_FF_FF_FF')]:
            invocation = self.ask(s, 'AuthorizeService', '(os)', (path, 'service'), sender)
            self.assertIsNotNone(invocation.error)
        self.assertIsNone(s.prompt)

    def test_display_cancel_and_release_complete_invocations(self):
        s = self.service()
        invocation = self.ask(s, 'DisplayPasskey', '(ouq)', (s.pending['path'], 42, 3))
        self.assertEqual(invocation.value, ())
        self.assertEqual(s.messages[-1]['prompt']['entered'], 3)
        waiting = self.ask(s, 'RequestAuthorization', '(o)', (s.pending['path'],))
        release = self.ask(s, 'Release', '()', ())
        self.assertIsNotNone(waiting.error)
        self.assertEqual(release.value, ())
        self.assertFalse(s.registered)

    def test_discovery_does_not_modify_original_objects(self):
        path = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF'
        objects = {'/org/bluez/hci0': {bt.ADAPTER: {'Powered': True}}, path: {bt.DEVICE: {'Adapter': '/org/bluez/hci0', 'Alias': 'New keyboard'}}}
        result = bt.discovered(objects)
        self.assertEqual(len(result['others']), 1)
        self.assertEqual(result['devices'], [])
        self.assertNotIn('Paired', objects[path][bt.DEVICE])


class RecordingTests(unittest.TestCase):
    def test_logical_selection_with_scale_rotation_negative_origin(self):
        output = {'logical': {'x': -1280, 'y': 0, 'width': 1280, 'height': 720, 'scale': 1.5, 'transform': '90'}}
        self.assertEqual(rec.geometry('-1200,10 321x201', output), '-1200,10 321x201')
        for invalid in ('bad', '-1200,10 1400x700', '-1281,0 100x100', '-100,0 1x1', '0,0 0x0', '0,0 100x100\n'):
            with self.assertRaises(ValueError): rec.geometry(invalid, output)

    def test_audio_choices_preserve_stable_names_and_roles(self):
        objects = [{'id': 1, 'info': {'props': {'node.name': 'mic', 'media.class': 'Audio/Source'}}}, {'id': 2, 'info': {'props': {'node.name': 'speakers', 'media.class': 'Audio/Sink'}}}, {'id': 3, 'info': {'props': {'node.name': 'macshell_record_foo', 'media.class': 'Audio/Source'}}}]
        choices = rec.audio_nodes(objects)
        self.assertEqual([v['name'] for v in choices['microphones']], ['mic'])
        self.assertEqual([v['name'] for v in choices['sinks']], ['speakers'])

    def test_file_validation_requires_video_duration_and_requested_audio(self):
        def result(data): return type('Result', (), {'stdout': __import__('json').dumps(data)})()
        valid = {'format': {'duration': '1.2'}, 'streams': [{'codec_type': 'video'}]}
        with patch.object(rec.subprocess, 'run', return_value=result(valid)):
            self.assertTrue(rec.valid_file('example.mkv', False))
            self.assertFalse(rec.valid_file('example.mkv', True))
        with patch.object(rec.subprocess, 'run', return_value=result({'format': {'duration': '0'}, 'streams': [{'codec_type': 'video'}]})):
            self.assertFalse(rec.valid_file('example.mkv', False))

    def test_disappeared_audio_is_rejected_instead_of_defaulting(self):
        recorder = rec.Recorder.__new__(rec.Recorder)
        recorder.current_output = lambda: {}
        recorder.config = {'audio': 'mic', 'microphone': 'missing'}
        with patch.object(rec, 'pipewire', return_value=[]):
            with self.assertRaisesRegex(ValueError, 'microphone disappeared'): recorder.validate()

    def test_audio_links_belong_to_this_recorder_and_selected_device(self):
        objects = [
            {'id': 1, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'mic'}}},
            {'id': 2, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'other'}}},
            {'id': 3, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'wf-recorder', 'client.id': 10}}},
            {'id': 10, 'type': 'PipeWire:Interface:Client', 'info': {'props': {'application.process.id': '1234'}}},
            {'id': 20, 'type': 'PipeWire:Interface:Link', 'info': {'output-node-id': 1, 'input-node-id': 3, 'state': 'active'}}]
        self.assertEqual(rec.audio_link_state(objects, 1234, 'mic'), 'ready')
        self.assertEqual(rec.audio_link_state(objects, 9999, 'mic'), 'waiting')
        self.assertEqual(rec.audio_link_state(objects, 1234, 'other'), 'wrong')
        objects[-1]['info']['state'] = 'paused'
        self.assertEqual(rec.audio_link_state(objects, 1234, 'mic'), 'waiting')

    def test_pulse_recorder_node_keeps_pid_and_source_ownership_checks(self):
        objects = [
            {'id': 1, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'speakers'}}},
            {'id': 2, 'type': 'PipeWire:Interface:Node', 'info': {'props': {'node.name': 'wf-recorder3', 'application.process.id': 1234}}},
            {'id': 3, 'type': 'PipeWire:Interface:Link', 'info': {'output-node-id': 1, 'input-node-id': 2, 'state': 'active'}}]
        self.assertEqual(rec.audio_link_state(objects, 1234, 'speakers'), 'ready')
        self.assertEqual(rec.audio_link_state(objects, 9999, 'speakers'), 'waiting')
        self.assertEqual(rec.audio_link_state(objects, 1234, 'microphone'), 'wrong')
        objects[-1]['info']['state'] = 'paused'
        self.assertEqual(rec.audio_link_state(objects, 1234, 'speakers'), 'waiting')

    def test_audio_backend_uses_compiled_support_instead_of_help_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'wf-recorder'
            with patch.object(rec.shutil, 'which', return_value=str(path)):
                for data, expected in [(b'\x7fELF libpipewire-0.3.so.0 libpulse-simple.so.0', 'pipewire'),
                                       (b'\x7fELF libpulse-simple.so.0', 'pulse')]:
                    path.write_bytes(data)
                    self.assertEqual(rec.recorder_audio_backend(), expected)
                for unknown in (b'\x7fELF video only', b'#!/bin/sh\n# pipewire support unknown'):
                    path.write_bytes(unknown)
                    with self.assertRaisesRegex(ValueError, 'audio backend'):
                        rec.recorder_audio_backend()

    def test_pulse_source_matches_the_selected_node_and_monitor_role(self):
        sources = [
            {'name': 'speaker.monitor', 'monitor_source': 'speaker', 'properties': {'node.name': 'speaker'}},
            {'name': 'mic', 'monitor_source': '', 'properties': {'node.name': 'mic'}}]
        result = type('Result', (), {'stdout': __import__('json').dumps(sources)})()
        with patch.object(rec.shutil, 'which', return_value='/usr/bin/pactl'), patch.object(rec.subprocess, 'run', return_value=result):
            self.assertEqual(rec.pulse_source('speaker', True), 'speaker.monitor')
            self.assertEqual(rec.pulse_source('mic', False), 'mic')
            for target, monitor in [('missing', False), ('speaker', False), ('mic', True)]:
                with self.assertRaisesRegex(ValueError, 'not uniquely'):
                    rec.pulse_source(target, monitor)
            sources.append(dict(sources[0]))
            result.stdout = __import__('json').dumps(sources)
            with self.assertRaisesRegex(ValueError, 'not uniquely'):
                rec.pulse_source('speaker', True)

    def test_recorder_header_is_not_video_but_muxed_packet_is(self):
        recorder = rec.Recorder.__new__(rec.Recorder)
        recorder.log, recorder.progress = '', False
        read, write = os.pipe()
        try:
            with os.fdopen(read, 'rb') as source:
                os.write(write, b'Output #0 matroska\nUsing video filter: pad\n')
                recorder.read_log(source)
                self.assertFalse(recorder.progress)
                os.write(write, b'Writing block of size 200 with pts 0 at offset 0. TrackNumber 1, keyframe 1\n')
                recorder.read_log(source)
                self.assertTrue(recorder.progress)
        finally:
            os.close(write)

    def test_audio_start_timeout_is_not_misreported_as_missing_video(self):
        recorder = rec.Recorder.__new__(rec.Recorder)
        recorder.state, recorder.when = 'starting', 0
        recorder.selection, recorder.progress, recorder.started = None, True, 0
        recorder.audio_target, recorder.audio_routes = 'speaker', []
        recorder.child = Mock(pid=1234)
        recorder.child.poll.return_value = None
        recorder.fail = Mock()
        with patch.object(rec, 'pipewire', return_value=[]), patch.object(rec.time, 'monotonic', return_value=11):
            recorder.tick()
        self.assertIn('Audio capture', recorder.fail.call_args.args[0])
