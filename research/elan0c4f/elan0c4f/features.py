# SPDX-License-Identifier: LGPL-2.1-or-later
"""Experimental touch-image descriptors; scores are not authentication decisions."""
from dataclasses import dataclass, field

import cv2
import numpy as np

DIMENSION = 80
PROFILES = ('most_features', 'temporal_median', 'sharpest')


@dataclass(repr=False)
class Features:
    points: tuple = field(repr=False)
    descriptors: np.ndarray | None = field(repr=False)

    @property
    def count(self):
        return 0 if self.descriptors is None else len(self.descriptors)


def _normalize(signal):
    image = np.asarray(signal, dtype=np.float32)
    if image.shape != (DIMENSION, DIMENSION) or not np.isfinite(image).all():
        raise ValueError('Invalid capture dimensions or values')
    # Remove the sensor border; this is an experiment, not a calibrated setting.
    image = image[3:-3, 3:-3]
    lo, hi = np.percentile(image, (1, 99))
    if hi - lo < 1:
        return np.zeros((148, 148), dtype=np.uint8)
    scaled = (np.clip((image - lo) / (hi - lo), 0, 1) * 255).astype(np.uint8)
    enlarged = cv2.resize(scaled, (148, 148), interpolation=cv2.INTER_CUBIC)
    return cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(enlarged)


def extract(frames, background, profile):
    if profile not in PROFILES:
        raise ValueError('Unknown experimental profile')
    frames = np.asarray(frames)
    background = np.asarray(background)
    if frames.ndim != 3 or not 1 <= len(frames) <= 8 or frames.shape[1:] != (DIMENSION, DIMENSION):
        raise ValueError('Invalid frame set')
    if background.shape != (DIMENSION, DIMENSION):
        raise ValueError('Invalid background')
    signal = frames.astype(np.float32) - background.astype(np.float32)
    if profile == 'temporal_median':
        images = [_normalize(np.median(signal, axis=0))]
    else:
        images = [_normalize(frame) for frame in signal]
    detector = cv2.SIFT_create(contrastThreshold=.04, edgeThreshold=12, sigma=1.2)
    candidates = []
    for image in images:
        points, descriptors = detector.detectAndCompute(image, None)
        sharpness = float(cv2.Laplacian(image, cv2.CV_32F).var())
        candidates.append((tuple(points), descriptors, sharpness))
    if profile == 'sharpest':
        best = max(candidates, key=lambda item: item[2])
    else:
        best = max(candidates, key=lambda item: len(item[0]))
    return Features(best[0], best[1])


def _ratio_matches(matcher, query, reference):
    pairs = matcher.knnMatch(query, reference, k=2)
    return [pair[0] for pair in pairs if len(pair) == 2 and pair[0].distance < .70 * pair[1].distance]


def _compare(left, right, mutual):
    if left.descriptors is None or right.descriptors is None or left.count < 2 or right.count < 2:
        return 0
    matcher = cv2.BFMatcher(cv2.NORM_L2)
    good = _ratio_matches(matcher, left.descriptors, right.descriptors)
    if mutual:
        reverse = _ratio_matches(matcher, right.descriptors, left.descriptors)
        reciprocal = {(match.trainIdx, match.queryIdx) for match in reverse}
        good = [match for match in good if (match.queryIdx, match.trainIdx) in reciprocal]
    if len(good) < 4:
        return 0
    source = np.float32([left.points[match.queryIdx].pt for match in good])
    target = np.float32([right.points[match.trainIdx].pt for match in good])
    cv2.setRNGSeed(0)
    _, inliers = cv2.estimateAffinePartial2D(source, target, method=cv2.RANSAC,
                                               ransacReprojThreshold=3.0, maxIters=5000, confidence=.99)
    return 0 if inliers is None else int(inliers.sum())


def compare(left, right):
    """Baseline: one-way ratio and geometric agreement, not an auth decision."""
    return _compare(left, right, mutual=False)


def compare_mutual(left, right):
    """Candidate: require the ratio test to agree in both directions."""
    return _compare(left, right, mutual=True)
