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
#  2. DXMT 所需的 iOS LLVM 由独立阶段构建并缓存，完整模式不使用占位库。
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

# 计时埋点（Claude 建议）: 关键子步骤秒级计时，汇总进运行页 Summary
_tic_ts=0
tic() { _tic_ts=$(date +%s); }
toc() { local now; now=$(date +%s); local line="TIMING ${1}: $((now - _tic_ts))s"; echo "$line"; if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$line" >> "$GITHUB_STEP_SUMMARY" || true; fi; }

brew_prefix="$(brew --prefix)"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1
export PATH="$brew_prefix/opt/bison/bin:$brew_prefix/opt/flex/bin:$brew_prefix/bin:$PATH"
# 每个阶段都是独立的 GitHub Actions step（新 shell），把工具链选择对齐到
# 系统级 xcode-select 的结果，防止镜像的 DEVELOPER_DIR 指向已删除的 Xcode。
export DEVELOPER_DIR="$(xcode-select -p)"

stage_deps() {
  local free_kb
  free_kb="$(df -Pk / | awk 'NR==2{print $4}')"
  echo "runner 空闲磁盘: $((free_kb / 1024 / 1024)) GiB"
  if [ "$APP_ONLY" != 1 ] && [ "$free_kb" -lt $((80 * 1024 * 1024)) ]; then
    step "磁盘不足 80 GiB，清理未使用的 Xcode"
    tic
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
    echo "  清理前: $(df -h / | tail -1 | awk '{print $4" free / "$2}')"
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
    [ -d "$DEVELOPER_DIR" ] || die "磁盘清理后当前 Xcode 路径不存在"
    echo "  使用 Xcode: $DEVELOPER_DIR"
    toc "deps:disk-cleanup"
  else
    echo "跳过磁盘清理（app-only 或空闲磁盘 >= 80 GiB）"
  fi
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
    || die "iphoneos SDK 不可用（xcode-select -p=$(xcode-select -p)）"

  step "构建环境版本记录（image 漂移时用于区分环境问题/代码问题）"
  sw_vers
  xcodebuild -version
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "xcode=$(xcodebuild -version | tr '\n' '-')" >> "$GITHUB_OUTPUT"
  fi
  echo "iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"
  echo "clang: $(clang --version | head -1)"
  echo "cmake: $(cmake --version | head -1)"
  echo "bison: $(bison --version 2>/dev/null | head -1)（必须 >= 3.0，且来自 brew 而非系统 2.3）"
  echo "flex: $(flex --version 2>/dev/null | head -1)"

  step "Metal 工具链准备（Xcode 26 拆分为独立组件；App 的 .metal 编译必需）"
  if xcrun --sdk iphoneos metal --version >/dev/null 2>&1; then
    echo "Metal 工具链已可用，跳过下载"
  else
    tic; xcodebuild -downloadComponent MetalToolchain; toc "deps:metal-toolchain"
    xcrun --sdk iphoneos metal --version
  fi

  step "brew 工具 (bison / flex / sevenzip / ccache)"
  if [ "$APP_ONLY" = 1 ]; then
    echo "  [app-only] 跳过（VC++ 运行时资源不参与源码编译）"
  else
    tic; brew install bison flex sevenzip ccache meson ninja; toc "deps:brew-install"
  fi

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

  if [ "$APP_ONLY" != 1 ] && [ ! -x "toolchains/$LLVM_MINGW_NAME/bin/llvm-objcopy" ] \
      && [ ! -x "$brew_prefix/opt/llvm/bin/llvm-objcopy" ]; then
    brew install llvm
  fi

  step "VC++ 运行时 DLL (app/Madeira/x86_64-vcruntime)"
  if [ "$APP_ONLY" = 1 ]; then
    mkdir -p app/Madeira/x86_64-vcruntime
    printf 'Compile-only resource placeholder; not a runnable App.\n' > app/Madeira/x86_64-vcruntime/CI-PLACEHOLDER.txt
    echo "VCRUNTIME_STATUS=COMPILE_ONLY_PLACEHOLDER"
  elif [ ! -f app/Madeira/x86_64-vcruntime/vcruntime140.dll ]; then
    tic
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
    toc "deps:vcredist"
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
    tic
    bash build/gnutls-ios/build.sh
    toc "toolchains:gnutls-stack"
  fi
  for library in gnutls hogweed nettle gmp; do
    [ -s "toolchains/gnutls-ios/lib/lib$library.a" ] || die "GnuTLS 缓存不完整: lib$library.a"
    cp "toolchains/gnutls-ios/lib/lib$library.a" app/Madeira/
  done

  step "FFmpeg, LGPL 极简配置 (build/ffmpeg)"
  if [ -f app/Madeira/libavcodec.a ] && [ -d toolchains/ffmpeg-ios/include ]; then
    echo "  [cache] 命中 toolchains 缓存，跳过"
  else
    tic
    bash build/ffmpeg/build.sh
    toc "toolchains:ffmpeg"
  fi

  step "freetype 静态库 (build/freetype-ios)"
  if [ -f build/freetype-ios/build/libfreetype.a ]; then
    echo "  [cache] 命中 toolchains 缓存，跳过"
  else
    tic
    bash build/freetype-ios/build.sh
    toc "toolchains:freetype"
  fi
}

stage_native() {
  step "浅克隆子模块（app-only 仅需 FEX；完整模式全量并跳过三个测试数据仓）"
  if [ "$APP_ONLY" = 1 ]; then
    tic; git submodule update --init --depth 1 --jobs "$NPROC" -- FEX; toc "native:fex-clone"
  else
    # 主仓库子模块: pinned SHA 均为各分支 HEAD（2026-10-11 核实），--depth 1 可用。
    tic; git submodule update --init --depth 1 --jobs "$NPROC" -- FEX wine dxmt; toc "native:submodule-clone"
    tic; git -C dxmt submodule update --init --depth 1 --jobs "$NPROC"; toc "native:dxmt-submodule-clone"
    for header in d3d9.h d3d11.h d3dcommon.h dxgi.h; do
      [ -s "dxmt/include/native/directx/$header" ] || die "DXMT 子模块缺失头文件: $header"
    done
  fi
  # FEX 嵌套子模块: BUILD_TESTING=OFF，三个 *-tests-bins 数据仓（数百 MB）
  # 不参与构建，跳过；其余（fmt/range-v3/rpmalloc/jemalloc/vixl 等）保留。
  local fex_modules fex_paths=() module_key module_path
  fex_modules="$(git -C FEX config -f .gitmodules --get-regexp '^submodule\..*\.path$')"
  while read -r module_key module_path; do
    case "$module_path" in
      *tests-bins*) ;;
      *) fex_paths+=("$module_path") ;;
    esac
  done <<< "$fex_modules"
  git -C FEX submodule update --init --depth 1 --jobs "$NPROC" -- "${fex_paths[@]}"
  [ -s FEX/External/fmt/include/fmt/format.h ] || die "FEX 的 pinned fmt 头文件缺失"
  echo "  磁盘余量: $(df -h / | tail -1 | awk '{print $4" free / "$2}')"

  if [ "$APP_ONLY" != 1 ]; then
    step "子模块 SHA 校验（gitlink 必须与实际检出一致）"
    for sub in FEX wine dxmt; do
      expected="$(git ls-tree HEAD "$sub" | awk '{print $3}')"
      actual="$(git -C "$sub" rev-parse HEAD)"
      printf '  %-14s expected=%s actual=%s\n' "$sub" "${expected:-MISSING}" "$actual"
      [ "$expected" = "$actual" ] || { echo "::error::Submodule SHA mismatch: $sub"; exit 1; }
    done
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "wine-sha=$(git -C wine rev-parse HEAD)" >> "$GITHUB_OUTPUT"
    fi
  fi

  step "Python 依赖（FEX 配置期脚本需要 packaging）"
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

  step "FEX iOS 行为补丁：32 位 RaiseException 用客户机上下文抛出（CI 侧）"
  # 32 位游戏抛 C++ 异常（MinGW 的 0x20474343）会走到 FEX 的 WinAPI shim：上游那里是
  # 裸 UNIMPLEMENTED()（实测退出码 0xFE63002C）；改成在宿主栈上调 RtlRaiseException
  # 也不行 —— Windows 会抓当前（宿主）上下文，客户机侧拿到退化上下文（pc=0），
  # 处理函数搜索要么被守卫掐断要么无限打转（两种都实测过）。
  # 上游 FEX 在 WOW64 模块里抛客户机异常用的是
  #   NtRaiseException(record, TLS.EntryContext(), TRUE)
  # 即"客户机进入 CPU 后端时保存的上下文"。这里照做：在 WOW64/Module.cpp 加一个
  # 同 DLL 内的辅助函数（能拿到 GetTLS() 与 UnlockJITContext），让 WinAPI shim 调它。
  python3 - <<'PYEOF'
