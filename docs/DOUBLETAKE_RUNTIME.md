# Doubletake runtime patch for AirPlay

MacShell starts Doubletake with an explicit `-fps` value. The default in the
MacShell UI is **60 FPS**, and the value can be changed in Settings → Screen
Mirroring. The receiver can still deliver fewer frames when its display,
encoder or network cannot sustain the requested rate.

MacShell also passes the requested TV volume through `-volume-percent`; the
default is **20%**. AirPlay represents this value as logarithmic dB, so 20% is
sent as `volume: -24.000000` on the AirPlay -30–0 dB scale, while `volume: 0` means 0 dB/full
scale. This changes the AirPlay receiver volume only and does not change the
computer's local PipeWire volume.

The `-volume-percent` option is available in the patched Doubletake runtime
used by MacShell. It is an external project and binary; MacShell does not
replace a system Doubletake installation automatically. When the requested
value is below 100%, MacShell refuses an older runtime instead of connecting
and silently resetting the TV to 100%. A runtime without this option can still
be used when the requested value is exactly 100%.
The MacShell runtime copy takes precedence over Doubletake on PATH.

From a Doubletake checkout, apply the corresponding local runtime patch and
build it according to the upstream instructions. Verify the installed binary:

```bash
doubletake -help 2>&1 | grep volume-percent
```

The integration tests use a fake sender to verify `-fps 60` and the default
20% volume setting without connecting to a real TV. Receiver volume curves
vary; the displayed TV percentage must be checked on the actual receiver.
