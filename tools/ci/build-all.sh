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

  step "FEX iOS 行为补丁：RaiseException 路由 + 池内 C++ 全局构造（CI 侧）"
  # 18:35 真机测量把调用者钉死了：host_lr 落在 libwow64fex 自身的
  # _Unwind_RaiseException+0x70，self 正是同一镜像里的 RaiseException。
  # 这是宿主 libunwind 的 SEH C++ 抛出（STATUS_GCC_THROW=0x20474343），
  # 不是客户机 JIT 通过导入跳板调过来的。因此：
  #   1) 保持 RaiseException 这个 WinAPI shim 对外的 UNIMPLEMENTED() 语义；
  #   2) 只把 __imp_RaiseException / __imp_aux_RaiseException 指向私有宿主
  #      抛出路径，构造 EXCEPTION_RECORD 后走 RtlRaiseException；
  # 2026-10-12 的 run59/阶段 1 已经验证过“直接 RtlRaiseException + 放宽 unwind
  # guard”能让两个 32 位游戏进入加载窗口；这次只把私有宿主抛出路径恢复回来。
  #
  # 2026-10-15 19:27 真机又抓到真正的抛出点：host_lr=_Unwind_RaiseException+0x70，
  # 三帧 libunwind 报 0x185c4c(__next_prime 的 __throw_overflow_error 返回处)、
  # 0x102afc(BTCpuThreadInit+0x260，紧跟 Threads.emplace)、wow64.dll+0x1c87c。
  # 异常消息是 “__next_prime overflow”。根因是 iOS 池拷贝发生在模块 C++ 全局
  # 构造之前：mingw 的 DllMainCRTStartup 把构造函数跑在“原图”上，而真正执行的是
  # 池内副本，池里的 .data 是构造前的快照。Threads 修好后，下一处是
  # std::chrono::system_clock::now() 里的全局函数指针（libwow64fex+0x1a38fc，
  # x8=0 -> blr x8 -> pc=0），narci2 和 EDEN 死在同一地址。因此不再逐个对象打
  # 补丁，而是在 CRT_iOS.cpp 的 InitCRTProcess 里像非 iOS 的 CRT.cpp 一样，
  # 在池内副本重跑一遍 GNU 构造函数列表。
  # guard”能让两个 32 位游戏进入加载窗口；这次只把私有宿主抛出路径恢复回来。
  python3 - <<'PYEOF'
import io

