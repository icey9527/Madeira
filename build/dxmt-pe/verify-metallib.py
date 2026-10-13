#!/usr/bin/env python3
"""Fail unless the embedded command library in a d3d11.dll is an iOS one.

The Metal runtime refuses a library whose container names macOS ("This library
format is not supported on this platform"), which is what made upstream's
arm64ec d3d11.dll unusable on iOS 15.6 until this build stamped it for iOS.
CI runs this on the restored-or-rebuilt d3d11.dll as well, so caching that step
cannot quietly ship a DLL that was never checked.
"""
import struct
import sys

d = open(sys.argv[1], 'rb').read()
found = 0
i = d.find(b'MTLB')
while i != -1:
    if i + 16 <= len(d):
        platform = struct.unpack_from('<H', d, i + 4)[0]
        os_ = d[i + 11]
        major, minor = struct.unpack_from('<HH', d, i + 12)
        if platform in (0x0001, 0x8001) and os_ in (0x81, 0x82) and 1 <= major <= 40:
            print('embedded metallib @0x%x: platform=0x%04x OS=0x%02x version=%d.%d'
                  % (i, platform, os_, major, minor))
            found += 1
            if platform != 0x0001 or os_ != 0x82:
                raise SystemExit('the embedded command library is still not an iOS one')
    i = d.find(b'MTLB', i + 1)
if not found:
    raise SystemExit('no embedded metallib found in the rebuilt d3d11.dll')
print('embedded command library: iOS container verified')
