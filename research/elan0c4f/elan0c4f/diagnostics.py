# SPDX-License-Identifier: LGPL-2.1-or-later
"""Aggregate sensor diagnostics, not a fingerprint quality or identity score."""
import numpy as np

from .features import DIMENSION


def background_delta(frame, reference):
    """Measure absolute per-pixel differences in the interior, in raw ADC units."""
    frame = np.asarray(frame)
    reference = np.asarray(reference)
    if frame.shape != (DIMENSION, DIMENSION) or reference.shape != frame.shape:
        raise ValueError('Invalid frame dimensions')
    if not np.isfinite(frame).all() or not np.isfinite(reference).all():
        raise ValueError('Invalid frame values')
    # Signed conversion before subtraction avoids uint16 wraparound.
    delta = np.abs(frame[3:-3, 3:-3].astype(np.float64) - reference[3:-3, 3:-3].astype(np.float64))
    return float(np.median(delta)), float(np.percentile(delta, 90))