p = 'FEX/Source/Windows/WOW64/Module.cpp'
s = io.open(p, encoding='utf-8').read()
anchor = '} // namespace Context\n'
if 'MadeiraWow64RaiseDiagnostic' not in s:
    if s.count(anchor) != 1:
        raise SystemExit('[patch] Context namespace close not unique: %d' % s.count(anchor))
    helper = (anchor +
        '\n'
        '/* MADEIRA: read the guest RIP for the RaiseException diagnostic.  Prefer the\n'
        ' * live CPU state; before thread init, fall back to the entry context.  Return\n'
        ' * false for every unavailable/invalid-looking source so the caller logs \'-\'\n'
        ' * rather than provoking another fault while reporting the first one. */\n'
        '#ifdef FEX_IOS_HOST\n'
        'static bool MadeiraWow64GetGuestRip(uint64_t *Rip) {\n'
        '  if (!Rip) {\n'
        '    return false;\n'
        '  }\n'
        '  const auto Tls = GetTLS();\n'
        '  const auto TebAddress = reinterpret_cast<uintptr_t>(Tls.TEB);\n'
        '  if (TebAddress < 0x10000 || (TebAddress & 0x7)) {\n'
        '    return false;\n'
        '  }\n'
        '  if (auto *Thread = Tls.ThreadStateIfInitialised()) {\n'
        '    if (Thread->CurrentFrame) {\n'
        '      *Rip = Thread->CurrentFrame->State.rip;\n'
        '      return true;\n'
        '    }\n'
        '  }\n'
        '  if (auto *EntryContext = Tls.EntryContext()) {\n'
        '    const auto EntryAddress = reinterpret_cast<uintptr_t>(EntryContext);\n'
        '    if (EntryAddress >= 0x10000 && !(EntryAddress & 0x7)) {\n'
        '      *Rip = EntryContext->Pc;\n'
        '      return true;\n'
        '    }\n'
        '  }\n'
        '  return false;\n'
        '}\n'
        '#endif\n'
        '\n'
        '/* MADEIRA: diagnostic only.  The external WinAPI shim remains UNIMPLEMENTED;\n'
        ' * the private host pointer installed from Misc.cpp calls this before asking\n'
        ' * ntdll to unwind the host C++ exception. */\n'
        'extern "C" void MadeiraWow64RaiseDiagnostic(uintptr_t HostLr, uintptr_t Self, DWORD Code, DWORD Flags,\n'
        '                                            DWORD NArgs, const ULONG_PTR *Args) {\n'
        '#ifdef FEX_IOS_HOST\n'
        '  uint64_t GuestRip {};\n'
        '  if (MadeiraWow64GetGuestRip(&GuestRip)) {\n'
        '    LogMan::Msg::EFmt("[mad-raise] host_lr={:#x} self={:#x} guest_rip={:#x} code={:#x} flags={:#x} nargs={} args={:#x}",\n'
        '                      HostLr, Self, GuestRip, Code, Flags, NArgs, reinterpret_cast<uintptr_t>(Args));\n'
        '  } else {\n'
        '    LogMan::Msg::EFmt("[mad-raise] host_lr={:#x} self={:#x} guest_rip=- code={:#x} flags={:#x} nargs={} args={:#x}",\n'
        '                      HostLr, Self, Code, Flags, NArgs, reinterpret_cast<uintptr_t>(Args));\n'
        '  }\n'
        '#else\n'
        '  (void)HostLr;\n'
        '  (void)Self;\n'
        '  (void)Code;\n'
        '  (void)Flags;\n'
        '  (void)NArgs;\n'
        '  (void)Args;\n'
        '#endif\n'
        '}\n')
    s = s.replace(anchor, helper, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: WOW64 RaiseException diagnostic helper')
else:
    print('[patch] already applied: WOW64 RaiseException diagnostic helper')

p = 'FEX/Source/Windows/Common/WinAPI/Misc.cpp'
s = io.open(p, encoding='utf-8').read()
old = ('DLLEXPORT_FUNC(void, RaiseException, (DWORD dwExceptionCode, DWORD dwExceptionFlags, '
       'DWORD nNumberOfArguments, CONST ULONG_PTR* lpArguments)) {\n'
       '  UNIMPLEMENTED();\n'
       '}')
new = '''#if defined(FEX_IOS_HOST) && !defined(ARCHITECTURE_arm64ec)
extern "C" void MadeiraWow64RaiseDiagnostic(uintptr_t, uintptr_t, DWORD, DWORD, DWORD, const ULONG_PTR *);
extern "C" VOID WINAPI RtlRaiseException(PEXCEPTION_RECORD ExceptionRecord);

/* MADEIRA: private host raise path.  The external RaiseException shim
 * remains UNIMPLEMENTED() below, but this module's own libunwind resolves
 * __imp_RaiseException to this function.  Build the record as kernelbase
 * does, then let the host ntdll unwind it. */
static void MadeiraHostRaiseException(DWORD dwExceptionCode, DWORD dwExceptionFlags,
                                      DWORD nNumberOfArguments, const ULONG_PTR *lpArguments) {
  EXCEPTION_RECORD Rec {};
  Rec.ExceptionCode = dwExceptionCode;
  Rec.ExceptionFlags = dwExceptionFlags;
  if (nNumberOfArguments > EXCEPTION_MAXIMUM_PARAMETERS) {
    nNumberOfArguments = EXCEPTION_MAXIMUM_PARAMETERS;
  }
  Rec.NumberParameters = nNumberOfArguments;
  if (lpArguments) {
    for (DWORD i = 0; i < nNumberOfArguments; ++i) {
      Rec.ExceptionInformation[i] = lpArguments[i];
    }
  }
  MadeiraWow64RaiseDiagnostic(reinterpret_cast<uintptr_t>(__builtin_return_address(0)),
                              reinterpret_cast<uintptr_t>(&MadeiraHostRaiseException),
                              dwExceptionCode, dwExceptionFlags, nNumberOfArguments, lpArguments);
  RtlRaiseException(&Rec);
  NtTerminateProcess(NtCurrentProcess(), dwExceptionCode);
}

typedef void (*MadeiraRaiseExceptionFn)(DWORD, DWORD, DWORD, const ULONG_PTR *);
MadeiraRaiseExceptionFn __imp_RaiseException = MadeiraHostRaiseException;
MadeiraRaiseExceptionFn __imp_aux_RaiseException = MadeiraHostRaiseException;

extern "C" void RaiseException(DWORD dwExceptionCode, DWORD dwExceptionFlags,
                               DWORD nNumberOfArguments, CONST ULONG_PTR *lpArguments) {
  UNIMPLEMENTED();
}
#else
DLLEXPORT_FUNC(void, RaiseException, (DWORD dwExceptionCode, DWORD dwExceptionFlags,
                                     DWORD nNumberOfArguments, CONST ULONG_PTR* lpArguments)) {
  UNIMPLEMENTED();
}
#endif'''
if old in s:
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: private host RaiseException path')
elif 'MadeiraHostRaiseException' in s:
    print('[patch] already applied: private host RaiseException path')
else:
    raise SystemExit('[patch] RaiseException pattern not found')

# MADEIRA: the iOS JIT pool copies this PE before mingw's DllMainCRTStartup
# runs on the original image, so the copy that actually executes has raw-zero
# state for every global with a non-trivial constructor.  Threads
# (std::unordered_map) threw __next_prime overflow; with that fixed, libc++'s
# system_clock call pointer was the next pc=0.  Run the GNU constructor list
# again inside the pool copy, exactly as the non-iOS CRT.cpp already does.
p = 'FEX/Source/Windows/Common/CRT/CRT_iOS.cpp'
s = io.open(p, encoding='utf-8').read()
if '__CTOR_LIST__' not in s:
    if '#include <rpmalloc/rpmalloc.h>\n' not in s:
        raise SystemExit('[patch] CRT_iOS rpmalloc include not found')
    s = s.replace('#include <rpmalloc/rpmalloc.h>\n',
                  '#include <rpmalloc/rpmalloc.h>\n#include <iterator>\n\nextern "C" void (*__CTOR_LIST__[])();\n', 1)
    old = ('void InitCRTProcess() {\n'
           '  // mingw\'s default startup already ran the C++ ctors. Ensure the rpmalloc\n'
           '  // global heap is up (idempotent) before any per-thread init below.\n'
           '  rpmalloc_initialize(nullptr);\n'
           '}')
    if s.count(old) != 1:
        raise SystemExit('[patch] CRT_iOS InitCRTProcess pattern not found')
    new = ('void InitCRTProcess() {\n'
           '  /* MADEIRA: mingw\'s DllMainCRTStartup runs the GNU ctors on the ORIGINAL\n'
           '   * image, but on this host the copy that executes is the iOS JIT pool\n'
           '   * copy, whose .data was snapshotted before that.  Every non-trivial\n'
           '   * global is therefore raw zero there: Threads threw __next_prime\n'
           '   * overflow, and libc++\'s system_clock call pointer was the next pc=0.\n'
           '   * Run the constructor list again in the copy that actually runs.\n'
           '   * rpmalloc_initialize stays first (idempotent); the guard makes a\n'
           '   * repeated call from either image harmless. */\n'
           '  static bool RanCtors;\n'
           '  if (RanCtors) {\n'
           '    return;\n'
           '  }\n'
           '  RanCtors = true;\n'
           '\n'
           '  rpmalloc_initialize(nullptr);\n'
           '\n'
           '  auto CtorBegin = &__CTOR_LIST__[1];\n'
           '  auto CtorEnd = CtorBegin;\n'
           '  while (*CtorEnd != nullptr) {\n'
           '    CtorEnd++;\n'
           '  }\n'
           '  for (auto It = std::reverse_iterator(CtorEnd); It != std::reverse_iterator(CtorBegin); ++It) {\n'
           '    if (*It) {\n'
           '      (**It)();\n'
           '    }\n'
           '  }\n'
           '}')
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: run the pool copy GNU ctors in InitCRTProcess')
else:
    print('[patch] already applied: run the pool copy GNU ctors in InitCRTProcess')
# MADEIRA: the [JITPOOL_RIP] detector that used to sit at the end of CompileBlock
# tested a hardcoded window [0x11c000000,0x12e000000) as "the JIT pool".  On
# iOS 15.6 the pool is the TrollStore RX mapping at 0x2a0000000 (896 MB); that
# window is just where Wine loads 64-bit PE images, so every hit was
# dockhost.exe's OWN code -- its TLS callback at base+0x5d10, i.e. 0x127625d10
# on the ml908 module and 0x12b975d10 on the rebuilt one, each matching that
# run's dockhost.exe ImageBase (0x127620000 / 0x12b970000).  It ran AFTER the
# ml315 alias-table redirect above, so any real module pool-copy RIP was already
# redirected before it could fire, and ml300 in this file had already retracted
# the pool-INTERVAL approach as unsound (ARM64EC type-2 X64 ranges inside the
# pool are correctly compiled as x86).  Genuine host-PC leaks are caught by the
# ml197/ml296 gate (>= 0x7400000000 || IsAddressInCodeBuffer) and by
# ntdll-unix's [rip-leak] probe.  Drop the stale detector and spend the space on
# the question the device log actually raised.
p = 'FEX/FEXCore/Source/Interface/Core/Core.cpp'
s = io.open(p, encoding='utf-8').read()
if '[callret-dup #{}]' in s:
    print('[patch] already applied: drop stale JITPOOL_RIP, add callret-dup probe')
else:
    old = '''  {
    /* JIT pool observed at RX=0x11cc00000+0x10000000 across runs. Tighten
     * the detector to the actual pool range so we don't false-positive on
     * other 0x1XXXXXXXX guest addresses. ASLR jitter is ~16MB so widen by
     * 32MB on each side. */
    constexpr uint64_t pool_lo = 0x11c000000ULL;
    constexpr uint64_t pool_hi = 0x12e000000ULL;
    if (GuestRIP >= pool_lo && GuestRIP < pool_hi) {
      uint64_t crsp = Frame ? Frame->State.callret_sp : 0;
      static volatile uint32_t jit_rip_dump_count = 0;
      uint32_t dn = __sync_add_and_fetch(&jit_rip_dump_count, 1);
      if (dn <= 8) {
        LogMan::Msg::EFmt("[JITPOOL_RIP #{}] GuestRIP=0x{:x} (HOST PC LEAKED INTO STATE.RIP)  "
                          "State.rip=0x{:x} callret_sp=0x{:x} Frame=0x{:x}  "
                          "pool=0x{:x}..0x{:x}",
                          dn, GuestRIP,
                          Frame ? Frame->State.rip : 0, crsp,
                          reinterpret_cast<uintptr_t>(Frame),
                          pool_lo, pool_hi);
        if (crsp != 0 && crsp >= 0x10000) {
          for (int i = 0; i < 8; i++) {
            uint64_t *pair = reinterpret_cast<uint64_t*>(crsp + i * 0x10);
            LogMan::Msg::EFmt("[JITPOOL_RIP #{}]   callret[+0x{:x}] = {{pc=0x{:x}, ret=0x{:x}}}",
                              dn, i * 0x10, pair[0], pair[1]);
          }
        }
      }
      /* Log-only \u2014 no state mutation. Fall through to normal compile path.
       * If FEX subsequently faults trying to decode the JIT pool bytes as
       * x86, we'll see that in the Mach handler \u2014 at least we know the
       * exact RIP that leaked. */
    }
  }
'''
    new = '''#if defined(FEX_IOS_HOST)
  /* MADEIRA callret duplicate-run probe.  The device log showed the top eight
   * callret entries holding the SAME {guest_ret, host_ret} pair with 16701
   * entries in use.  Is that a loop legitimately re-pushing the same call, or a
   * push that never pops?  Count the longest run of identical consecutive pairs
   * and report it with the stack depth so the next log answers that instead of
   * us guessing.  Bounds-checked and read-only, and the scan is rate-limited
   * (1 in 4096 CompileBlock calls) so the hot path does not pay for it.
   *
   * Replaces the stale [JITPOOL_RIP] detector: see the patch comment in
   * tools/ci/build-all.sh for why its hardcoded window was pure false
   * positives, and why ml315 (above) plus ml197/ml296 already cover the real
   * cases. */
  if (Frame) {
    static volatile uint32_t dup_probe_tick = 0;
    const uint32_t Tick = __sync_add_and_fetch(&dup_probe_tick, 1);
    if ((Tick & 0xFFF) == 0) {
      const uint64_t CRBase = Frame->State.callret_sp_base;
      const uint64_t CRSp = Frame->State.callret_sp;
      const uint64_t CREnd = CRBase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
      if (CRBase && CRSp >= CRBase && CRSp + 0x10 <= CREnd) {
        const uint64_t Pc0 = *reinterpret_cast<const uint64_t*>(CRSp);
        const uint64_t Host0 = *reinterpret_cast<const uint64_t*>(CRSp + 8);
        uint32_t Run = 0;
        for (uint32_t i = 1; i < 64; ++i) {
          const uint64_t Slot = CRSp + (uint64_t)i * 0x10;
          if (Slot + 0x10 > CREnd) {
            break;
          }
          if (*reinterpret_cast<const uint64_t*>(Slot) != Pc0 ||
              *reinterpret_cast<const uint64_t*>(Slot + 8) != Host0) {
            break;
          }
          Run = i;
        }
        if (Run + 1 >= 4) {
          static volatile uint32_t dup_dump_count = 0;
          const uint32_t DupN = __sync_add_and_fetch(&dup_dump_count, 1);
          if (DupN <= 16) {
            LogMan::Msg::EFmt("[callret-dup #{}] run={} pc=0x{:x} ret=0x{:x}  sp=0x{:x} "
                              "base=0x{:x} depth=0x{:x}  GuestRIP=0x{:x}",
                              DupN, Run + 1, Pc0, Host0, CRSp, CRBase,
                              (CRBase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE / 4) - CRSp,
                              GuestRIP);
          }
        }
      }
    }
  }
#endif
'''
    if old not in s:
        raise SystemExit('[patch] stale JITPOOL_RIP detector pattern not found -- FEX Core.cpp changed?')
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: drop stale JITPOOL_RIP, add callret-dup probe')
# MADEIRA: arm64x_check_call (__os_arm64x_check_icall) bounds-checks the target
# ABOVE the EcCodeBitMap's coverage (ml975: >= 2^39 -> .Lexit) but not BELOW the
# iOS user-space floor, and ml975's own comment records that gap:
#   "a NULL or small-but-invalid target still reaches `ldr x16,[x11]` below and
#    faults there, which is what Windows would also do."
#
# iOS 15.6 makes that gap fatal.  The observed target is exactly 0x100000000 --
# the iOS user-space floor, which this port already uses as "below this nothing
# is mapped" in build/ntdll-unix/signal_arm64_ios.c (bus_pc_ok, ml982).  It is
# far below the 2^39 ceiling, so the ml975 guard passes it, the bitmap reads
# "not EC code", and the FFS sniff dereferences it inside ntdll:
#   [first-fault] pc=<ntdll pool>+0x5623c addr=0x100000000 x11=0x100000000
#   lr PE: libarm64ecfex.dll+0x1412c
# -> guest c0000005, and the process dies with an exception the guest cannot
# handle, because it is raised from inside ntdll's classifier.
#
# Reject at or below the floor and take .Lexit, the "not EC code, use the x64
# exit thunk" answer -- the same reasoning and the same exit as ml975, and the
# only exit that does not dereference x11.  A target that is genuinely mapped
# code at or below the floor has never existed on iOS (the app's own region
# starts at [device] address-map=0x10216c000 and above), so this cannot reject
# real code; if it ever did, .Lexit still runs it correctly through the thunk.
#
# The count and the last target/caller are kept in a small array so the next
# report can say whether this fires once or in a loop, and who supplied it.
p = 'wine/dlls/ntdll/signal_arm64ec.c'
s = io.open(p, encoding='utf-8').read()
if 'madeira_ec_floor_log' in s:
    print('[patch] already applied: arm64x_check_call iOS floor guard')
else:
    # 1) the storage
    anchor = ("static void __attribute__((naked)) arm64x_check_call(void)\n{\n")
    if anchor not in s:
        raise SystemExit('[patch] arm64x_check_call definition not found')
    s = s.replace(
        anchor,
        "/* MADEIRA: [0]=times the iOS-floor guard rejected a target,\n"
        " * [1]=the last rejected target, [2]=the caller that supplied it. */\n"
        "UINT64 madeira_ec_floor_log[3] __attribute__((used));\n"
        "\n"
        + anchor, 1)

    # 2) the guard itself
    old = ('         "lsr x16, x11, #39\\n\\t"            /* ml975: beyond 39-bit VA / map coverage? */\n'
           '         "cbnz x16, .Lexit\\n\\t"             /*        -> not EC code, exit thunk */\n'
           '         "ldr x16, [x18, #0x60]\\n\\t"        /* peb -- see above, intentionally x18 */\n')
    if old not in s:
        raise SystemExit('[patch] ml975 guard text not found -- wine signal_arm64ec.c changed?')
    new = ('         "lsr x16, x11, #39\\n\\t"            /* ml975: beyond 39-bit VA / map coverage? */\n'
           '         "cbnz x16, .Lexit\\n\\t"             /*        -> not EC code, exit thunk */\n'
           '         /* MADEIRA: also reject at or below the iOS user-space floor. */\n'
           '         "movz x16, #0x1, lsl #32\\n\\t"       /* x16 = 0x100000000 */\n'
           '         "cmp x11, x16\\n\\t"\n'
           '         "b.hi .Labove_floor\\n\\t"\n'
           '         "adrp x16, madeira_ec_floor_log\\n\\t"\n'
           '         "add x16, x16, #:lo12:madeira_ec_floor_log\\n\\t"\n'
           '         "ldr x17, [x16]\\n\\t"\n'
           '         "add x17, x17, #1\\n\\t"\n'
           '         "str x17, [x16]\\n\\t"\n'
           '         "str x11, [x16, #8]\\n\\t"\n'
           '         "str x30, [x16, #16]\\n\\t"\n'
           '         "b .Lexit\\n\\t"\n'
           '         ".Labove_floor:\\n\\t"\n'
           '         "ldr x16, [x18, #0x60]\\n\\t"        /* peb -- see above, intentionally x18 */\n')
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: arm64x_check_call iOS floor guard')

# MADEIRA: the SAME missing lower bound, one layer over.
#
# ntdll's arm64x_check_call now rejects a target at or below the iOS user-space
# floor and takes .Lexit, which hands that target to the x64 exit thunk. The
# thunk ends in FEX's own ExitToX64, whose FFS sniff does `ldr x16, [x9]` with
# the same unchecked x9 -- so the bad address simply crashes one layer later.
# The 02:14 device log shows exactly that: ntdll no longer appears in the
# fault, and the PC is libarm64ecfex.dll+0x11348, whose bytes are
#   f9400130 (ldr x16,[x9])  d2916911 f2a91891 f2cb1131 f2eaa411 eb11021f
# i.e. the movz/movk ladder that builds 0x5520588948C48B48, the FFS magic.
#
# ExitToX64 documents x16/x17 as scratch, so the check is free: an x9 at or
# below the floor is never a real FFS (the app's own region starts at
# address-map=0x10216c000 and above on iOS), and falling through to
# ios_ffs_no_bypass is the documented "not FFS -> normal emulation" path.
p = 'FEX/Source/Windows/ARM64EC/Module.S'
s = io.open(p, encoding='utf-8').read()
if 'MADEIRA: FFS SIGNATURE SNIFF' in s:
    print('[patch] already applied: ExitToX64 FFS floor guard')
else:
    old = "  ldr x16, [x9]\n  movz x17, #0x8b48\n"
    new = "\n".join([
        "  /* MADEIRA: FFS SIGNATURE SNIFF NEEDS A FLOOR. x9 here is the target the",
        "   * caller could not classify, and it reaches this line unchecked, so a bad",
        "   * pointer faults inside FEX exactly as it did inside ntdll's",
        "   * arm64x_check_call. 0x100000000 is the iOS user-space floor and nothing is",
        "   * mapped at or below it, so an x9 there can only be a bad target: take the",
        "   * documented non-FFS path instead of dereferencing it. x16 is scratch. */",
        "  movz x16, #0x1, lsl #32",
        "  cmp x9, x16",
        "  b.ls ios_ffs_no_bypass",
        "  ldr x16, [x9]",
        "  movz x17, #0x8b48",
        "",
    ])
    if old not in s:
        raise SystemExit('[patch] ExitToX64 FFS anchor not found -- FEX Module.S changed?')
    s = s.replace(old, new, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: ExitToX64 FFS floor guard')

# MADEIRA: name the producer of the RIP that the two floor guards now reject.
#
# With ntdll's arm64x_check_call and FEX's ExitToX64 both refusing a target at or
# below 0x100000000, the 13:41 run no longer crashes -- it Livelocks: CompileBlock
# is entered 4.08e9 times with GuestRIP=0x100000000, 99% of them L1 hits, so the
# block that exists for that address re-enters the dispatcher immediately. The
# log says nothing about where the address came from, which is now the only
# unknown left. Print the guest context the first few times it happens:
# __builtin_return_address(0) names the host caller, and the guest registers plus
# the call-return stack say where the guest came from.
#
# The same edit stops the flood that turned that livelock into a 48 MB log: 249k
# of its 264k lines were [CB_SUMMARY], emitted every 16384 CompileBlock calls. The
# summary is pointless once the hot RIP is the bogus one, so skip it (and keep
# advancing the window so the check stays cheap).
p = 'FEX/FEXCore/Source/Interface/Core/Core.cpp'
s = io.open(p, encoding='utf-8').read()
if 'floor-rip #' in s:
    print('[patch] already applied: floor-rip probe + CB_SUMMARY flood guard')
else:
    ins = "  /* iOS-Madeira 2026-05-18 low-noise summary. Replaces per-call log (which\n"
    if ins not in s:
        raise SystemExit('[patch] CB_SUMMARY block not found -- FEX Core.cpp changed?')
    probe = "\n".join([
        "#if defined(FEX_IOS_HOST)",
        "  /* MADEIRA floor-rip probe: see the patch comment in tools/ci/build-all.sh.",
        "   * One-shot per arm; a livelock must not be able to flood the log. */",
        "  if (GuestRIP <= 0x100000000ULL) {",
        "    static volatile uint32_t floor_rip_count = 0;",
        "    const uint32_t FR = __sync_add_and_fetch(&floor_rip_count, 1);",
        "    if (FR <= 4) {",
        "      LogMan::Msg::EFmt(\"[floor-rip #{}] GuestRIP=0x{:x} State.rip=0x{:x} host_ra=0x{:x} \"",
        "                        \"callret_sp=0x{:x} Frame=0x{:x}\",",
        "                        FR, GuestRIP, Frame ? Frame->State.rip : 0,",
        "                        reinterpret_cast<uintptr_t>(__builtin_return_address(0)),",
        "                        Frame ? Frame->State.callret_sp : 0,",
        "                        reinterpret_cast<uintptr_t>(Frame));",
        "      if (Frame) {",
        "        LogMan::Msg::EFmt(\"[floor-rip #{}] rax={:#x} rcx={:#x} rdx={:#x} rbx={:#x} \"",
        "                          \"rsp={:#x} rbp={:#x} rsi={:#x} rdi={:#x}\",",
        "                          FR, Frame->State.gregs[0], Frame->State.gregs[1],",
        "                          Frame->State.gregs[2], Frame->State.gregs[3],",
        "                          Frame->State.gregs[4], Frame->State.gregs[5],",
        "                          Frame->State.gregs[6], Frame->State.gregs[7]);",
        "        LogMan::Msg::EFmt(\"[floor-rip #{}] r8={:#x} r9={:#x} r10={:#x} r11={:#x} \"",
        "                          \"r12={:#x} r13={:#x} r14={:#x} r15={:#x}\",",
        "                          FR, Frame->State.gregs[8], Frame->State.gregs[9],",
        "                          Frame->State.gregs[10], Frame->State.gregs[11],",
        "                          Frame->State.gregs[12], Frame->State.gregs[13],",
        "                          Frame->State.gregs[14], Frame->State.gregs[15]);",
        "        const uint64_t FRBase = Frame->State.callret_sp_base;",
        "        const uint64_t FRSp = Frame->State.callret_sp;",
        "        const uint64_t FREnd = FRBase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;",
        "        if (FRBase && FRSp >= FRBase && FRSp + 0x10 <= FREnd) {",
        "          for (int i = 0; i < 6; ++i) {",
        "            const uint64_t Slot = FRSp + (uint64_t)i * 0x10;",
        "            if (Slot + 0x10 > FREnd) {",
        "              break;",
        "            }",
        "            LogMan::Msg::EFmt(\"[floor-rip #{}]   callret[+0x{:x}] = {{pc=0x{:x}, ret=0x{:x}}}\",",
        "                              FR, i * 0x10,",
        "                              *reinterpret_cast<const uint64_t*>(Slot),",
        "                              *reinterpret_cast<const uint64_t*>(Slot + 8));",
        "          }",
        "        }",
        "      }",
        "    }",
        "  }",
        "#endif",
        "",
    ])
    s = s.replace(ins, probe + ins, 1)

    cond = "    if ((total - g_cb_last_summary_total) >= 16384) {\n"
    if cond not in s:
        raise SystemExit('[patch] CB_SUMMARY condition not found')
    newcond = ("    /* MADEIRA: a hot RIP at or below the iOS user-space floor means the run is\n"
               "     * livelocked on a bogus address; [floor-rip] has already named it, and\n"
               "     * 249k of these lines is what turned one hang into a 48 MB log. Keep the\n"
               "     * window moving so the check stays cheap, but do not print. */\n"
               "    if (g_cb_hot_rip <= 0x100000000ULL) {\n"
               "      g_cb_last_summary_total = total;\n"
               "    } else if ((total - g_cb_last_summary_total) >= 16384) {\n")
    s = s.replace(cond, newcond, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('[patch] applied: floor-rip probe + CB_SUMMARY flood guard')
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

  # 64 位 CPU 后端（ARM64EC）。和上面的 32 位模块同理：仓库里 vendored 的
  # xtajit64.dll 是上游 v0.1.3 的预编译件（日志里的 [build-id] rev=ml908 是
  # 源码里写死的常量，不是真实修订），而 pinned FEX 源码已经比它多出十几个
  # 带日志标签的修订，包括 ml1207 的 sub-floor 代码失效、ml1231 的 LRCPC2/AFP
  # 主机特性、ml1039 的访问违例数据地址诊断。Fate 的 JITPOOL_RIP 正好落在
  # 这段漂移里，所以这里也改成从 pinned FEX 源码构建。
  step "FEX ARM64EC 模块（build/fex-arm64ec → arm64ec-windows/xtajit64.dll）"
  bash build/fex-arm64ec/build.sh

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

  # 64 位 PE 边的 ntdll **不在这里**构建。它由 build/wine-pe/build-ntdll.sh 产出，
  # 而那个脚本的前提是 tools/ci/build-all.sh 已给 wine/dlls/ntdll/signal_arm64ec.c
  # 打过补丁；本阶段是 cache 命中就整体跳过的（见 ci.yml 的 wine-cache），把构建
  # 放在这里会让"补丁变了但本阶段没跑"变成一次静默的旧文件发布 —— 4589017 那次
  # 就是这样：arm64x_check_call 的地板护栏没进包，CI 却全绿。它现在有自己的
  # restore / build / save 三步（照抄 aarch64-windows/ntdll.dll 那个 WoW64 loader
  # 的写法），key 里带上 build-all.sh 的哈希，且构建步骤不被 cache 命中跳过。
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
