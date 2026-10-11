#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLVM_REVISION=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a
LLVM_ROOT="$REPO_ROOT/toolchains/llvm-project"
HOST_BUILD="$REPO_ROOT/toolchains/llvm-host-build"
IOS_BUILD="$REPO_ROOT/toolchains/llvm-ios-build"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
BUILD_ID="$LLVM_REVISION/$DEPLOYMENT_TARGET/$(xcodebuild -version | tr '\n' ' ')/$(shasum -a 256 < "${BASH_SOURCE[0]}" | cut -c1-64)"

if [ -f "$IOS_BUILD/.madeira-complete" ] \
    && [ "$(cat "$IOS_BUILD/.madeira-complete")" = "$BUILD_ID" ] \
    && [ -s "$IOS_BUILD/lib/libLLVMPasses.a" ] \
    && [ -s "$IOS_BUILD/lib/libLLVMBitWriter.a" ] \
    && [ -s "$IOS_BUILD/lib/libLLVMLinker.a" ] \
    && [ -s "$LLVM_ROOT/llvm/include/llvm/IR/Module.h" ]; then
    echo "LLVM iOS: completed build cache hit"
    exit 0
fi

if [ ! -d "$LLVM_ROOT/.git" ]; then
    git init "$LLVM_ROOT"
    git -C "$LLVM_ROOT" remote add origin https://github.com/llvm/llvm-project.git
    git -C "$LLVM_ROOT" config remote.origin.promisor true
    git -C "$LLVM_ROOT" config remote.origin.partialclonefilter blob:none
    git -C "$LLVM_ROOT" sparse-checkout init --cone
    git -C "$LLVM_ROOT" sparse-checkout set llvm cmake third-party
fi
if [ "$(git -C "$LLVM_ROOT" rev-parse HEAD 2>/dev/null || true)" != "$LLVM_REVISION" ]; then
    git -C "$LLVM_ROOT" fetch --depth 1 --filter=blob:none origin "$LLVM_REVISION"
    git -C "$LLVM_ROOT" checkout --detach FETCH_HEAD
fi
[ "$(git -C "$LLVM_ROOT" rev-parse HEAD)" = "$LLVM_REVISION" ]

python3 - "$LLVM_ROOT/llvm/cmake/modules/AddLLVM.cmake" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
text = source.read_text()
original = 'if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin")'
patched = 'if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin|iOS")'
if original not in text and patched not in text:
    raise SystemExit("LLVM Darwin linker rule changed")
source.write_text(text.replace(original, patched))
PY

MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
HOST_TARGET="$(uname -m)-apple-macos$(sw_vers -productVersion)"
HOST_ENV=(env -u IPHONEOS_DEPLOYMENT_TARGET SDKROOT="$MAC_SDK")
COMMON_OPTIONS=(
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS=
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF
    -DLLVM_ENABLE_RTTI=OFF -DLLVM_ENABLE_EH=OFF
)
PARALLEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(sysctl -n hw.ncpu)}"

"${HOST_ENV[@]}" cmake -S "$LLVM_ROOT/llvm" -B "$HOST_BUILD" "${COMMON_OPTIONS[@]}" \
    -DCMAKE_C_COMPILER="$(xcrun --sdk macosx -f clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --sdk macosx -f clang++)" \
    -DCMAKE_C_FLAGS="-target $HOST_TARGET -isysroot $MAC_SDK" \
    -DCMAKE_CXX_FLAGS="-target $HOST_TARGET -isysroot $MAC_SDK" \
    -DCMAKE_OSX_SYSROOT="$MAC_SDK" -DLLVM_BUILD_TOOLS=OFF
"${HOST_ENV[@]}" cmake --build "$HOST_BUILD" --target llvm-tblgen --parallel "$PARALLEL"
"$HOST_BUILD/bin/llvm-tblgen" --version

cmake -S "$LLVM_ROOT/llvm" -B "$IOS_BUILD" "${COMMON_OPTIONS[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_C_COMPILER="$(xcrun --sdk iphoneos -f clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --sdk iphoneos -f clang++)" \
    -DLLVM_HOST_TRIPLE="arm64-apple-ios$DEPLOYMENT_TARGET" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="arm64-apple-ios$DEPLOYMENT_TARGET" \
    -DLLVM_TABLEGEN="$HOST_BUILD/bin/llvm-tblgen" \
    -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_UTILS=OFF \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
cmake --build "$IOS_BUILD" --target LLVMBitWriter LLVMPasses LLVMLinker --parallel "$PARALLEL"
printf '%s\n' "$BUILD_ID" > "$IOS_BUILD/.madeira-complete"
