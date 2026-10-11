#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$probe_root"
probe_build="$probe_root/.ci-jit-probe"
probe_app="$probe_build/Payload/MadeiraJITProbe.app"
mkdir -p "$probe_app" "$probe_root/ipa" "$probe_root/ci-logs"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
probe_flags=(-arch arm64 -isysroot "$probe_sdk" -miphoneos-version-min=15.6 -DMADEIRA_JIT_PROBE=1 -O0 -g -Iapp/Madeira)
xcrun --sdk iphoneos clang "${probe_flags[@]}" -c app/Madeira/JITAllocator.c -o "$probe_build/JITAllocator.o"
xcrun --sdk iphoneos clang "${probe_flags[@]}" -fobjc-arc -c tools/jit-probe/main.m -o "$probe_build/main.o"
xcrun --sdk iphoneos clang "${probe_flags[@]}" "$probe_build/main.o" "$probe_build/JITAllocator.o" \
    -framework UIKit -framework Foundation -o "$probe_app/MadeiraJITProbe"
PROBE_APP="$probe_app" PROBE_COMMIT="$(git rev-parse HEAD)" python3 - <<'PY'
import os
import plistlib
from pathlib import Path

info = {
    'CFBundleExecutable': 'MadeiraJITProbe',
    'CFBundleIdentifier': 'com.icey9527.madeira.jitprobe',
    'CFBundleName': 'MadeiraJITProbe',
    'CFBundleDisplayName': 'Madeira JIT Probe',
    'CFBundlePackageType': 'APPL',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleShortVersionString': '0.1',
    'CFBundleVersion': '3',
    'MinimumOSVersion': '15.6',
    'LSRequiresIPhoneOS': True,
    'UIDeviceFamily': [1, 2],
    'UIRequiredDeviceCapabilities': ['arm64'],
    'UILaunchScreen': {},
    'UIFileSharingEnabled': True,
    'LSSupportsOpeningDocumentsInPlace': True,
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    'ProbeCommit': os.environ['PROBE_COMMIT'],
}
with (Path(os.environ['PROBE_APP']) / 'Info.plist').open('wb') as output:
    plistlib.dump(info, output)
(Path(os.environ['PROBE_APP']) / 'PkgInfo').write_bytes(b'APPL????')
PY
xcrun dsymutil "$probe_app/MadeiraJITProbe" -o "$probe_build/MadeiraJITProbe.dSYM"
(cd "$probe_build" && zip -qry "$probe_root/ci-logs/jit-probe-symbols.zip" MadeiraJITProbe.dSYM)
codesign --force --sign - --entitlements tools/jit-probe/entitlements.plist "$probe_app"
codesign --verify --strict "$probe_app"
otool -l "$probe_app/MadeiraJITProbe" > ci-logs/jit-probe-load-commands.log
xcrun nm -u "$probe_app/MadeiraJITProbe" > ci-logs/jit-probe-imports.log
codesign -d --entitlements :- "$probe_app" > ci-logs/jit-probe-entitlements.plist
python3 - <<'PY'
import plistlib
from pathlib import Path

entitlements = plistlib.loads(Path('ci-logs/jit-probe-entitlements.plist').read_bytes())
banned = {'dynamic-codesigning', 'com.apple.private.cs.debugger', 'com.apple.private.skip-library-validation'}
assert not banned.intersection(entitlements), 'iOS 15 A12+ banned entitlement in signed probe'
PY
otool -l "$probe_app/MadeiraJITProbe" | awk '/cmd LC_BUILD_VERSION/ { found = 1 } found && /minos/ { if ($2 != "15.6") exit 1; passed = 1; exit } END { if (!passed) exit 1 }'
(cd "$probe_build" && zip -qry "$probe_root/ipa/Madeira-JIT-Probe.ipa" Payload)
echo "JIT probe packaged: ipa/Madeira-JIT-Probe.ipa (TrollStore installation; does not run games)"
