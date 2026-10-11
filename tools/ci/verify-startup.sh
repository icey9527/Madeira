#!/usr/bin/env bash
set -euo pipefail

APP_BUILT="$1"
LOGDIR="$2"
mkdir -p "$LOGDIR"
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
