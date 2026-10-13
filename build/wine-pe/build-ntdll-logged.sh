#!/bin/bash
# Rebuild the ARM64EC PE ntdll with Wine's hybrid-slot patching logged.
#
# A 64-bit D3D11 program dies on a jump to address 0 inside an ARM64EC module's
# exit thunk, and nothing in the log says which dispatch slot the call went
# through or whether that slot was patched.  build/wine-pe/log-hybrid.py adds
# that logging to the pinned wine source (in the CI workspace only), then the
# existing build-ntdll.sh builds and installs the DLL exactly as before,
# including its SizeOfImage + 0x50000 padding.
#
# Run this AFTER tools/ci/verify-upstream-compat.py, next to the DXMT PE step.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# `make -C dlls/ntdll` pulls in Wine's tools (wrc, widl, winebuild) before it can
# link the DLL, and tools/wrc/parser.y needs bison >= 3.0 (`%define api.prefix`).
# macOS still ships /usr/bin/bison 2.3, which rejects that grammar, so put
# Homebrew's copy first the way tools/ci/build-all.sh does for its own steps.
# (Run #71 died here: "parser.y:206.9-18: syntax error, unexpected identifier".)
if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix)"
    export PATH="$brew_prefix/opt/bison/bin:$brew_prefix/opt/flex/bin:$brew_prefix/bin:$PATH"
fi
bison_major="$(bison --version 2>/dev/null | head -1 | awk '{print $NF}')"
bison_major="${bison_major%%.*}"
case "$bison_major" in ''|*[!0-9]*) echo "::error::找不到 bison（Wine 的 tools/wrc 需要 >= 3.0）" >&2; exit 1 ;; esac
[ "$bison_major" -ge 3 ] || { echo "::error::bison 需要 >= 3.0，实际 $(bison --version | head -1)（系统 2.3 编不过 tools/wrc/parser.y）" >&2; exit 1; }
echo "bison: $(bison --version | head -1)"

python3 "$R/build/wine-pe/log-hybrid.py" "$R/wine"
BEFORE="$(wc -c < "$R/app/Madeira/arm64ec-windows/ntdll.dll" 2>/dev/null || echo 0)"
bash "$R/build/wine-pe/build-ntdll.sh"
echo "ntdll.dll: committed $BEFORE bytes, rebuilt $(wc -c < "$R/app/Madeira/arm64ec-windows/ntdll.dll") bytes"
