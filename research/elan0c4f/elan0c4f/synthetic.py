# SPDX-License-Identifier: LGPL-2.1-or-later
"""Reproducible non-biometric image transformations for algorithm smoke tests.

These random textures are NOT fingerprints and cannot estimate fingerprint accuracy.
"""
import cv2
import numpy as np

from .features import compare, compare_mutual, extract


def make_pair(seed, shared_artifact=None, compensate_artifact=False):
    random = np.random.default_rng(seed)
    # A repeatable textured image provides distinguishable points, not ridges.
    texture = random.normal(0, 1, (80, 80)).astype(np.float32)
    texture = cv2.GaussianBlur(texture, (0, 0), .75)
    texture = texture / max(float(texture.std()), 1e-6) * (120 if shared_artifact is not None else 500)
    if compensate_artifact and shared_artifact is None:
        raise ValueError('No artificial background artifact supplied')
    reference = 4000 if not compensate_artifact else 4000 + shared_artifact
    background = np.full((80, 80), reference, dtype=np.uint16)
    matrix = cv2.getRotationMatrix2D((39.5, 39.5), 8, 1)
    matrix[:, 2] += [3, -2]
    moved = cv2.warpAffine(texture, matrix, (80, 80), flags=cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_REFLECT_101)
    artifact = 0 if shared_artifact is None else shared_artifact
    original = np.clip(4000 + artifact + texture + random.normal(0, 20, (80, 80)), 0, 65535).astype(np.uint16)
    moved = np.clip(4000 + artifact + moved + random.normal(0, 20, (80, 80)), 0, 65535).astype(np.uint16)
    return (extract(original[None], background, 'temporal_median'),
            extract(moved[None], background, 'temporal_median'))


def benchmark(size=8, shared_artifact=False, compensate_artifact=False):
    if not 2 <= size <= 64:
        raise ValueError('Invalid synthetic benchmark size')
    artifact = None
    if shared_artifact:
        artifact = np.random.default_rng(999).normal(0, 1, (80, 80)).astype(np.float32)
        artifact = cv2.GaussianBlur(artifact, (0, 0), .75)
        artifact *= 500 / float(artifact.std())
    pairs = [make_pair(seed, artifact, compensate_artifact) for seed in range(size)]
    results = {}
    for name, scorer in (('ratio', compare), ('mutual_ratio', compare_mutual)):
        same = [scorer(original, moved) for original, moved in pairs]
        different = [scorer(pairs[i][0], pairs[j][1])
                     for i in range(size) for j in range(size) if i != j]
        results[name] = {'same_pattern': same, 'different_pattern': different}
    return results


if __name__ == '__main__':
    print('SYNTHETIC NON-BIOMETRIC TEST: not evidence of fingerprint accuracy')
    for shared, compensate in ((False, False), (True, False), (True, True)):
        print(f'shared_artifact={shared} corrected_background={compensate}')
        for policy, result in benchmark(shared_artifact=shared, compensate_artifact=compensate).items():
            same, different = result['same_pattern'], result['different_pattern']
            print(f'{policy}: same_min={min(same)}; different_count={len(different)}; '
                  f'different_max={max(different)}; different_nonzero={sum(value > 0 for value in different)}')
