import unittest

import numpy as np

from elan0c4f.diagnostics import background_delta


class DiagnosticTests(unittest.TestCase):
    def test_unsigned_difference_and_border_exclusion(self):
        background = np.full((80, 80), 1000, dtype=np.uint16)
        frame = np.full((80, 80), 900, dtype=np.uint16)
        frame[:3, :] = 65000
        self.assertEqual(background_delta(frame, background), (100.0, 100.0))

    def test_invalid_frames_rejected(self):
        with self.assertRaises(ValueError):
            background_delta(np.zeros((79, 80)), np.zeros((80, 80)))
        frame = np.zeros((80, 80))
        frame[20, 20] = np.nan
        with self.assertRaises(ValueError):
            background_delta(frame, np.zeros((80, 80)))
