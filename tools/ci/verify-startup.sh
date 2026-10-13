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
for symbol in _MTLSetShaderCachePath _MTLGetShaderCachePath; do
    imports="$(awk -v symbol="$symbol" '{ for (field = 1; field <= NF; field++) if ($field == symbol) print }' "$LOGDIR/startup-imports.txt")"
    if [ -z "$imports" ] || printf '%s\n' "$imports" | grep -qv '(undefined) weak external'; then
        echo "Metal 私有符号必须弱引用: $symbol" >&2
        exit 1
    fi
done
echo "Metal 私有缓存符号: weak external"
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
