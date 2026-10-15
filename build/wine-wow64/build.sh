#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$(brew --prefix)/opt/bison/bin:$(brew --prefix)/opt/flex/bin:$PATH"
unset IPHONEOS_DEPLOYMENT_TARGET
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
MAC_TARGET="$(uname -m)-apple-macos$(sw_vers -productVersion)"
export CC="$(xcrun --sdk macosx -f clang) -target $MAC_TARGET -isysroot $SDKROOT"
export CXX="$(xcrun --sdk macosx -f clang++) -target $MAC_TARGET -isysroot $SDKROOT"
B="$R/build/wine-wow64/output"
SOURCE="$R/build/wine-wow64/source"
python3 "$R/build/wine-wow64/prepare.py" "$R/wine" "$SOURCE"
mkdir -p "$B"
if [ ! -f "$B/config.status" ]; then
    (cd "$B" && "$SOURCE/configure" --enable-win64 --enable-archs=aarch64 --without-x --without-vulkan --disable-tests)
fi
make -C "$B" -j"${JOBS:-$(sysctl -n hw.ncpu)}" dlls/ntdll/aarch64-windows/ntdll.dll
cp "$B/dlls/ntdll/aarch64-windows/ntdll.dll" "$R/app/Madeira/aarch64-windows/ntdll.dll"
"$TC/aarch64-w64-mingw32-strip" --strip-debug "$R/app/Madeira/aarch64-windows/ntdll.dll"
python3 "$R/tools/ci/verify-wow64.py" "$R/app/Madeira"
