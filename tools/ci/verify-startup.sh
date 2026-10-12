#!/usr/bin/env bash
set -euo pipefail

APP_BUILT="$1"
LOGDIR="$2"
mkdir -p "$LOGDIR"
find "$APP_BUILT" -type f | LC_ALL=C sort > "$LOGDIR/bundle-files.txt"
if grep -Eq '/([^/]*\.debug\.dylib|__preview\.dylib)$' "$LOGDIR/bundle-files.txt"; then
    echo "安装包含遗留 debug/preview dylib" >&2
    exit 1
fi
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
if grep -Eq 'Madeira\.debug\.dylib|__preview\.dylib' "$LOGDIR/startup-dependencies.txt"; then
    echo "主启动链仍引用 debug/preview dylib" >&2
    exit 1
fi
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
: > "$LOGDIR/bundle-components.txt"
while IFS= read -r -d '' component; do
    if file -b "$component" | grep -q 'Mach-O'; then
        printf '\nComponent: %s\n' "${component#"$APP_BUILT/"}" >> "$LOGDIR/bundle-components.txt"
        case "$component" in
            "$APP_BUILT/Madeira"|"$APP_BUILT/"*.dylib) role="startup inspection" ;;
            "$APP_BUILT/PlugIns/"*|"$APP_BUILT/Frameworks/StikJIT.framework/"*|"$APP_BUILT/d3d12/"*) role="on demand; minimum version may exceed ${IPHONEOS_DEPLOYMENT_TARGET:-15.6}" ;;
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