import io

p = 'FEX/Source/Windows/WOW64/Module.cpp'
s = io.open(p, encoding='utf-8').read()
anchor = '} // namespace Context\n'
if 'MadeiraWow64RaiseGuestException' not in s:
    if s.count(anchor) != 1:
        raise SystemExit('[patch] Context namespace close not unique: %d' % s.count(anchor))
    helper = (anchor +
        '\n'
        '/* MADEIRA: raise a guest exception from the CPU backend with the context the\n'
        ' * guest had when it entered the backend.  Raising from this host frame\n'
        ' * (RtlRaiseException) gave the 32-bit C++ throw a degenerate context (pc=0),\n'
        ' * so the handler search never made progress.  This is the call shape the\n'
        ' * upstream WOW64 module uses for guest exceptions. */\n'
        'extern "C" NTSTATUS WINAPI NtRaiseException(EXCEPTION_RECORD *, CONTEXT *, BOOL);\n'
        'extern "C" void MadeiraWow64RaiseGuestException(EXCEPTION_RECORD *Rec) {\n'
        '  const auto Tls = GetTLS();\n'
        '  Context::UnlockJITContext(Tls);\n'
        '  NtRaiseException(Rec, Tls.EntryContext(), TRUE);\n'
        '}\n')
    s = s.replace(anchor, helper, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: WOW64 guest-context raise helper')
else:
    print('[patch] already applied: WOW64 guest-context raise helper')

p = 'FEX/Source/Windows/Common/WinAPI/Misc.cpp'
s = io.open(p, encoding='utf-8').read()
old = ('DLLEXPORT_FUNC(void, RaiseException, (DWORD dwExceptionCode, DWORD dwExceptionFlags, '
       'DWORD nNumberOfArguments, CONST ULONG_PTR* lpArguments)) {\n'
       '  UNIMPLEMENTED();\n'
       '}')
new = ('extern "C" void MadeiraWow64RaiseGuestException(EXCEPTION_RECORD *ExceptionRecord);\n\n'
       'DLLEXPORT_FUNC(void, RaiseException, (DWORD dwExceptionCode, DWORD dwExceptionFlags, '
       'DWORD nNumberOfArguments, CONST ULONG_PTR* lpArguments)) {\n'
       '  /* MADEIRA: patched by tools/ci/build-all.sh.  Upstream is UNIMPLEMENTED() here,\n'
       '   * which turns every 32-bit C++ throw into exit code 0xFE63002C.  Build the\n'
       '   * record Windows would and raise it on the guest\'s behalf. */\n'
       '  EXCEPTION_RECORD Rec {};\n'
       '  Rec.ExceptionCode = dwExceptionCode;\n'
       '  Rec.ExceptionFlags = dwExceptionFlags;\n'
       '  Rec.NumberParameters = nNumberOfArguments;\n'
       '  for (DWORD i = 0; i < nNumberOfArguments && i < EXCEPTION_MAXIMUM_PARAMETERS; ++i)\n'
       '    Rec.ExceptionInformation[i] = lpArguments ? lpArguments[i] : 0;\n'
       '  MadeiraWow64RaiseGuestException(&Rec);\n'
       '  NtTerminateProcess(NtCurrentProcess(), dwExceptionCode);\n'
       '}')
if old in s:
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: WinAPI RaiseException -> guest-context raise')
elif 'MadeiraWow64RaiseGuestException' in s:
    print('[patch] already applied: WinAPI RaiseException')
else:
    raise SystemExit('[patch] RaiseException pattern not found')
PYEOF

  if [ "$APP_ONLY" = 1 ]; then
    # app 源码只包含 FEXCore 头文件（FEXBridge.mm）；configure 生成
    # ConfigValues.inl 等生成头（约 1 分钟），其余原生库由 stage_app 空桩。
    step "[app-only] FEX configure-only（生成头文件，不编译）"
    FEX_CONFIGURE_ONLY=1 bash build/fex-ios/build.sh
    cmake --build "FEX/build-ios" --target CONFIG_INC
    toc "native:fex-configure+headers"
    echo "[app-only] wine/dxmt 静态库由 stage_app 统一空桩"
    return 0
  fi

  step "FEXCore (build/fex-ios, cmake iOS)"
  bash build/fex-ios/build.sh

  # 32 位 CPU 后端必须和 FEXCore 同一个 commit：设备上那份 vendored 的
  # 上游 v0.1.3 xtajit.dll 在 iOS 15.6 会 NULL 读（libwow64fex+0x1b21e0，
  # handoff 2026-10-12 已记录同一签名），用 pinned FEX 源码重编的就是修好的那份。
  step "FEX WoW64 模块（build/fex-wow64 → aarch64-windows/xtajit.dll）"
  bash build/fex-wow64/build.sh

  ccache --show-stats
}

