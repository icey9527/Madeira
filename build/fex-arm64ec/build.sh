#!/bin/bash
# Configure (first time) and build the ARM64EC FEX module (libarm64ecfex.dll,
# shipped as xtajit64.dll), the CPU backend Wine's arm64ec ntdll loads for
# 64-bit x86 programs.
#
# The option set is upstream's build/fex-arm64ec/build.sh -- it is the
# configuration upstream pins FEX, wine and dxmt together and tests -- plus the
# hermetic-build fixes this port needs on a clean CI runner:
#   * an explicit MINGW_TRIPLE: toolchain_mingw.cmake ships none, so without it
#     the compiler resolves to "-clang";
#   * a re-rooted CMAKE_FIND_ROOT_PATH with the three *_FIND_PACKAGE off by
#     name: the toolchain sets FIND_ROOT_PATH_MODE_PACKAGE=ONLY, which with an
#     empty root path has no effect, and find_package() then picks up a host
#     Homebrew fmt/range-v3 whose IMPORTED_IMPLIB a PE target cannot use;
#   * the iOS workflow's IPHONEOS_DEPLOYMENT_TARGET/SDKROOT and CC/CXX are
#     unset: this half is a macOS-host PE cross build and must not inherit the
#     iOS ones;
#   * --parallel, because cmake --build without it is serial.
# MINGW_TRIPLE / TUNE_CPU notes are upstream's: the toolchain file has no
# default triple, and TUNE_CPU=native probes the build host and aborts the
# configure on macOS. A tree configured before keeps its cached options, so
# remove $B to reconfigure with these.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
unset IPHONEOS_DEPLOYMENT_TARGET SDKROOT CC CXX
B="$R/FEX/build-arm64ec"
TOOLCHAIN="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DTUNE_CPU=cortex-a78 \
        -DCMAKE_FIND_ROOT_PATH="$TOOLCHAIN/arm64ec-w64-mingw32" \
        -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
        -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST=1 \
        -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST=1 -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST=1 \
        -DENABLE_LTO=OFF -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON -DENABLE_OFFLINE_RUNTIME=ON \
        -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF
fi
cmake --build "$B" --target arm64ecfex --parallel "${JOBS:-$(sysctl -n hw.ncpu)}"
cp "$B/Bin/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll" && ls -l "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
