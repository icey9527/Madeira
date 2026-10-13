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
python3 "$R/build/wine-pe/log-hybrid.py" "$R/wine"
BEFORE="$(wc -c < "$R/app/Madeira/arm64ec-windows/ntdll.dll" 2>/dev/null || echo 0)"
bash "$R/build/wine-pe/build-ntdll.sh"
echo "ntdll.dll: committed $BEFORE bytes, rebuilt $(wc -c < "$R/app/Madeira/arm64ec-windows/ntdll.dll") bytes"
