import unittest

import numpy as np

from elan0c4f.features import PROFILES, compare, compare_mutual, extract
from elan0c4f.synthetic import benchmark, make_pair


class FeatureTests(unittest.TestCase):
    def test_profiles_handle_synthetic_frames_without_writing_files(self):
        random = np.random.default_rng(174)
        background = np.full((80, 80), 4000, dtype=np.uint16)
        frame = np.clip(background.astype(np.int32) + random.integers(-1000, 1000, (80, 80)), 0, 16383).astype(np.uint16)
        frames = np.stack([frame, frame, frame])
        for profile in PROFILES:
            with self.subTest(profile=profile):
                features = extract(frames, background, profile)
                self.assertGreater(features.count, 10)
                self.assertGreater(compare(features, features), 4)
                self.assertGreater(compare_mutual(features, features), 4)
                self.assertNotIn('descriptors', repr(features))

    def test_empty_capture_cannot_match(self):
        background = np.full((80, 80), 4000, dtype=np.uint16)
        empty = extract(background[None, :, :], background, 'temporal_median')
        self.assertEqual(empty.count, 0)
        self.assertEqual(compare(empty, empty), 0)
        self.assertEqual(compare_mutual(empty, empty), 0)

    def test_transformed_synthetic_pattern_has_correspondences(self):
        original, moved = make_pair(8)
        self.assertGreater(compare(original, moved), 4)
        self.assertGreater(compare_mutual(original, moved), 4)
        self.assertEqual(compare_mutual(original, moved), compare_mutual(moved, original))

    def test_shared_sensor_artifact_can_produce_false_correspondences(self):
        results = benchmark(size=2, shared_artifact=True)
        for result in results.values():
            self.assertGreater(max(result['different_pattern']), 5)

    def test_synthetic_artifact_in_reference_is_subtracted(self):
        results = benchmark(size=2, shared_artifact=True, compensate_artifact=True)
        for result in results.values():
            self.assertGreater(min(result['same_pattern']), 5)
            self.assertLess(max(result['different_pattern']), 5)

    def test_bad_inputs_are_rejected(self):
        background = np.zeros((80, 80), dtype=np.uint16)
        with self.assertRaises(ValueError):
            extract(np.zeros((0, 80, 80)), background, 'sharpest')
        with self.assertRaises(ValueError):
            extract(np.zeros((1, 79, 80)), background, 'sharpest')
        with self.assertRaises(ValueError):
            extract(np.zeros((1, 80, 80)), background, 'unknown')


if __name__ == '__main__':
    unittest.main()
