# Compatibility, limitations and risks

This is an experimental community utility, not an HP product. A working fan-control report on one laptop is not certification for other laptops.

## Tested platform and installer restrictions

- Physical HP OMEN 16-wf1xxx, PCI subsystem vendor 103C, board 8C78, BIOS F.15; Intel i7-14650HX and NVIDIA RTX 4060 Laptop GPU.
- The app builds for Intel macOS 13+. The supplied bridge is built with the macOS 26.5 SDK and the first combined installer is restricted to Darwin 25.5–25.99. Other macOS releases are unvalidated for this driver.
- The package requires an actual writable mounted FAT EFI volume, and exactly one mounted volume containing EFI/OC/config.plist and OpenCore.efi. It does not mount or guess a boot partition. Unmount other EFI volumes and mount the actual boot EFI yourself.
- The first package accepts only the exact tested OpenCore 1.0.8 binary, SHA-256 `1569cd1d183c5ee9fda2eced767a4b2efa307e6edfcf2a50109c9657098671ff`, so its bundled ocvalidate matches the loader. A different hash, including another 1.0.8 build, requires manual installation with the matching validator. The hash check is a narrow compatibility gate, not a security signature or proof of the boot partition's identity.
- Physical board identity is checked independently of spoofed SMBIOS. BIOS F.15 is the tested BIOS; its version is not reliably detectable under spoofed macOS and is not enforced by the installer. Confirm it yourself. Future BIOS updates may change this protocol.

## Fan and sensor behavior

- Manual 1–100% requests scale each fan's own maximum and clamp to the firmware minimum. The tested CPU range is 2000–6000 RPM, GPU 2300–6300 RPM.
- **0% means firmware Auto, not fan stop.** This firmware's fan-stop method is a stub. The UI does not promise stopped fans.
- RPM readback is in 100-RPM increments. Animation is slowed by 1/240 for visibility; it is not a physical tachometer display.
- GPU temperature depends on an exposed SMC sensor or a successful read-only NVIDIA RM query through the existing driver. That fallback is not verified on every driver and may return unavailable. No graphics driver is included, patched or replaced.
- Temperature curves need both CPU and GPU temperatures. Missing/stale data disables or exits curve control. CPU firmware temperature does not stand in for GPU temperature.
- Thermal override, user-client disconnect, lease expiry and the firmware timeout are fallbacks; they cannot guarantee protection against every firmware/driver failure. The bridge requests Auto at a validated CPU sample of 90°C. Monitor first use while attended.
- Performance means full fan requests. It does not change HP CPU/GPU power limits. Battery/AC Low Power Mode uses a narrowly scoped on-demand helper, requiring explicit macOS approval. Local fan preferences do not require administrator access. Missing policies are unavailable.
- Service off stops this app's polling and OMEN-key handling, closes its connection and requests Auto if it owns manual control. It does not unload the kernel extension. A controller shell remains so Settings is reachable.
- Service and login startup currently share one setting. Dock visibility is a separate setting. Live Dock/service transitions still need acceptance testing on the desktop.

## Installation and recovery risks

Kernel extensions and EFI changes can cause boot failure, crashes, sleep/wake problems, thermal throttling or data loss. A complete verified EFI backup is made before the package changes the driver/config; keep a separate bootable recovery USB as well. Do not rely on a backup stored only on an unbootable startup disk.

The installer does not replace OpenCore, SMBIOS/serials, boot arguments, ACPI tables, graphics, Wi-Fi, audio or keyboard drivers. Only OmenFanBridge.kext and its Kernel/Add entry are changed. Config serialization may change formatting/key order, but other values are preserved.

Postinstall verifies the installed files and runs ocvalidate. An ordinary commit failure attempts a verified rollback. Loss of power, storage failure, process termination, or a rollback error can leave a partial update; the backup and recovery USB remain essential. Read the installer log before rebooting after an error. A failed postinstall can leave the new application installed even when the EFI transaction was rolled back.

A reboot is required to load a changed kext. The package does not hot-load or unload kernel code, change SIP, disable Gatekeeper or change SecureBootModel. It requires an already working OpenCore setup.

## Distribution and testing status

The historical first package is unsigned and local app builds are ad-hoc signed. It is not Developer-ID signed or Apple-notarized, so macOS may block it. Do not disable system-wide security as an installation step. Trusted external distribution requires the maintainer's Developer ID signing and notarization workflow; those credentials are not part of this project. The bundled kext requires an Apple-approved kext-capable signing identity for standard Apple distribution; an ordinary app certificate does not cover it. Notarization of this combined EFI-kext package is not guaranteed.

Builds, signature integrity, archive contents, policy checks and synthetic EFI transaction/rollback tests can be verified locally. The complete Installer GUI/root workflow and reboot after installing this package have **not** been tested end-to-end on hardware. The combined 1.0 installer remains experimental until those tests pass. Version 1.0 has a new power helper whose registration/live privileged XPC behavior still needs desktop acceptance testing; a passing build is not that test.

MIT covers this project's original code. It does not grant HP/OMEN trademark rights or relicense bundled third-party code. NVIDIA ABI notices and the ocvalidate BSD license are included. Public artifacts contain no NullMoth driver, personal EFI config, serials or hardware reports.
