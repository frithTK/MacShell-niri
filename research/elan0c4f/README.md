# ELAN 04f3:0c4f: capture prototype

This is an early, experimental Linux userspace capture core for the ELAN `04f3:0c4f` USB fingerprint sensor. **It is not an authentication driver:** it does not enroll, verify, unlock a screen, change PAM or integrate with `fprintd`. Matching and false-accept testing are still research tasks.

The sensor protocol and frame rotation are based on [libfprint's ELAN driver](https://gitlab.freedesktop.org/libfprint/libfprint/-/tree/master/libfprint/drivers), copyright Igor Filatov and Sébastien Béchet. The C code is distributed under LGPL-2.1-or-later; see [COPYING](COPYING). The research compares approaches inspired by the separate [0c63 project](https://github.com/smox/libfprint-elan-04f3-0c63), which supports a different device and is not a dependency of the C core.

## Current scope

- C protocol and libusb transport, restricted to exactly one `04f3:0c4f` device; the transport does not detach kernel drivers or reset USB.
- Firmware and geometry discovery, bounded calibration, finger detection and an in-memory frame capture. The probe never enrolls or deletes a fingerprint and never writes an image or template to disk.
- Synthetic protocol tests using an injected transport, with no reader or biometric data.
- Python/OpenCV code is used only for research into image comparison. It is not part of the native capture library or an authentication implementation.

Sensor responses and calibration vary between devices; a successful capture is **not** evidence of recognition accuracy, spoof resistance or safe authentication. Do not enable this code in a lock screen, PAM, login or administrative authorization.

## Build and test

Requires a C11 compiler, Meson, Ninja and libusb 1.0 development files.

```sh
meson setup build
meson compile -C build
meson test -C build --print-errorlogs
```

The optional image-comparison research needs Python 3, NumPy and OpenCV's Python bindings. Its tests use generated images, not fingerprint samples:

```sh
python -m unittest discover -s tests -p 'test_features.py'
```

An optional in-memory study compares three experimental feature-extraction profiles. It uses a small C process for USB access and an unprivileged Python process for image analysis. You can check repeated idle waits without a fingerprint first:

```sh
python -B -m elan0c4f.study --bridge "$PWD/build/elan-study-bridge" --check-idle
```

The idle check compares each empty-reader frame with the calibration frame, and also compares their extracted features with each other. Median and 90th percentile background deltas are in sensor units; they are diagnostics, not biometric quality scores or acceptance thresholds. The check is only meaningful when the sensor is actually clear.

For an interactive study, omit `--check-idle`. The operator needs to coordinate five distinct touches for each of three fingers and confirm each change of finger by entering `continue`. It holds out the final two touches per finger and compares them with the first three. It evaluates the original one-way ratio matcher and a candidate requiring the ratio test to pass in both directions on exactly the same touches. [OpenCV documents reciprocal matching](https://docs.opencv.org/4.13.0/javadoc/org/opencv/features2d/BFMatcher.html); this stricter experimental variant is not established as an improvement for fingerprints. It also compares the original fixed calibration background with the latest idle frame before a touch; the very first touch uses the calibration background in both cases. The reader's reported release does not guarantee that an idle frame is uncontaminated, so this is only a research comparison. The reported values are matching scores, not authentication decisions. The sample sizes are much too small to estimate security or reliability. To avoid a misleading result, an incomplete study reports no comparisons.

For a repeatable smoke test that needs neither a reader nor biometric samples:

```sh
python -B -m elan0c4f.synthetic
```

It uses artificial random textures under rotation and translation and then adds a common synthetic artifact. The final case demonstrates what happens if the reference background contains that artifact before subtraction. They are not fingerprint images or a biometric test dataset. The shared-artifact case deliberately demonstrates that both matchers can assign high scores to different textures; a passing corrected case must not be interpreted as evidence that a real sensor's drift will be corrected, or as evidence of biometric accuracy or spoof resistance.

The helper exchanges frames over pipes and neither process writes images or templates to files. Core dumps are disabled. Frame buffers are cleared where practical, but Python and native image libraries may make temporary copies, and normal operating-system swap behavior is outside this prototype's control. Do not install the bridge as a setuid binary.

`build/elan-probe` only opens the reader, reports firmware and dimensions, then releases it. `build/elan-probe --capture` additionally calibrates and waits for one touch; frame bytes remain in memory and are cleared before exit. USB access may require system authorization. Close other fingerprint applications before running either probe. Device access is deliberately not configured or installed by this project.

The experiment uses no fingerprint image in its tests. Native USB and safe cleanup still need testing on more hardware and under disconnect, cancellation and suspend. A future `libfprint` integration requires a supported matcher, independent positive and negative evaluation, and a separate review of template protection and authentication semantics.
