# Install and recover

Read [compatibility, limitations and risks](Docs/LIMITATIONS.md) before using kernel code. This package is an experimental release for the tested 8C78 board, not a universal OMEN installer.

## Combined PKG

1. Confirm HP board 8C78 and tested BIOS F.15, Intel macOS/Darwin 25.5–25.99, and an already working OpenCore installation. Prepare an independent bootable recovery USB.
2. Mount the actual boot EFI. Leave exactly one mounted EFI/OC, using the exact tested OpenCore 1.0.8 binary documented in LIMITATIONS.md. The package refuses other or ambiguous targets. It does not select or mount a partition for you.
3. Quit OMEN Control using its menu. Download the PKG and SHA256SUMS.txt from the same release and verify the hash, for example `shasum -a 256 -c SHA256SUMS.txt` after downloading all listed assets into one directory. Checksums show consistency with that manifest, not publisher identity.
4. Open `Omen-Control-Alpha-1.0V-8C78-Experimental.pkg`. Read its Introduction, Read Me and License screens. Authenticate in Installer. The unsigned first package may be blocked by macOS; do not disable system-wide security. Review unsigned software through macOS's supported per-item security UI only if you trust its source.
5. Preinstall checks physical hardware/OS, finds one mounted target, validates the original and candidate configs, and makes a SHA-256-verified copy of the whole EFI. A running app blocks installation. No driver is changed at this stage.
6. The payload installs `/Applications/OmenControl.app` and `/Library/Application Support/OMEN Control/` containing documentation, driver and tools. Postinstall replaces only the bridge and its config entry, verifies them and runs the matching ocvalidate. It configures quiet login for the current desktop user, preserving a saved service-off preference. It does not launch manual control during installation.
7. Restart when the installer requests it. Open the app and check the driver version in Diagnostics, fan RPM, Manual, Eco, Performance, Auto, and recovery to Auto when quitting.

No console user means quiet-login setup is deferred: turn the service off and back on in Settings after logging in. If login setup fails, the app/EFI can still be installed; the installer log reports this and Settings can retry.

EFI backups are in `/Library/Application Support/OMEN Control/Backups/working before OMEN package …/EFI`, with SHA256.json beside them. Backups are restricted to administrator/root access because EFI configs may contain identifiers. Never upload them to GitHub.

## Manual installation / other OpenCore builds

Build the app with `./build-app.sh` and open it from Applications. The clean App ZIP in the release is app-only; it does not install a driver. Build the kext using `zsh Driver/build-fan-bridge.sh` with the documented SDK. Other boards/firmware are unsupported; changing a board check is not hardware validation.

Back up the whole EFI and verify it. On a compatible 8C78 board, place OmenFanBridge.kext in EFI/OC/Kexts and add or update exactly one enabled Kernel/Add entry:

```xml
<dict>
 <key>Arch</key><string>x86_64</string>
 <key>BundlePath</key><string>OmenFanBridge.kext</string>
 <key>Comment</key><string>OMEN board 8C78 fan bridge 0.4.0</string>
 <key>Enabled</key><true/>
 <key>ExecutablePath</key><string>Contents/MacOS/OmenFanBridge</string>
 <key>MinKernel</key><string>25.5.0</string>
 <key>MaxKernel</key><string>25.99.99</string>
 <key>PlistPath</key><string>Contents/Info.plist</string>
</dict>
```

Validate with **your OpenCore release's matching ocvalidate**, then reboot. Never copy a whole EFI/config from this project or another machine. Neither the source nor the release contains a personal EFI config.

## Restore / uninstall

Turn the background service off in Settings first. Mount the correct EFI and keep the recovery USB available. For an installer regression, restore OmenFanBridge.kext (or its prior absence) and config.plist from the verified backup, validate using the matching OpenCore validator, then reboot. Restore other EFI files only when they actually need restoration; a later unrelated EFI change should not be overwritten blindly.

To remove the driver entirely, remove its Kernel/Add entry and EFI/OC/Kexts/OmenFanBridge.kext together, validate and reboot. Removing only the app does not remove kernel code. After disabling the service, you may remove the app and the per-user `~/Library/LaunchAgents/local.omen.login.control.plist`. Retain backup/recovery material until booting and automatic cooling have been confirmed. Package receipts are not an EFI uninstaller.

## First hardware acceptance test

Check quiet login; Dock visibility on/off with dashboard/Settings open and closed; service off/on and error reporting; Apply dirty-state behavior; actual CPU/GPU RPM at several requests; Auto on quit; GPU sensor availability and curve fallback; unplug/replug profile changes; sleep/wake; reboot; and recovery USB bootability. Record outcomes without publishing serial numbers or full registry dumps.

## Version 1.0 app/source update

The combined 1.0 PKG is supplied with this release. The app/source version is 1.0, while the fan bridge remains 0.4.0. Build/copy the complete app to Applications. Open Settings → Enable power access… to register the embedded helper and approve it in macOS when requested. Local fan preferences and ordinary fan Apply do not need that approval. Disable power access before removing the app. See Docs/POWER-HELPER.md.
