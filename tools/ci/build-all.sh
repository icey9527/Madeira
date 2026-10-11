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
# app-only 快车道（Phase 2 迭代用）: 跳过 FEX/Wine 编译，所有原生静态库用
# 空桩占位，xcodebuild 只验证 Swift/ObjC 编译——链接失败视为编译通过。
# 完整流水线（真实原生链）把 ci.yml 里的 APP_ONLY 改回 '0'。
APP_ONLY="${APP_ONLY:-0}"

LLVM_MINGW_VER="20260421"
LLVM_MINGW_NAME="llvm-mingw-${LLVM_MINGW_VER}-ucrt-macos-universal"
LLVM_MINGW_SHA="bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7"
FREETYPE_TAG="VER-2-13-3"
NPROC="$(sysctl -n hw.ncpu)"
# 提速关键（GPT 复核 2026-10-11）: cmake --build 不给 --parallel 就是串行！
# build/fex-ios/build.sh 里没有 --parallel，FEX 此前一直在单核编译。
# CMAKE_BUILD_PARALLEL_LEVEL 会被 cmake --build（make/ninja）自动采用。
export CMAKE_BUILD_PARALLEL_LEVEL="$NPROC"
# ccache: FEX 的 ENABLE_CCACHE=ON 会 find_program(ccache) 自动接线；
# 缓存目录放在工作区内以便 actions/cache 保存（.gitignore 已排除）。
export CCACHE_DIR="$R/.ccache"
export CCACHE_MAXSIZE=3G
export CCACHE_COMPILERCHECK=content
mkdir -p "$CCACHE_DIR"

