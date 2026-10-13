#!/usr/bin/env bash
set -euo pipefail

APP_BUILT="$1"
LOGDIR="$2"
mkdir -p "$LOGDIR"
find "$APP_BUILT" -type f | LC_ALL=C sort > "$LOGDIR/bundle-files.txt"
# Upstream ships the Debug-dylib layout: a thin `Madeira` launcher that loads
# `Madeira.debug.dylib`, next to `__preview.dylib`, and the JIT helper has the
# same pair.  This port matches upstream by building with ENABLE_DEBUG_DYLIB=YES,
# so those files are expected; record them instead of rejecting the bundle.
grep -E '/([^/]*\.debug\.dylib|__preview\.dylib)$' "$LOGDIR/bundle-files.txt" \
    > "$LOGDIR/debug-dylibs.txt" || true
echo "Debug-dylib layout: $(wc -l < "$LOGDIR/debug-dylibs.txt" | tr -d ' ') debug/preview dylib(s)"
shopt -s nullglob
BINARIES=("$APP_BUILT/Madeira" "$APP_BUILT/"*.dylib)
: > "$LOGDIR/startup-dependencies.txt"
: > "$LOGDIR/startup-load-commands.txt"
: > "$LOGDIR/startup-imports.txt"
for binary in "${BINARIES[@]}"; do
    otool -L "$binary" >> "$LOGDIR/startup-dependencies.txt"
    otool -l "$binary" >> "$LOGDIR/startup-load-commands.txt"
    nm -m -u "$binary" >> "$LOGDIR/startup-imports.txt"
done
# Read off the shipped upstream v0.1.3 IPA: `Madeira` is a 73,536-byte launcher
# whose only Madeira dependency is `@rpath/Madeira.debug.dylib`, and the code
# lives in `Madeira.debug.dylib` (61,822,448 bytes).  Check the launcher's own
# dependency list -- the aggregate above also carries each dylib's install name,
# so it would match even when the launcher loads nothing.
[ -f "$APP_BUILT/Madeira.debug.dylib" ] || {
    echo "缺少 Madeira.debug.dylib（上游布局要求拆分主程序）" >&2
    exit 1
}
main_dependencies="$(otool -L "$APP_BUILT/Madeira")"
if ! printf '%s\n' "$main_dependencies" | grep -q 'Madeira\.debug\.dylib'; then
    echo "主启动链未引用 Madeira.debug.dylib（上游布局要求引用）" >&2
    exit 1
fi
if printf '%s\n' "$main_dependencies" | grep -q '__preview\.dylib'; then
    echo "__preview.dylib 不得成为启动依赖" >&2
    exit 1
fi
echo "主启动链引用 Madeira.debug.dylib（上游布局）"
main_load_commands="$(otool -l "$APP_BUILT/Madeira")"
main_minimum="$(printf '%s\n' "$main_load_commands" | awk '/^[[:space:]]*cmd LC_/ { command = $2 } command == "LC_BUILD_VERSION" && $1 == "minos" { print $2 } command == "LC_VERSION_MIN_IPHONEOS" && $1 == "version" { print $2 }')"
if [ "$main_minimum" != "${IPHONEOS_DEPLOYMENT_TARGET:-15.6}" ]; then
    echo "主程序 Mach-O 最低系统不符: ${main_minimum:-MISSING}" >&2
    exit 1
fi
# These must stay weak-imported: the availability checks at their call sites
# only work while the reference is weak (a strong reference would make
# dyld refuse the launch on 15.6 instead of binding NULL).
for symbol in \
    _MTLSetShaderCachePath _MTLGetShaderCachePath _MTLCopyAllDevices \
    _os_sync_wait_on_address _os_sync_wait_on_address_with_timeout \
    _os_sync_wake_by_address_all _os_sync_wake_by_address_any; do
    imports="$(awk -v symbol="$symbol" '{ for (field = 1; field <= NF; field++) if ($field == symbol) print }' "$LOGDIR/startup-imports.txt")"
    if [ -z "$imports" ] || printf '%s\n' "$imports" | grep -qv '(undefined) weak external'; then
        echo "Metal 私有符号必须弱引用: $symbol" >&2
        exit 1
    fi
