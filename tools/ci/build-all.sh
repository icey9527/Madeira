#!/usr/bin/env bash
# tools/ci/build-all.sh — GitHub Actions (macos-26) 分阶段构建脚本
#
# 用法: tools/ci/build-all.sh <deps|toolchains|native|wine|app>
#
# 目的: 在干净克隆上自动准备全部构建输入，并编译 Madeira（Xcode, Debug,
# 未签名），作为 port/ios15.6 分支「可编译性」的云端冒烟验证。
# 分支纪律: 本 CI 只允许跑在 port/ios15.6（workflow 里有 guard）。
#
# CI 与本地开发流程的差异（此处引导，待日后回馈仓库）:
#  1. app/Madeira/libwineserver.a 基础库不在仓库 —— CI 首次用 wine/server/*.c
#     全量编译引导，再由 build/wineserver/build.sh 替换其中的补丁对象。
#  2. app/Madeira/libdxmt_combined.a 的真实构建需要自建 iOS 版 LLVM（数小时）
#     —— CI 先放空库占位，先验证 App 层的编译与链接；Phase 4 再补真实构建。
#  3. llvm-mingw 工具链按 docs/BUILDING.md 的版本与 SHA256 固定下载。
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$R"
LOGDIR="$R/ci-logs"
mkdir -p "$LOGDIR"

LLVM_MINGW_VER="20260421"
LLVM_MINGW_NAME="llvm-mingw-${LLVM_MINGW_VER}-ucrt-macos-universal"
LLVM_MINGW_SHA="bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7"
FREETYPE_TAG="VER-2-13-3"
NPROC="$(sysctl -n hw.ncpu)"

