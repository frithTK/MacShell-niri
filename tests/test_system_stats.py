import importlib.util
from pathlib import Path
import sys
import os
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))

spec = importlib.util.spec_from_file_location('stats', Path(__file__).parents[1] / 'MacShell/system_stats.py')
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)


class StatsTests(unittest.TestCase):
    def test_standard_root_keeps_its_block_layer_without_mount_fallback(self):
        with patch.object(stats.os, 'stat', return_value=SimpleNamespace(st_dev=os.makedev(8, 1))), \
                patch.object(stats, 'block_name', return_value='sda1'), patch.object(stats, 'read') as read:
            self.assertEqual(stats.root_device({'sda', 'sda1'}), 'sda1')
            read.assert_not_called()

    def test_mountinfo_optional_fields_and_escaped_source(self):
        text = '54 32 0:37 /@ / rw,noatime shared:1 - btrfs /dev/mapper/crypt\\040root rw,subvol=/@\n'
        self.assertEqual(stats.root_mount(text), ('btrfs', '/dev/mapper/crypt root'))
        self.assertEqual(stats.root_mount('broken\n'), ('', ''))
        self.assertEqual(stats.root_mount(text + text), ('', ''))

    def test_anonymous_btrfs_root_uses_mount_source_not_an_unrelated_disk(self):
        text = '54 32 0:37 /@ / rw - btrfs /dev/nvme0n1p2 rw,subvol=/@\n'
        nodes = [SimpleNamespace(st_dev=os.makedev(0, 37)),
                 SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(259, 3))]
        with patch.object(stats.os, 'stat', side_effect=nodes) as node, \
                patch.object(stats, 'block_name', side_effect=['', 'nvme0n1p2']), \
                patch.object(stats, 'read', return_value=text), patch.object(stats, 'single_btrfs_device', return_value=True):
            self.assertEqual(stats.root_device({'nvme0n1p2', 'nvme1n1'}), 'nvme0n1p2')
            self.assertEqual(node.call_args_list[-1].args, ('/dev/nvme0n1p2',))

    def test_multi_device_btrfs_requires_an_explicit_layer(self):
        with patch.object(stats.os, 'stat', side_effect=[SimpleNamespace(st_dev=0), SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=1)]), \
                patch.object(stats, 'block_name', side_effect=['', 'sda1']), \
                patch.object(stats, 'read', return_value='1 0 0:1 /@ / rw - btrfs /dev/sda1 rw'), \
                patch.object(stats, 'single_btrfs_device', return_value=False):
            self.assertEqual(stats.root_device({'sda1', 'sdb1'}), '')

    def test_single_btrfs_group_is_matched_by_device(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            devices = base / 'filesystem' / 'devices'; devices.mkdir(parents=True)
            (devices / 'nvme0n1p2').touch()
            self.assertTrue(stats.single_btrfs_device('nvme0n1p2', base))
            self.assertFalse(stats.single_btrfs_device('nvme1n1', base))
            (devices / 'nvme1n1p2').touch()
            self.assertFalse(stats.single_btrfs_device('nvme0n1p2', base))

    def test_overlay_and_non_block_mount_sources_never_pick_the_first_disk(self):
        with patch.object(stats.os, 'stat', return_value=SimpleNamespace(st_dev=0)), \
                patch.object(stats, 'block_name', return_value=''), \
                patch.object(stats, 'read', return_value='1 0 0:1 / / rw - overlay overlay rw'):
            self.assertEqual(stats.root_device({'sda', 'nvme0n1'}), '')
        with patch.object(stats.os, 'stat', side_effect=[SimpleNamespace(st_dev=0), SimpleNamespace(st_mode=stat.S_IFREG)]), \
                patch.object(stats, 'block_name', return_value=''), \
                patch.object(stats, 'read', return_value='1 0 0:1 / / rw - ext4 /dev/not-a-device rw'):
            self.assertEqual(stats.root_device({'sda'}), '')

    def test_device_mapper_mount_source_retains_the_logical_layer(self):
        with patch.object(stats.os, 'stat', side_effect=[SimpleNamespace(st_dev=0), SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(253, 0))]), \
                patch.object(stats, 'block_name', side_effect=['', 'dm-0']), \
                patch.object(stats, 'read', return_value='1 0 0:1 / / rw - ext4 /dev/mapper/root rw'):
            self.assertEqual(stats.root_device({'dm-0', 'sda2'}), 'dm-0')

    def test_cpu_guest_is_not_counted_twice_and_iowait_is_idle(self):
        self.assertEqual(stats.cpu_counters('cpu 10 2 3 40 5 6 7 8 100 100')['cpu'], (81, 45))
        self.assertEqual(stats.cpu_delta((100, 30), (200, 70)), 60)
        self.assertIsNone(stats.cpu_delta((200, 30), (100, 50)))

    def test_ram_uses_available_and_binary_units(self):
        m = stats.memory('MemTotal: 1000 kB\nMemAvailable: 400 kB\nSwapTotal: 200 kB\nSwapFree: 50 kB')
        self.assertEqual(m['used'], 600 * 1024)
        self.assertEqual(m['swapUsed'], 150 * 1024)

    def test_network_and_disk_counters(self):
        net = stats.networks('header\nheader\n eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0')
        self.assertEqual(net['eth0'], (100, 200))
        self.assertEqual(stats.disks('259 0 nvme0n1 0 0 10 0 0 0 20 0 0 0 0')['nvme0n1'], (5120, 10240))
        self.assertEqual(stats.rates((10, 20), (30, 80), 2), [10, 30])
        self.assertIsNone(stats.rates((10, 20), (0, 80), 2))
        self.assertIsNone(stats.rates(None, (30, 80), 2))

    def test_resume_and_device_change_reseed(self):
        sampler = stats.Sampler()
        with patch.object(stats, 'root_device', return_value=''), patch.object(stats, 'default_interface', return_value='lo'):
            self.assertTrue(sampler.sample(now=100, boot=100)['gap'])
            self.assertFalse(sampler.sample(now=101, boot=101)['gap'])
            resumed = sampler.sample(now=102, boot=162)
            self.assertTrue(resumed['gap'])
            self.assertIsNone(resumed['cpu'])
            missing = sampler.sample(interface='missing', device='missing', now=103, boot=163)
            self.assertEqual(missing['interface'], '')
            self.assertIsNone(missing['network'])
            self.assertIsNone(missing['disk'])
            sampler.previous['cpu'] = {}  # CPU hotplug/topology reset.
            self.assertTrue(sampler.sample(now=104, boot=164)['gap'])

    def test_ipv6_default_route(self):
        route = '0'*32 + ' 00 ' + '0'*32 + ' 00 ' + '0'*32 + ' 00000064 00000000 00000000 00000001 eth0'
        with patch.object(stats.Path, 'exists', return_value=True):
            self.assertEqual(stats.default_interface(['eth0', 'tun0'], '', route), 'eth0')
