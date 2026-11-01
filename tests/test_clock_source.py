import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import clock_source


class ClockSourceTests(unittest.TestCase):
    def test_boot_id_is_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'boot_id'
            path.write_text('bb1e22b6-bfec-4501-aad7-082c60b8a74f\n')
            self.assertEqual(clock_source.boot_id(path), 'bb1e22b6-bfec-4501-aad7-082c60b8a74f')
            path.write_text('not-a-uuid')
            with self.assertRaises(ValueError):
                clock_source.boot_id(path)

    def test_kernel_clock_and_wall_clock_are_separate(self):
        with mock.patch.object(clock_source.time, 'clock_gettime_ns', return_value=1234567890) as kernel:
            with mock.patch.object(clock_source.time, 'time_ns', return_value=2000999999):
                self.assertEqual(clock_source.boot_time_ms(), 1234)
                self.assertEqual(clock_source.wall_time_ms(), 2000)
        kernel.assert_called_once_with(clock_source.time.CLOCK_BOOTTIME)


if __name__ == '__main__':
    unittest.main()
