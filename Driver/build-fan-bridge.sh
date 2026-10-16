#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
headers="$sdk/System/Library/Frameworks/Kernel.framework/Headers"
resource="$(xcrun clang -print-resource-dir)"
mkdir -p build ../dist/OmenFanBridge.kext/Contents/MacOS
flags=(-arch x86_64 -std=c++17 -mkernel -fapple-kext -fno-exceptions -fno-rtti -fno-common -nostdinc -isystem "$headers" -isystem "$resource/include" -DKERNEL -DKERNEL_PRIVATE -O2 -mmacosx-version-min=26.5)
xcrun clang++ $flags -c OmenFanBridge.cpp -o build/OmenFanBridge.o
xcrun clang++ $flags -c FanModule.cpp -o build/FanModule.o
xcrun clang++ -arch x86_64 -nostdlib -Wl,-kext -Wl,-undefined,dynamic_lookup -mmacosx-version-min=26.5 -isysroot "$sdk" build/OmenFanBridge.o build/FanModule.o -lkmod -lkmodc++ -o ../dist/OmenFanBridge.kext/Contents/MacOS/OmenFanBridge
python3 -c 'import plistlib,sys; plistlib.dump({"CFBundleIdentifier":"local.omen.FanBridge","CFBundleName":"OmenFanBridge","CFBundleExecutable":"OmenFanBridge","CFBundlePackageType":"KEXT","CFBundleVersion":"0.4.0","CFBundleShortVersionString":"0.4.0","OSBundleRequired":"Root","OSBundleLibraries":{"com.apple.kpi.iokit":"13.0.0","com.apple.kpi.libkern":"13.0.0","com.apple.kpi.mach":"13.0.0","com.apple.iokit.IOACPIFamily":"1.4"},"IOKitPersonalities":{"Omen Fan Bridge":{"CFBundleIdentifier":"local.omen.FanBridge","IOClass":"OmenFanBridge","IOProviderClass":"IOACPIPlatformDevice","IONameMatch":"PNP0C14","IOMatchCategory":"OmenFanBridge","IOProbeScore":1000}}},open(sys.argv[1],"wb"))' ../dist/OmenFanBridge.kext/Contents/Info.plist
print 'Built OmenFanBridge 0.4.0; not installed.'
