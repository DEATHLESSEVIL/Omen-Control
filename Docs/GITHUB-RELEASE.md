# Publish Omen Control Alpha 1.0V later

The handoff includes source, a combined experimental PKG and app ZIP. No GitHub repository or release has been created. Public assets are in dist/Release; private artwork-preserving assets are in dist/LocalRelease.

Extract Omen-Control-Alpha-1.0V-Source.zip and use its OMEN-Control folder as the repository root. It includes the native Xcode project, helper sources, original artwork generator, README, LICENSE, third-party notices, docs, tests and build tooling. Review staged files before pushing. SOURCE-SHA256.json describes this exact export; regenerate it after later edits or remove the stale manifest.

Do not upload the whole private workspace. Exclude build caches, binaries in dist, personal EFI configs, serials, hardware reports, probe output, backups, installation records, credentials and Xcode user data. The export uses an explicit allowlist. The OMEN logo is an HP trademark; MIT covers original code and does not grant trademark rights or imply HP endorsement.

Before publishing, test the UI, fan safety/recovery, quiet login, Dock transitions, source following and power-helper approval/denial/revocation on the actual laptop. Verify that unchanged Power Profile selections keep Apply disabled, local-only fan choices never request administrator access, and Low Power Mode changes read back correctly after one-time helper approval. Recheck audio/Wi-Fi independently; those EFI modifications are outside this project.

Build with ./build-app.sh or Xcode. A complete app bundle includes Contents/MacOS/OmenPowerHelper and Contents/Library/LaunchDaemons/local.omen.power.plist. App power-helper registration uses macOS ServiceManagement; do not replace it with a passwordless sudo rule or arbitrary-command daemon. Local ad-hoc builds may face approval/distribution restrictions. See POWER-HELPER.md.

When ready, commit the reviewed source and tag that commit v1.0-alpha.1. Attach the source ZIP and use RELEASE-NOTES.md for its description. Attach only the matching 1.0 assets and checksums from dist/Release. The combined installer still needs root/install/reboot acceptance testing before a stable release. Do not publish dist/LocalRelease or optional local artwork without its redistribution rights. User-visible signing/notarization requirements remain documented in LIMITATIONS.md; a source license is unrelated to Apple code signing.
