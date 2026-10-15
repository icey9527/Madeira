#!/usr/bin/env python3
"""Verify the committed Windows-side compatibility layers.

The four directories below are the unmodified upstream Madeira v0.1.3
compatibility binaries, committed so CI and local builds use them directly
instead of rebuilding and drifting.  tools/ci/upstream-compat.sha256 is the
authoritative manifest; any edit, addition or deletion fails the build.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

DIRS = ("i386-windows", "aarch64-windows", "arm64ec-windows", "d3d12")
MANIFEST = Path(__file__).with_name("upstream-compat.sha256")

# Built by CI from the pinned FEX/Wine sources instead of being vendored:
#   * xtajit.dll  -- the upstream prebuild is the one that NULL-derefs inside
#     libwow64fex on iOS 15.6;
#   * ntdll.dll   -- the upstream prebuild assumes the native layer has already
#     allocated native TLS, which this port's alloc_thread_tls does later, so the
#     32-bit loader is rebuilt with that order fixed (build/wine-wow64/).
# See HANDOFF; both files are still shipped, so they must exist -- they are just
# no longer hash-pinned to upstream.
BUILD_OUTPUTS = frozenset({
    "app/Madeira/aarch64-windows/xtajit.dll",
    "app/Madeira/aarch64-windows/ntdll.dll",
})

# Directories CI builds from source: the 32-bit farm (Wine's i386 modules plus
# DXMT's i386 d3d11/dxgi/d3d10core/winemetal/d3d9).  It has to come from the
# same wine pin as the aarch64 loader/backend that dispatches its exceptions --
# mixing a rebuilt host ntdll with vendored i386 modules is what left the
# 32-bit C++ throw with a degenerate context (pc=0).  Still required to exist.
BUILD_OUTPUT_DIRS = ("app/Madeira/i386-windows",)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest() -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        digest, relative = line.split("  ", 1)
        entries[relative] = digest
    return entries


def main(argv: list[str]) -> int:
    bundle = Path(argv[1]) if len(argv) > 1 else Path("app/Madeira")
    expected = load_manifest()

    actual: dict[str, str] = {}
    for name in DIRS:
        base = bundle / name
        if not base.is_dir():
            raise SystemExit(f"missing compatibility directory: {base}")
        for path in base.rglob("*"):
            if path.is_file():
                key = path.as_posix()
                if any(key.startswith(d + "/") for d in BUILD_OUTPUT_DIRS):
                    continue
                actual[key] = sha256(path)

    for relative in sorted(BUILD_OUTPUTS):
        if relative not in actual:
            raise SystemExit(f"missing build output: {relative}")
        actual.pop(relative)

    for directory in BUILD_OUTPUT_DIRS:
        built = bundle / Path(directory).relative_to("app/Madeira")
        count = sum(1 for f in built.glob("*") if f.is_file()) if built.is_dir() else 0
        if count == 0:
            raise SystemExit(f"missing build output directory or it is empty: {directory}")

    problems: list[str] = []
    for relative, digest in sorted(expected.items()):
        if relative not in actual:
            problems.append(f"missing: {relative}")
        elif actual[relative] != digest:
            problems.append(f"changed: {relative}")
    for relative in sorted(set(actual) - set(expected)):
        problems.append(f"unexpected file: {relative}")

    if problems:
        print("committed compatibility layer does not match the upstream manifest:", file=sys.stderr)
        for problem in problems[:40]:
            print("  " + problem, file=sys.stderr)
        if len(problems) > 40:
            print(f"  ... and {len(problems) - 40} more", file=sys.stderr)
        return 1

    print(f"upstream compatibility layers verified: {len(expected)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
