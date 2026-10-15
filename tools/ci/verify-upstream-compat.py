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

# Built by CI from the pinned FEX source instead of being vendored, because the
# upstream prebuild is the one that NULL-derefs in libwow64fex on iOS 15.6
# (see tools/ci/build-all.sh and HANDOFF).  These paths are still shipped, so
# they must exist -- they are just not hash-pinned to upstream any more.
BUILD_OUTPUTS = frozenset({
    "app/Madeira/aarch64-windows/xtajit.dll",
})


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
                actual[path.as_posix()] = sha256(path)

    for relative in sorted(BUILD_OUTPUTS):
        if relative not in actual:
            raise SystemExit(f"missing build output: {relative}")
        actual.pop(relative)

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