step() { printf '\n\033[1;34m===== [ci] %s =====\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ci] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

brew_prefix="$(brew --prefix)"
export HOMEBREW_NO_AUTO_UPDATE=1
export PATH="$brew_prefix/opt/bison/bin:$brew_prefix/opt/flex/bin:$brew_prefix/bin:$PATH"

stage_deps() {
  step "brew 工具 (bison / flex / sevenzip)"
  brew install bison flex sevenzip

  step "llvm-mingw $LLVM_MINGW_VER 工具链"
  if [ ! -x "toolchains/$LLVM_MINGW_NAME/bin/arm64ec-w64-mingw32-clang" ]; then
    mkdir -p toolchains
    curl -fL --retry 3 -o "/tmp/$LLVM_MINGW_NAME.tar.xz" \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VER/$LLVM_MINGW_NAME.tar.xz"
    echo "$LLVM_MINGW_SHA  /tmp/$LLVM_MINGW_NAME.tar.xz" | shasum -a 256 -c -
    tar -xJf "/tmp/$LLVM_MINGW_NAME.tar.xz" -C toolchains/
  fi

  step "VC++ 运行时 DLL (app/Madeira/x86_64-vcruntime)"
  if [ ! -f app/Madeira/x86_64-vcruntime/vcruntime140.dll ]; then
    need="concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll msvcp140_atomic_wait.dll \
msvcp140_codecvt_ids.dll vcamp140.dll vccorlib140.dll vcomp140.dll \
vcruntime140.dll vcruntime140_1.dll vcruntime140_threads.dll"
    curl -fL --retry 3 -o /tmp/VC_redist.x64.exe "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    rm -rf /tmp/vcredist && mkdir -p /tmp/vcredist
    7zz x /tmp/VC_redist.x64.exe -o/tmp/vcredist >/dev/null
    # 新版安装器解出的是 u28/u17 这类无扩展名容器，逐个再展开一层
    for f in /tmp/vcredist/u* /tmp/vcredist/*.bin; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in *.exe) continue ;; esac
      7zz x "$f" -o"/tmp/vcredist/x_$(basename "$f")" >/dev/null 2>&1 || true
    done
    mkdir -p app/Madeira/x86_64-vcruntime
    # 全局按文件名收 12 个 DLL（布局再变也能找到）
    for n in $need; do
      src="$(find /tmp/vcredist -name "$n" -type f | head -1)"
      [ -n "$src" ] && cp "$src" app/Madeira/x86_64-vcruntime/
    done
    miss=""
    for n in $need; do
      [ -f "app/Madeira/x86_64-vcruntime/$n" ] || miss="$miss $n"
    done
    if [ -n "$miss" ]; then
      # 编译冒烟不需要这些 DLL（它们只是游戏的运行时资源，不参与链接），
      # 提取不全就放占位目录让构建继续；真实打包（Phase 4）再按
      # tools/fetch-vcruntime.md 补齐。
      echo "[deps] 警告: VC 运行时提取不全（缺:$miss）—— 用占位目录继续，CI 产物不含 VC 运行时"
      rm -f app/Madeira/x86_64-vcruntime/*.dll
      printf 'CI compile-smoke placeholder — real VC++ runtime DLLs NOT bundled.\nObtain them per tools/fetch-vcruntime.md for real packaging.\n' \
        > app/Madeira/x86_64-vcruntime/CI-PLACEHOLDER.txt
    fi
    ls app/Madeira/x86_64-vcruntime
  fi

  step "freetype 源码 (research/freetype, shallow)"
  [ -d research/freetype ] || \
    git clone --depth 1 --branch "$FREETYPE_TAG" \
      https://github.com/freetype/freetype.git research/freetype
}

stage_toolchains() {
  step "GnuTLS / GMP / Nettle (build/gnutls-ios)"
  bash build/gnutls-ios/build.sh

  step "FFmpeg, LGPL 极简配置 (build/ffmpeg)"
  bash build/ffmpeg/build.sh

  step "freetype 静态库 (build/freetype-ios)"
  bash build/freetype-ios/build.sh
}

stage_native() {
  step "FEXCore (build/fex-ios, cmake iOS)"
  bash build/fex-ios/build.sh
  missing=""
  for lib in libFEXCore.a libFEXCore_Base.a libJemallocLibs.a; do
    [ -f "FEX/build-ios/FEXCore/Source/$lib" ] || missing="$missing $lib"
  done
  for lib in libfmt.a libcephes_128bit.a libxxhash.a libsoftfloat_3e.a; do
    find FEX/build-ios -name "$lib" -print -quit | grep -q . || missing="$missing $lib"
  done
  if [ -n "$missing" ]; then
    step "FEX 全量构建（上面还缺:$missing）"
    cmake --build FEX/build-ios -j "$NPROC"
  fi
}

bootstrap_wineserver_base() {
  # CI 引导: 仓库不含基础版 app/Madeira/libwineserver.a。用与
  # build/wineserver/build.sh 完全相同的编译参数把 wine/server/*.c 全量
  # 编译成基础库；随后的官方脚本会替换其中的补丁对象。
  local SDK WINE_SRC OBJ name src
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  WINE_SRC="$R/wine"
  OBJ="build/wineserver/obj"
  mkdir -p "$OBJ"
  echo "  [bootstrap] 全量编译 wine/server/*.c -> 基础 libwineserver.a"
  for src in "$WINE_SRC"/server/*.c; do
    name="$(basename "$src" .c)"
    xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
      -miphoneos-version-min=17.0 -O2 -fPIC \
      -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine" \
      -I"$WINE_SRC/build-macos/include" \
      -I"$R/build/wineserver" -I"$WINE_SRC/server" \
      -I"$R/build/ntdll-unix/shims" -I"$R/build/madsync" -DHAVE_LINUX_NTSYNC_H=1 \
      -include "$R/build/wineserver/config_ios.h" -include stdarg.h \
      -include "$R/build/wineserver/unicode_fix.h" \
      -include "$R/build/wineserver/wineserver_ios_kill.h" \
      -DBINDIR='"/usr/local/bin"' -DDATADIR='"/usr/local/share"' \
      -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main \
      -Wno-implicit-function-declaration \
      -c "$src" -o "$OBJ/base-$name.o" 2>"$OBJ/base-$name.err" \
      || { echo "  [bootstrap] 失败: $name"; cat "$OBJ/base-$name.err"; exit 1; }
  done
  ar rcs "$OBJ/libwineserver.a" "$OBJ"/base-*.o
  cp "$OBJ/libwineserver.a" app/Madeira/libwineserver.a
}

stage_wine() {
  step "wine configure: build-macos (config.h + widl 头文件)"
  if [ ! -f wine/build-macos/Makefile ]; then
    mkdir -p wine/build-macos
    (cd wine/build-macos && ../configure --disable-tests --without-x)
  fi
  make -C wine/build-macos -j "$NPROC" include

  step "wine configure: build-arm64ec (dwrite 的 widl 头文件)"
  export PATH="$R/toolchains/$LLVM_MINGW_NAME/bin:$PATH"
  if [ ! -f wine/build-arm64ec/config.status ]; then
    mkdir -p wine/build-arm64ec
    (cd wine/build-arm64ec && \
      ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
  fi
  make -C wine/build-arm64ec -j "$NPROC" include

  step "libntdll_unix.a (build/ntdll-unix)"
  bash build/ntdll-unix/build.sh

  step "libwineserver.a (build/wineserver, 含 CI 引导)"
  if [ ! -f app/Madeira/libwineserver.a ]; then
    bootstrap_wineserver_base
  fi
  bash build/wineserver/build.sh all

  step "libwin32u_unix.a (build/win32u-unix)"
  bash build/win32u-unix/build.sh
}

stage_app() {
  step "libdxmt_combined.a 占位（真实构建需 iOS LLVM，Phase 4 再做）"
  if [ ! -s app/Madeira/libdxmt_combined.a ]; then
    printf 'int __madeira_ci_dxmt_placeholder = 0;\n' > /tmp/dxmt_stub.c
    xcrun -sdk iphoneos clang -arch arm64 -c /tmp/dxmt_stub.c -o /tmp/dxmt_stub.o
    ar rcs app/Madeira/libdxmt_combined.a /tmp/dxmt_stub.o
  fi

  step "xcodebuild 编译冒烟 (Debug, 未签名)"
  set -o pipefail
  if ! xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
        -configuration Debug -destination 'generic/platform=iOS' \
        CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
        build 2>&1 | tee "$LOGDIR/xcodebuild.log"; then
    echo "======== xcodebuild 失败，末 150 行 ========"
    tail -n 150 "$LOGDIR/xcodebuild.log"
    exit 1
  fi
  echo "======== APP BUILD OK ========"
}

# run_stage — 执行阶段并把失败证据写进 $GITHUB_STEP_SUMMARY（运行页可直接
# 渲染，无需登录），同时 tee 全量日志到 ci-logs/<stage>.log 供 artifact 上传。
run_stage() {
  local s="$1"
  local log="$LOGDIR/$s.log"
  touch "$LOGDIR/.stamp"
  step "stage: $s"
  if ! "stage_$s" 2>&1 | tee "$log"; then
    {
      echo "## ❌ port-ci — stage \`$s\` FAILED"
      echo
      echo '```text'
      tail -n 120 "$log"
      echo '```'
      local f
      find "$R/build" -name '*.log' -newer "$LOGDIR/.stamp" 2>/dev/null | head -20 | while read -r f; do
        echo
        echo "#### ${f#"$R"/}（末 40 行）"
        echo '```text'
        tail -n 40 "$f"
        echo '```'
      done
    } >> "${GITHUB_STEP_SUMMARY:-$LOGDIR/summary-fallback.md}"
    tail -n 120 "$log"
    exit 1
  fi
}

case "${1:-}" in
  deps)       run_stage deps ;;
  toolchains) run_stage toolchains ;;
  native)     run_stage native ;;
  wine)       run_stage wine ;;
  app)        run_stage app ;;
  *) die "用法: tools/ci/build-all.sh <deps|toolchains|native|wine|app>" ;;
esac