done
echo "Metal 与 os_sync 弱导入符号: weak external"
if grep -q 'NSt3__13pmr' "$LOGDIR/startup-imports.txt"; then
    echo "iOS 15.6 主启动链仍依赖系统 PMR 符号" >&2
    grep 'NSt3__13pmr' "$LOGDIR/startup-imports.txt" >&2
    exit 1
fi
: > "$LOGDIR/startup-symbols.txt"
for binary in "${BINARIES[@]}"; do
    nm -m "$binary" >> "$LOGDIR/startup-symbols.txt"
done
for symbol in __ZNSt3__13pmr15memory_resourceD2Ev __ZTINSt3__13pmr15memory_resourceE; do
    definitions="$(awk -v symbol="$symbol" '{ for (field = 1; field <= NF; field++) if ($field == symbol && $0 !~ /\(undefined\)/) print }' "$LOGDIR/startup-symbols.txt")"
    if [ -z "$definitions" ]; then
        echo "主程序缺少 PMR 兼容定义: $symbol" >&2
        exit 1
    fi
done
echo "PMR 析构与类型信息: 本地定义，无系统 PMR 导入"
: > "$LOGDIR/bundle-components.txt"
while IFS= read -r -d '' component; do
    if file -b "$component" | grep -q 'Mach-O'; then
        printf '\nComponent: %s\n' "${component#"$APP_BUILT/"}" >> "$LOGDIR/bundle-components.txt"
        case "$component" in
            "$APP_BUILT/PlugIns/"*|"$APP_BUILT/Frameworks/StikJIT.framework/"*|"$APP_BUILT/d3d12/"*) role="on demand; minimum version may exceed ${IPHONEOS_DEPLOYMENT_TARGET:-15.6}" ;;
            "$APP_BUILT/Madeira") role="startup inspection" ;;
            "$APP_BUILT/"*.dylib)
                if [ "$(dirname "$component")" = "$APP_BUILT" ]; then
                    role="startup inspection"
                else
                    role="embedded; consult startup dependencies before treating as on demand"
                fi
                ;;
            *) role="embedded; consult startup dependencies before treating as on demand" ;;
        esac
        printf 'Role: %s\n' "$role" >> "$LOGDIR/bundle-components.txt"
        otool -l "$component" | awk '/^[[:space:]]*cmd LC_/ { command = $2 } command == "LC_BUILD_VERSION" && ($1 == "platform" || $1 == "minos" || $1 == "sdk") { print } command ~ /^LC_VERSION_MIN_/ && ($1 == "version" || $1 == "sdk") { print }' >> "$LOGDIR/bundle-components.txt"
    fi
done < <(find "$APP_BUILT" -type f -print0)
metalfx_load="$(awk '/^[[:space:]]*cmd LC_/ { command = $2 } /name .*MetalFX.framework/ { print command }' "$LOGDIR/startup-load-commands.txt")"
if [ -z "$metalfx_load" ] || [ -n "$(printf '%s\n' "$metalfx_load" | grep -v '^LC_LOAD_WEAK_DYLIB$' || true)" ]; then
    echo "MetalFX 必须弱链接，实际为 ${metalfx_load:-MISSING}" >&2
    exit 1
fi
echo "MetalFX: LC_LOAD_WEAK_DYLIB（已检查入口和 App dylib）"
if grep -q libmetalirconverter "$LOGDIR/startup-dependencies.txt"; then
    echo "Metal Shader Converter 只能按需 dlopen，不能作为 15.6 主程序的启动依赖" >&2
    exit 1
fi

# ---- The working tree's native inputs must actually be in the bundle --------
# Two generic checks.  They exist because a build can be green while the bundle
# disagrees with the tree: the folder references we copy (the PE farm, the
# on-demand dylib) are not hashed anywhere, and a restored DerivedData can
# satisfy the link task with a product older than the archives it links -- which
# is how a fixed binary fails to ship.  Neither check depends on a cache key.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dir in arm64ec-windows aarch64-windows i386-windows x86_64-vcruntime d3d12; do
    if [ ! -d "$APP_BUILT/$dir" ]; then
        echo "bundle 里缺少目录: $dir" >&2
        exit 1
    fi
    log="$LOGDIR/bundle-diff-$dir.txt"
    if ! diff -rq "$REPO_ROOT/app/Madeira/$dir" "$APP_BUILT/$dir" > "$log" 2>&1; then
        echo "bundle 里的 $dir 与工作树不一致（前 20 行）:" >&2
        head -20 "$log" >&2
        exit 1
    fi
