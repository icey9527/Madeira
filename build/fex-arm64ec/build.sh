#!/bin/bash
# Configure (first time) and build the ARM64EC FEX module (libarm64ecfex.dll,
# shipped as xtajit64.dll), the CPU backend Wine's arm64ec ntdll loads for
# 64-bit x86 programs. See docs/BUILDING.md and docs/STATUS-AND-PLAN.md.
#
# The options are the iOS host build's, mirroring build/fex-wow64/build.sh.
# FEX_IOS_HOST_BUILD switches Common/CRT to CRT_iOS.cpp and turns on the
# module's #ifdef FEX_IOS_HOST code: JIT-pool alias translation, TSD-slot TEB
# reads, and the ThreadInit dispatcher patching.  It does NOT turn on
# ENABLE_GUEST_WINDOW -- FEX/CMakeLists.txt refuses that for ARM64EC, and the
# 64-bit guest keeps its own VA layout.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
# The workflow exports IPHONEOS_DEPLOYMENT_TARGET/SDKROOT for the iOS half; the
# PE cross build here is a macOS-host build and must not inherit them.
unset IPHONEOS_DEPLOYMENT_TARGET SDKROOT CC CXX
B="$R/FEX/build-arm64ec"
TOOLCHAIN="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
# The toolchain file defaults MINGW_TRIPLE to the empty string, so the triple
# has to be passed explicitly or the compiler becomes "-clang".  arm64ec needs
# the ARM64EC-aware driver prefix, which is why this is not the aarch64 default.
# CMAKE_FIND_ROOT_PATH is re-rooted at the MinGW sysroot for the same reason as
# in build/fex-wow64/build.sh: with an empty root path the
# CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY in the toolchain file has no effect and
# find_package() picks up a host Homebrew fmt/range-v3 instead.
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
        -DCMAKE_FIND_ROOT_PATH="$TOOLCHAIN/arm64ec-w64-mingw32" \
        -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
        -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
        -DENABLE_LTO=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
        -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DTUNE_ARCH=generic -DTUNE_CPU=none \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SHARED_LINKER_FLAGS="-static -static-libgcc -static-libstdc++ -Wl,--file-alignment=4096,/mllvm:-align-loops=1,-Map,$B/arm64ecfex.map"
fi
cmake --build "$B" --target arm64ecfex --parallel "${JOBS:-$(sysctl -n hw.ncpu)}"
cp "$B/Bin/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll" && ls -l "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
