# macOS power access

OMEN Control 1.0 uses SMAppService on macOS 13+ to register an embedded, on-demand launch daemon. No setuid executable, permanent sudo rule, arbitrary shell interface or per-Apply administrator AppleScript is used.

## Enable and remove

Install the complete app at `/Applications/OmenControl.app`. In Settings choose **Enable power access…**. macOS may require administrator approval in System Settings → General → Login Items & Extensions. Until service status is enabled, Apply is unavailable for protected power changes; local fan preferences remain available. Returning to the app refreshes its approval/current-policy status. Approval can be revoked through **Disable power access** or macOS's own settings. Disable it before moving/removing the app.

The bundled plist is `Contents/Library/LaunchDaemons/local.omen.power.plist`, with BundleProgram `Contents/MacOS/OmenPowerHelper` and Mach service `local.omen.power`. ServiceManagement performs the privileged registration; app startup does not register it silently. The daemon runs as root only after macOS approval and launches on demand for XPC requests.

## Allowed operation

The sole XPC method accepts Boolean values and separate change flags for battery and AC. The executable path is always `/usr/bin/pmset`; argument tokens are generated solely as `-b lowpowermode 0|1` and/or `-c lowpowermode 0|1`. There is no caller-supplied path, power key, shell program, file write or raw fan/EC command. Source flags avoid rewriting unchanged/unsupported sources.

Connections must originate from the effective UID of the current local console user (UID 501 or higher). The helper rechecks console ownership before every queued operation, including after logout/fast-user switching. Other processes belonging to that same console user can request these same two Boolean power settings; the helper does not claim a code-signature-only client restriction. Its authority is deliberately limited to those settings.

The app records a successful Apply only after readback confirms requested changes. A failed/partial/timed-out request preserves an error and refreshes the actual state. The XPC completion is single-use across replies, errors and timeout. The 15-second client timeout does not imply the OS operation was cancelled; refresh determines its result. No automatic retry loop runs.

Local fan-profile changes save through UserDefaults with no helper call. Unchanged requests do not invoke privileged IPC. The power helper does not receive the fan driver's lease or control graphics/firmware.

## Build, signing and validation limits

SwiftPM builds the helper as a separate executable. The Xcode build phase compiles the same shared contract/helper source and embeds/signs it before the app is signed. The local build is ad-hoc signed. Distribution should use a stable Developer ID identity and macOS's supported service approval/signing flow; approval can change when the app identity or registration changes.

Builds, command allowlist/UID-policy tests, power parsing tests and signature integrity can be checked in the development environment. Full ServiceManagement approval, live root XPC changes and recovery after revocation still require a user desktop acceptance test. Do not describe those as completed based solely on compilation.

Apple references: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [LaunchDaemon registration](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:)).