done
echo "bundle 与工作树逐字节一致: 5 个拷贝目录"

newest_a=""
for a in "$REPO_ROOT/app/Madeira"/*.a; do
    [ -f "$a" ] || continue
    if [ -z "$newest_a" ] || [ "$a" -nt "$newest_a" ]; then newest_a="$a"; fi
done
dyl="$APP_BUILT/Madeira.debug.dylib"
if [ -n "$newest_a" ] && [ "$dyl" -ot "$newest_a" ]; then
    echo "Madeira.debug.dylib 比 $(basename "$newest_a") 还旧：链接被跳过了（缓存恢复出来的旧产物）" >&2
    ls -l "$newest_a" "$dyl" >&2
    exit 1
fi
if [ -f "$LOGDIR/xcodebuild.log" ] && grep -qE '(^|[[:space:]])Ld ' "$LOGDIR/xcodebuild.log"; then
    echo "xcodebuild 这次跑了 Ld（$(grep -cE '(^|[[:space:]])Ld ' "$LOGDIR/xcodebuild.log") 行）"
else
    echo "xcodebuild 这次没有跑 Ld（增量构建直接复用了上一份 dylib）"
fi

# ---- Weak-imported C symbols must be audited -------------------------------
# A weak import binds to NULL on an iOS that does not export the symbol, so a
# call that is not behind an availability check or a NULL test jumps to address
# 0.  Every weak C symbol the startup binaries import must be listed in the
# audit file with the reason its call sites are safe; a new one fails the build
# until someone looks at it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_FILE="$REPO_ROOT/tools/ci/weak-imports-audited.txt"
[ -f "$AUDIT_FILE" ] || { echo "缺少弱导入审计清单: $AUDIT_FILE" >&2; exit 1; }
audited_symbols="$(awk '!/^[[:space:]]*#/ && NF { print $1 }' "$AUDIT_FILE" | LC_ALL=C sort -u)"
weak_c_symbols="$(awk '/\(undefined\) weak external/ {
        for (field = 1; field <= NF; field++) {
            symbol = $field
            if (symbol !~ /^_[A-Za-z0-9_]+$/) continue
            if (symbol ~ /^_OBJC_/) continue
            if (symbol ~ /^_swift/) continue
            if (symbol ~ /^__swift/) continue
            print symbol
        }
    }' "$LOGDIR/startup-imports.txt" | LC_ALL=C sort -u)"
unaudited="$(comm -23 <(printf '%s\n' "$weak_c_symbols") <(printf '%s\n' "$audited_symbols"))"
if [ -n "$unaudited" ]; then
    echo "未审计的弱导入 C 符号（在不导出它的 iOS 上会绑成 NULL，未经检查的调用会跳到地址 0）:" >&2
    printf '%s\n' "$unaudited" >&2
    echo "确认其调用点有 iOS 可用性判断或 NULL 检查后，把符号和理由加进 tools/ci/weak-imports-audited.txt" >&2
    exit 1
fi
echo "弱导入 C 符号: $(printf '%s\n' "$weak_c_symbols" | grep -c . || true) 个，全部已审计"

# ---- The MTLCopyAllDevices fallback must be in the shipped dylib ------------
# The weak import is audited above, but auditing the import says nothing about
# whether the guarded call site survived the build.  It did not once: a second
# prepare-compat.py rewrite of winemetal_unix.c overwrote the guard, and every
# IPA from that commit crashed in D3D11 device creation with pc=0 (found by
# disassembling the installed dylib, not in CI).  -initWithObjects:count: is
# the selector only that fallback compiles to, so a build that lost the guard
# fails here instead of shipping a jump to address 0.
if ! LC_ALL=C grep -aq 'initWithObjects:count:' "$APP_BUILT/Madeira.debug.dylib"; then
    echo "Madeira.debug.dylib 缺少 MTLCopyAllDevices 回退（prepare-compat.py 的 winemetal 改写没进二进制，或 app 缓存发了一份旧 dylib）" >&2
    exit 1
fi
echo "MTLCopyAllDevices 回退: 在 Madeira.debug.dylib 里"
