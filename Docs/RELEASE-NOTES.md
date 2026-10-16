# Omen Control Alpha 1.0V

- Power & startup is renamed **Power Profile**.
- Low Power Mode initializes from actual macOS battery/AC policies, refreshes on app activation, preserves drafts and verifies changed system settings after applying.
- Apply is disabled when no effective request differs from live policy/accepted local fan choices. Sources not reported by macOS are unavailable rather than guessed.
- Saving only battery/AC fan-profile preferences never requests administrator access.
- Added a narrowly scoped, on-demand power helper with explicit one-time macOS approval, fixed Boolean power commands, console-user authorization and a disable control. Removed the per-change password script.
- Restored layered fan artwork for local builds while retaining independent RPM-matched rotation. Source-only builds use the built-in vector fallback.
- Updated MIT-licensed source, README, native Xcode project and technical limitations. Required third-party notices are retained.

This release includes the app, source and combined experimental PKG. The board-specific bridge remains 0.4.0; building this release does not change live EFI; running its installer does. Version 1.0 is not a claim of universal hardware support. Privileged helper approval/live writes and the new UI still require desktop acceptance testing.

- Overview includes fan controls, with a separate Power Profile page and no scrolling. Settings remain accessible from every main page.
- NVIDIA hardware uses a small transparent logo PNG on the GPU chip artwork.

- Appearance offers Chip Image or Product Image; temperature details open in a popover to keep page height bounded.

- Fixed runaway window height by disabling intrinsic hosting-view sizing and bounding AppKit window dimensions. Overview and Power Profile share stable window bounds without navigation-driven resizing.
- Version 1.0 build 19 includes refreshed app, Xcode source export, documentation and combined experimental installer.

- Alpha build 20: constrained the translucent background to a full-window container and removed page-driven window resizing to prevent material/compositor tearing. Display name: Omen Control Alpha 1.0V.
