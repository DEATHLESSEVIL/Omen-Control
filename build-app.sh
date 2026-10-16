#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
if ! xcrun --find swift >/dev/null 2>&1; then
  print -u2 'Install Xcode or Apple Command Line Tools first, then run this script again.'
  exit 1
fi
swift build --disable-sandbox -c release --arch x86_64
binary_dir="$(swift build --disable-sandbox -c release --arch x86_64 --show-bin-path)"
bundle="$PWD/dist/OmenControl.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/OmenControl" "$bundle/Contents/MacOS/OmenControl"
mkdir -p "$bundle/Contents/Resources"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
ditto Resources/Branding "$bundle/Contents/Resources/Branding"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp THIRD-PARTY-NOTICES.md "$bundle/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
# Refresh optional local artwork without retaining stale files.
rm -rf "$bundle/Contents/Resources/LocalFanArtwork"
if [[ -d Resources/LocalFanArtwork ]]; then
    ditto Resources/LocalFanArtwork "$bundle/Contents/Resources/LocalFanArtwork"
fi
mkdir -p "$bundle/Contents/Library/LaunchDaemons"
cp Resources/LaunchDaemons/local.omen.power.plist "$bundle/Contents/Library/LaunchDaemons/"
cp "$binary_dir/OmenPowerHelper" "$bundle/Contents/MacOS/OmenPowerHelper"
codesign --force --sign - "$bundle/Contents/MacOS/OmenPowerHelper"
codesign --force --sign - "$bundle"
print "Built $bundle"