step() { printf '\n\033[1;34m===== [ci] %s =====\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ci] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

brew_prefix="$(brew --prefix)"
export HOMEBREW_NO_AUTO_UPDATE=1
export PATH="$brew_prefix/opt/bison/bin:$brew_prefix/opt/flex/bin:$brew_prefix/bin:$PATH"
# 每个阶段都是独立的 GitHub Actions step（新 shell），把工具链选择对齐到
# 系统级 xcode-select 的结果，防止镜像的 DEVELOPER_DIR 指向已删除的 Xcode。
export DEVELOPER_DIR="$(xcode-select -p)"

stage_deps() {
  step "runner 磁盘瘦身（macOS runner 磁盘是最稀缺资源）"
  # 磁盘基线
  echo "  清理前: $(df -h / | tail -1 | awk '{print $4" free / "$2}')"
  # 在用的 Xcode 绝不删: 同时尊重 xcode-select -p 与镜像的 DEVELOPER_DIR
  # （run #9 的教训: 只看 xcode-select 把镜像默认的 Xcode 删了，
  #  后续 xcrun 全部 "SDK iphoneos cannot be located"）。
  keep1="$(xcode-select -p 2>/dev/null || true)"
  keep2="${DEVELOPER_DIR:-}"
  keep_apps=""
  for k in "$keep1" "$keep2"; do
    [ -n "$k" ] || continue
    keep_apps="$keep_apps ${k%/Contents/Developer}"
  done
  for d in /Applications/Xcode*.app; do
    [ -d "$d" ] || continue
    skip=""
    for k in $keep_apps; do
      [ "$(cd "$d" && pwd -P)" = "$(cd "$k" && pwd -P)" ] && skip=1
    done
    if [ -z "$skip" ]; then
      echo "  删除: $d"
      sudo rm -rf "$d"
    fi
  done
  sudo rm -rf /Users/runner/Library/Android/sdk /usr/local/lib/android \
    /usr/local/.ghcup /opt/hostedtoolcache/CodeQL 2>/dev/null || true
  echo "  清理后: $(df -h / | tail -1 | awk '{print $4" free / "$2}')"

  # 清理后必须验证 iOS SDK 可用，坏则尽快失败并给出诊断
  kept="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)"
  [ -n "$kept" ] || die "磁盘清理后 /Applications 下没有任何 Xcode 了"
  sudo xcode-select -s "$kept"
  export DEVELOPER_DIR="$kept"
  echo "  使用 Xcode: $kept"
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
    || die "iphoneos SDK 不可用（xcode-select -p=$(xcode-select -p)）"

  step "构建环境版本记录（image 漂移时用于区分环境问题/代码问题）"
  sw_vers
  echo "xcodebuild: $(xcodebuild -version | head -1)"
  echo "iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"
  echo "clang: $(clang --version | head -1)"
  echo "cmake: $(cmake --version | head -1)"
  echo "bison: $(bison --version 2>/dev/null | head -1)（必须 >= 3.0，且来自 brew 而非系统 2.3）"
  echo "flex: $(flex --version 2>/dev/null | head -1)"

  step "brew 工具 (bison / flex / sevenzip / ccache)"
  brew install bison flex sevenzip ccache

  step "llvm-mingw $LLVM_MINGW_VER 工具链"
  if [ "$APP_ONLY" = 1 ]; then
    echo "  [app-only] 跳过（llvm-mingw 仅原生 PE 交叉编译需要）"
  elif [ ! -x "toolchains/$LLVM_MINGW_NAME/bin/arm64ec-w64-mingw32-clang" ]; then
    mkdir -p toolchains
    curl -fL --retry 3 -o "/tmp/$LLVM_MINGW_NAME.tar.xz" \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VER/$LLVM_MINGW_NAME.tar.xz"
    echo "$LLVM_MINGW_SHA  /tmp/$LLVM_MINGW_NAME.tar.xz" | shasum -a 256 -c -
    tar -xJf "/tmp/$LLVM_MINGW_NAME.tar.xz" -C toolchains/
  fi

  step "VC++ 运行时 DLL (app/Madeira/x86_64-vcruntime)"
  if [ ! -f app/Madeira/x86_64-vcruntime/vcruntime140.dll ]; then
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
    # 按文件名全局收集 12 个运行时 DLL（安装器布局再变也能找到）
    for n in concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll \
             msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll vcamp140.dll \
             vccorlib140.dll vcomp140.dll vcruntime140.dll vcruntime140_1.dll \
             vcruntime140_threads.dll; do
      src="$(find /tmp/vcredist -name "$n" -type f 2>/dev/null | head -1)"
      if [ -n "$src" ]; then
        cp "$src" app/Madeira/x86_64-vcruntime/
      fi
    done
    got="$(find app/Madeira/x86_64-vcruntime -name '*.dll' | wc -l | tr -d ' ')"
    if [ "${got:-0}" -lt 12 ]; then
      # 编译冒烟不需要这些 DLL（它们只是 Windows 游戏的运行时资源，不参与
      # 编译链接）；提取不全就放占位目录让构建继续。真实打包（Phase 4）
      # 按 tools/fetch-vcruntime.md 补齐。
      echo "[deps] 警告: VC 运行时只收集到 ${got:-0}/12 个 —— 用占位目录继续，CI 产物不含 VC 运行时"
      rm -f app/Madeira/x86_64-vcruntime/*.dll
      printf 'CI compile-smoke placeholder — real VC++ runtime DLLs NOT bundled.\nObtain them per tools/fetch-vcruntime.md for real packaging.\n' \
        > app/Madeira/x86_64-vcruntime/CI-PLACEHOLDER.txt
    fi
    ls app/Madeira/x86_64-vcruntime
    if [ -f app/Madeira/x86_64-vcruntime/CI-PLACEHOLDER.txt ]; then
      echo "VCRUNTIME_STATUS=PLACEHOLDER"
    else
      echo "VCRUNTIME_STATUS=COMPLETE"
    fi
  fi

  step "freetype 源码 (research/freetype, shallow)"
  if [ "$APP_ONLY" = 1 ]; then
    echo "  [app-only] 跳过（freetype 仅 win32u unix 侧需要）"
  elif [ -d research/freetype ]; then
    echo "  已存在"
  else
    git clone --depth 1 --branch "$FREETYPE_TAG" \
      https://github.com/freetype/freetype.git research/freetype
  fi
}

stage_toolchains() {
  if [ "$APP_ONLY" = 1 ]; then
    echo "[app-only] 跳过 toolchains（GnuTLS/FFmpeg/freetype 仅原生链需要，app 走空桩）"
    return 0
  fi
  step "GnuTLS / GMP / Nettle (build/gnutls-ios)"
  if [ -f toolchains/gnutls-ios/lib/libgnutls.a ]; then
    echo "  [cache] 命中 toolchains 缓存，跳过"
  else
    bash build/gnutls-ios/build.sh
  fi

  step "FFmpeg, LGPL 极简配置 (build/ffmpeg)"
  if [ -f app/Madeira/libavcodec.a ] && [ -d toolchains/ffmpeg-ios/include ]; then
    echo "  [cache] 命中 toolchains 缓存，跳过"
  else
    bash build/ffmpeg/build.sh
  fi

  step "freetype 静态库 (build/freetype-ios)"
  if [ -f build/freetype-ios/build/libfreetype.a ]; then
    echo "  [cache] 命中 toolchains 缓存，跳过"
  else
    bash build/freetype-ios/build.sh
  fi
}

stage_native() {
  step "浅克隆子模块（跳过 FEX 的三个测试数据仓）"
  # 主仓库子模块: pinned SHA 均为各分支 HEAD（2026-10-11 核实），--depth 1 可用。
  git submodule update --init --depth 1 -- FEX wine dxmt madeira-dock
  # FEX 嵌套子模块: BUILD_TESTING=OFF，三个 *-tests-bins 数据仓（数百 MB）
  # 不参与构建，跳过；其余（fmt/range-v3/rpmalloc/jemalloc/vixl 等）保留。
  git -C FEX submodule update --init --depth 1 \
    $(git -C FEX config -f .gitmodules --name-only | grep -v 'tests-bins' | tr '\n' ' ')
  echo "  磁盘余量: $(df -h / | tail -1 | awk '{print $4" free / "$2}')"

  step "子模块 SHA 校验（gitlink 必须与实际检出一致）"
  for sub in FEX wine dxmt madeira-dock; do
    expected="$(git ls-tree HEAD "$sub" | awk '{print $3}')"
    actual="$(git -C "$sub" rev-parse HEAD)"
    printf '  %-14s expected=%s actual=%s\n' "$sub" "${expected:-MISSING}" "$actual"
    [ "$expected" = "$actual" ] || { echo "::error::Submodule SHA mismatch: $sub"; exit 1; }
  done

  if [ "$APP_ONLY" = 1 ]; then
    echo "[app-only] 跳过 FEX/Wine 原生编译（静态库由 stage_app 统一空桩）"
    return 0
  fi

  step "子模块 SHA 校验（gitlink 必须与实际检出一致）"
  for sub in FEX wine dxmt madeira-dock; do
    expected="$(git ls-tree HEAD "$sub" | awk '{print $3}')"
    actual="$(git -C "$sub" rev-parse HEAD)"
    printf '  %-14s expected=%s actual=%s\n' "$sub" "${expected:-MISSING}" "$actual"
    [ "$expected" = "$actual" ] || { echo "::error::Submodule SHA mismatch: $sub"; exit 1; }
  done

  step "Python 依赖（FEX 的 CPU 检测脚本需要 packaging）"
  # runner 的 Homebrew Python 受 PEP 668 保护；FEX 配置期会调用
  # Scripts/aarch64_fit_native.py（import packaging）。dev 机有此模块，
  # CI 补上。装不上也不致命——下一个补丁会给 STRIP 加引号兜底。
  python3 -m pip install --break-system-packages -q packaging setuptools \
    || python3 -m pip install -q packaging setuptools || true

  step "FEX CMake 兼容补丁（CI 侧，详 HANDOFF『CI 侧补丁』）"
  # 两处 CI 侧补丁：
  # 1) CMAKE_SYSTEM_PROCESSOR 在 -DCMAKE_SYSTEM_NAME=iOS 的 runner 上为空，
  #    FEX 未加引号的引用会解析错位 → "Unsupported processor type"。
  #    补丁：为空时回退 CMAKE_OSX_ARCHITECTURES，并加引号。
  # 2) aarch64_fit_native.py 输出为空时（如依赖缺失），未加引号的
  #    string(STRIP ${AARCH64_CPU} ...) 同样解析错位 → 加引号兜底。
  python3 - <<'PYEOF'
import io
p = 'FEX/CMakeLists.txt'
s = io.open(p, encoding='utf-8').read()
edits = [
    ('string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} processor)',
     'if(NOT CMAKE_SYSTEM_PROCESSOR)\n'
     '  set(CMAKE_SYSTEM_PROCESSOR "${CMAKE_OSX_ARCHITECTURES}")\n'
     'endif()\n'
     'string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" processor)'),
    ('string(STRIP ${AARCH64_CPU} AARCH64_CPU)',
     'string(STRIP "${AARCH64_CPU}" AARCH64_CPU)'),
]
for old, new in edits:
    if old in s:
        s = s.replace(old, new, 1)
        print('[patch] applied:', old.splitlines()[0])
    elif new in s:
        print('[patch] already applied:', new.splitlines()[0])
    else:
        raise SystemExit('[patch] pattern not found: %r — FEX 上游变了？核对 HANDOFF CI 侧补丁' % old[:48])
io.open(p, 'w', encoding='utf-8').write(s)
PYEOF

  step "FEXCore (build/fex-ios, cmake iOS)"
  bash build/fex-ios/build.sh
  missing=""
  for lib in libFEXCore.a libFEXCore_Base.a libJemallocLibs.a; do
    [ -f "FEX/build-ios/FEXCore/Source/$lib" ] || missing="${missing:-} $lib"
  done
  for lib in libfmt.a libcephes_128bit.a libxxhash.a libsoftfloat_3e.a; do
    find FEX/build-ios -name "$lib" -print -quit | grep -q . || missing="${missing:-} $lib"
  done
  if [ -n "${missing:-}" ]; then
    step "FEX 全量构建（上面还缺:${missing:-}）"
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
  if [ "$APP_ONLY" = 1 ]; then
    echo "[app-only] 跳过 wine（libntdll_unix/libwineserver/libwin32u_unix 用空桩）"
    return 0
  fi
  step "工具链版本确认（configure 实际使用的 bison/flex 必须来自 brew）"
  command -v bison && bison --version | head -1
  command -v flex && flex --version | head -1

  step "wine configure: build-macos (config.h + widl 头文件)"
  if [ ! -f wine/build-macos/Makefile ]; then
    mkdir -p wine/build-macos
    (cd wine/build-macos && ../configure --disable-tests --without-x)
  fi
  make -C wine/build-macos -j "$NPROC" include
  hdrs_m="$(find wine/build-macos/include -name '*.h' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  build-macos 生成头文件数: $hdrs_m"
  [ -f wine/build-macos/include/config.h ] || { echo "::error::build-macos/include/config.h 缺失"; exit 1; }
  find wine/build-macos/include -name 'mfobjects.h' -o -name 'mftransform.h' 2>/dev/null \
    | head -2 | grep . || echo "  [warn] ntapi 的 widl 头（mfobjects/mftransform）未找到——ntdll-unix 编译会再暴露"

  step "wine configure: build-arm64ec (dwrite 的 widl 头文件)"
  export PATH="$R/toolchains/$LLVM_MINGW_NAME/bin:$PATH"
  if [ ! -f wine/build-arm64ec/config.status ]; then
    mkdir -p wine/build-arm64ec
    (cd wine/build-arm64ec && \
      ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
  fi
  make -C wine/build-arm64ec -j "$NPROC" include
  hdrs_x="$(find wine/build-arm64ec/include -name '*.h' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  build-arm64ec 生成头文件数: $hdrs_x"
  [ -f wine/build-arm64ec/include/dwrite.h ] \
    || echo "  [warn] build-arm64ec/include/dwrite.h 未生成——dwrite_unixlib 编译会再暴露"

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

stub_all_native_libs() {
  # app-only 冒烟: 把 App 链接的、由原生链产出的静态库全部空桩占位。
  # 路径与 app/Madeira.xcodeproj 的 PBXFileReference 一一对应。
  local sd="$R/.ci-stubs"
  mkdir -p "$sd"
  printf 'int __madeira_ci_stub;\n' > "$sd/stub.c"
  xcrun -sdk iphoneos clang -arch arm64 -c "$sd/stub.c" -o "$sd/stub.o"
  local libs=(
    "FEX/build-ios/FEXCore/Source/libFEXCore.a"
    "FEX/build-ios/FEXCore/Source/libFEXCore_Base.a"
    "FEX/build-ios/FEXCore/Source/libJemallocLibs.a"
    "FEX/build-ios/External/fmt/libfmt.a"
    "FEX/build-ios/External/cephes/libcephes_128bit.a"
    "FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a"
    "FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a"
    "app/Madeira/libwineserver.a"
    "app/Madeira/libntdll_unix.a"
    "app/Madeira/libwin32u_unix.a"
    "app/Madeira/libdxmt_combined.a"
    "app/Madeira/libavformat.a"
    "app/Madeira/libavcodec.a"
    "app/Madeira/libswresample.a"
    "app/Madeira/libavutil.a"
  )
  local p
  for p in "${libs[@]}"; do
    if [ ! -s "$R/$p" ]; then
      mkdir -p "$(dirname "$R/$p")"
      ar rcs "$R/$p" "$sd/stub.o"
      echo "  [stub] $p"
    fi
  done
}

stage_app() {
  step "磁盘保护线（app 构建前必须 >= 30 GiB 可用）"
  free_kb="$(df -Pk / | awk 'NR==2{print $4}')"
  echo "  可用: $(( ${free_kb:-0} / 1024 / 1024 )) GiB"
  if [ "${free_kb:-0}" -lt $((30 * 1024 * 1024)) ]; then
    echo "::error::app 构建前磁盘可用不足 30 GiB（run #8 的死法，不重演）"
    df -h /
    exit 1
  fi

  if [ "$APP_ONLY" = 1 ]; then
    echo "BUILD_PURPOSE=COMPILE_ONLY（原生库空桩：链接失败=编译通过）"
    stub_all_native_libs
  else
    echo "DXMT_STATUS=STUB | BUILD_PURPOSE=LINK_SMOKE_TEST_ONLY"
    if [ ! -s app/Madeira/libdxmt_combined.a ]; then
      printf 'int __madeira_ci_dxmt_placeholder = 0;\n' > /tmp/dxmt_stub.c
      xcrun -sdk iphoneos clang -arch arm64 -c /tmp/dxmt_stub.c -o /tmp/dxmt_stub.o
      ar rcs app/Madeira/libdxmt_combined.a /tmp/dxmt_stub.o
    fi
    step "DXMT 占位符号审计（确认其余部分不静态引用 dxmt）"
    if xcrun -sdk iphoneos nm -u app/Madeira/libntdll_unix.a 2>/dev/null | c++filt \
        | grep -Ei 'dxmt|winemetal|airconv' | head -20; then
      echo "  ^ 上述符号被静态引用 —— 空库占位会在链接期暴露（属预期，按报错继续）"
    else
      echo "  libntdll_unix.a 无静态 dxmt 引用 —— 空库占位预期可链接通过"
    fi
  fi

  DD="${RUNNER_TEMP:-$R/ci-DD}/Madeira-DD"
  step "xcodebuild 编译冒烟 (Debug, 未签名, DerivedData=$DD)"
  rc=0
  xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build > "$LOGDIR/xcodebuild.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$APP_ONLY" = 1 ] && grep -qE "Undefined symbol[s]?|ld: symbol|error: linker command" "$LOGDIR/xcodebuild.log"; then
      echo "======== COMPILE-ONLY PASS ========"
      echo "Swift/ObjC 编译全部通过；仅链接失败（app-only 空桩库的预期结果）。未定义符号示例："
      grep -B1 -A4 "Undefined symbol" "$LOGDIR/xcodebuild.log" | head -24 || true
      exit 0
    fi
    echo "======== xcodebuild 失败，末 100 行 ========"
    tail -n 100 "$LOGDIR/xcodebuild.log"
    exit 1
  fi
  echo "======== APP BUILD OK ========"
  tail -n 5 "$LOGDIR/xcodebuild.log"

  step "构建产物校验（部署目标 / MetalFX 链接形态）"
  APP_BUILT="$DD/Build/Products/Debug-iphoneos/Madeira.app"
  [ -d "$APP_BUILT" ] || { ls "$DD/Build/Products" 2>/dev/null || true; die "构建成功但找不到 Madeira.app"; }
  echo "  App  MinimumOSVersion = $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_BUILT/Info.plist" 2>/dev/null)"
  if [ -f "$APP_BUILT/PlugIns/MadeiraJITHelper.appex/Info.plist" ]; then
    echo "  JITHelper MinimumOSVersion = $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_BUILT/PlugIns/MadeiraJITHelper.appex/Info.plist")"
  fi
  echo "  MetalFX 链接形态（17.0 基线应为强链接；Phase 2 降到 15.6 必须改 Weak）:"
  otool -L "$APP_BUILT/Madeira" | grep -i metalfx || echo "  [warn] 主二进制动态依赖中未见 MetalFX"
}

# ---------- main ----------
# 关键实现说明: 阶段函数绝不能放进 `if ! ... | tee` 这类条件/管道上下文里调用
# —— bash 在那里会关闭 set -e，函数内部任何失败都会被静默吞掉（这正是
# run #1–#5 各种诡异行为的根源）。这里用"普通调用 + EXIT trap 写失败摘要"。
STAGE="${1:-}"
case "$STAGE" in
  deps|toolchains|native|wine|app) ;;
  *) die "用法: tools/ci/build-all.sh <deps|toolchains|native|wine|app>" ;;
esac

summary_fail() {
  {
    echo "## ❌ port-ci — stage \`$STAGE\` FAILED"
    echo
    echo '```text'
    tail -n 150 "$LOGDIR/$STAGE.log" 2>/dev/null || true
    echo '```'
    local f
    find "$R/build" "$R/FEX" "$R/wine" "$R/app" -name '*.log' \
      -newer "$LOGDIR/.stamp" 2>/dev/null | head -20 | while read -r f; do
      echo
      echo "#### ${f#"$R"/}（末 40 行）"
      echo '```text'
      tail -n 40 "$f" 2>/dev/null
      echo '```'
    done
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
  echo "======== 失败: stage $STAGE （ci-logs/$STAGE.log 末 80 行如下） ========"
  tail -n 80 "$LOGDIR/$STAGE.log" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    sleep 1   # 给 tee 一点时间把尾部刷进日志文件
    summary_fail || true
  fi
  exit "$rc"
}
trap cleanup EXIT

touch "$LOGDIR/.stamp"
step "stage: $STAGE （实时流式输出，同步写入 ci-logs/$STAGE.log）"
# 实时流式: 函数不在管道/if 条件里调用（保住 set -e），输出经进程替换
# 同时进控制台与日志文件——网页上能看到编译进度实时滚动。
"stage_$STAGE" > >(tee "$LOGDIR/$STAGE.log") 2>&1
step "stage: $STAGE OK"
