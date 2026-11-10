# Security policy

Security fixes target the current `main` branch of this niri port. Historical commits and the original upstream project are not maintained by this repository.

## Reporting a vulnerability

Use **Security → Report a vulnerability** when private reporting is available. If the button is unavailable, open an issue requesting a private contact without including exploitation details, credentials or personal data. Do not post Wi-Fi passwords, PAM credentials, session cookies or unredacted desktop snapshots in public issues.

Include the affected commit, niri/Quickshell/Qt versions, a minimal reproduction, expected permissions and the impact. Authentication bypasses, unintended credential exposure, capture permission failures and unsafe installer/rollback behavior are relevant reports. Response times are not guaranteed.

## Runtime boundaries

MacLock uses an existing PAM service; the installer does not modify system PAM files. Wi-Fi credentials are handled through NetworkManager. IPC and D-Bus helpers run in the user's session. Test lock/unlock behavior in your own configured session before relying on a new PAM or runtime configuration.

A visible Batteries card asks the Bluetooth helper to listen for Apple LE advertisements; that is not Control Center pairing search and does not list unpaired devices in the picker. Connected AirPods also use the existing A2DP link's AACP control channel (L2CAP 0x1001) for live charge; the helper does not enable `bluetoothd --experimental` or change DeviceID. Screen Mirroring Extend may prompt for a password (pkexec) to write an HDMI/DisplayPort DRM dummy; it does not force the laptop panel (`eDP`).

Snapshot and rollback directories can contain personal configuration. Keep them private and share only the files needed to reproduce a problem. These directories, `.env` files and common key formats are excluded from version control.