wine_host_command() {
  local mac_sdk mac_target
  mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
  mac_target="$(uname -m)-apple-macos$(sw_vers -productVersion)"
  env -u IPHONEOS_DEPLOYMENT_TARGET \
    SDKROOT="$mac_sdk" \
    CC="$(xcrun --sdk macosx -f clang) -target $mac_target -isysroot $mac_sdk" \
    CXX="$(xcrun --sdk macosx -f clang++) -target $mac_target -isysroot $mac_sdk" \
    "$@"
}

stage_wine() {
  if [ "$APP_ONLY" = 1 ]; then
    echo "[app-only] 跳过 wine（libntdll_unix/libwineserver/libwin32u_unix 用空桩）"
    return 0
  fi
  step "工具链版本确认（configure 实际使用的 bison/flex 必须来自 brew）"
  command -v bison && bison --version | head -1
  command -v flex && flex --version | head -1

  export PATH="$R/toolchains/$LLVM_MINGW_NAME/bin:$PATH"

  step "wine configure: build-macos (config.h + widl 头文件)"
  if [ ! -f wine/build-macos/Makefile ]; then
    mkdir -p wine/build-macos
    (cd wine/build-macos && wine_host_command ../configure --enable-win64 --disable-tests --without-x)
  fi
  wine_host_command make -C wine/build-macos -j "$NPROC" include/all
  hdrs_m="$(find wine/build-macos/include -name '*.h' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  build-macos 生成头文件数: $hdrs_m"
  [ -f wine/build-macos/include/config.h ] || { echo "::error::build-macos/include/config.h 缺失"; exit 1; }
  for header in wtypes mfobjects mftransform objidlbase objidl; do
    [ -s "wine/build-macos/include/$header.h" ] || die "Wine Mac 生成头缺失: $header.h"
  done

  step "wine configure: build-arm64ec (dwrite 的 widl 头文件)"
  if [ ! -f wine/build-arm64ec/config.status ]; then
    mkdir -p wine/build-arm64ec
    (cd wine/build-arm64ec && \
      wine_host_command ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
  fi
  wine_host_command make -C wine/build-arm64ec -j "$NPROC" include/all
  hdrs_x="$(find wine/build-arm64ec/include -name '*.h' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  build-arm64ec 生成头文件数: $hdrs_x"
  for header in dwrite dwrite_3 objidlbase objidl; do
    [ -s "wine/build-arm64ec/include/$header.h" ] || die "Wine ARM64EC 生成头缺失: $header.h"
  done

  step "libntdll_unix.a (build/ntdll-unix)"
  bash build/ntdll-unix/build.sh

  step "libwineserver.a (build/wineserver, 含 CI 引导)"
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
  xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min="${IPHONEOS_DEPLOYMENT_TARGET:-15.6}" -c "$sd/stub.c" -o "$sd/stub.o"
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
    "app/Madeira/libmadeira_rppairing.a"
    "app/Madeira/libgnutls.a"
    "app/Madeira/libhogweed.a"
    "app/Madeira/libnettle.a"
    "app/Madeira/libgmp.a"
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
  bash build/stage-licenses.sh
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
    echo "BUILD_PURPOSE=FULL_NATIVE_BUILD"
    [ -s app/Madeira/libdxmt_combined.a ] || die "真实 DXMT 静态库缺失"
    [ -s app/Madeira/libmadeira_rppairing.a ] || die "真实配对静态库缺失"
  fi

  DD="$R/ci-DD/Madeira-DD"
  step "xcodebuild 编译冒烟 (Debug, 未签名, DerivedData=$DD)"
  rc=0
  tic
  xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ENABLE_DEBUG_DYLIB=YES \
    COMPILER_INDEX_STORE_ENABLE=NO \
    OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -warn-long-expression-type-checking=500 -Xfrontend -warn-long-function-bodies=1000' \
    -showBuildTimingSummary \
    build > "$LOGDIR/xcodebuild.log" 2>&1 || rc=$?
  toc "app:xcodebuild"
  grep -E 'took [0-9]+ms to type-check|Build Timing Summary' "$LOGDIR/xcodebuild.log" > "$LOGDIR/compile-timing.log" || true
  if [ "$rc" -ne 0 ]; then
    if [ "$APP_ONLY" = 1 ] \
        && grep -qE 'Undefined symbols?(:| for architecture)' "$LOGDIR/xcodebuild.log" \
        && ! grep -E '(^|[[:space:]])(fatal )?error:|^Command .* failed' "$LOGDIR/xcodebuild.log" \
          | grep -Ev 'error: linker command failed|^Command Ld( .*)? failed'; then
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
  local app_minos
  app_minos="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_BUILT/Info.plist")"
  [ "$app_minos" = "${IPHONEOS_DEPLOYMENT_TARGET:-15.6}" ] || die "主 App MinimumOSVersion 与构建目标不一致，实际为 $app_minos"
  bash tools/ci/verify-startup.sh "$APP_BUILT" "$LOGDIR"
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
    while IFS= read -r diagnostic; do
      local relative="${diagnostic#"$R"/}"
      mkdir -p "$LOGDIR/native-diagnostics/$(dirname "$relative")"
      cp "$diagnostic" "$LOGDIR/native-diagnostics/$relative" || true
    done < <(find "$R/build" "$R/wine" -type f \( -name '*.log' -o -name '*.err' -o -name 'err-*.txt' \) -newer "$LOGDIR/.stamp" 2>/dev/null)
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
