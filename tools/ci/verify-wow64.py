import struct
import sys
from pathlib import Path


def machine(path):
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b"MZ":
        raise SystemExit(f"Invalid PE: {path}")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset + 6 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise SystemExit(f"Invalid PE header: {path}")
    return struct.unpack_from("<H", data, offset + 4)[0]


def verify(bundle):
    groups = {
        "i386-windows": (0x14C, ["ntdll.dll", "kernel32.dll", "kernelbase.dll", "user32.dll", "gdi32.dll", "win32u.dll", "msvcrt.dll", "advapi32.dll", "ole32.dll", "shell32.dll", "d3d9.dll", "d3d9-emulated.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"]),
        "aarch64-windows": (0xAA64, ["ntdll.dll", "wow64.dll", "wow64win.dll", "xtajit.dll"]),
    }
    for directory, (expected, names) in groups.items():
        for name in names:
            path = bundle / directory / name
            if not path.is_file() or machine(path) != expected:
                raise SystemExit(f"Missing or wrong architecture: {path}")
    modules = list((bundle / "i386-windows").glob("*.dll"))
    for path in modules:
        if machine(path) != 0x14C:
            raise SystemExit(f"Wrong i386 architecture: {path}")
    print(f"WoW64 resources verified: {len(modules)} i386 DLLs and ARM64 loader/backend")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
