import pathlib
import sys

# DXMT's meson build hardcodes -sdk macosx and --target=air64-apple-macos14.0 for
# the embedded shaders, and only metal_std is an option (upstream's pin for
# newer systems). The iOS 16 fork added metal_sdk / metal_target the same way;
# this adds them here, in the submodule's own files, so -Dmetal_sdk=iphoneos
# -Dmetal_target=air64-apple-ios15 can build a library iOS 15.6 loads.
#
# src/airconv/meson.build is deliberately NOT patched: its three helper shaders
# pass their own extra_args and do not parse below Metal 3.0 (the command
# library is what the device loads; these are linked into airconv's output).
root = pathlib.Path(sys.argv[1])
options = root / 'meson.options'
build = root / 'meson.build'

text = options.read_text(encoding='utf-8')
if "option('metal_sdk'" not in text:
    text += ("# The SDK and AIR target the embedded shaders are compiled for. A library\n"
             "# built for macOS is refused by iOS (\"This library format is not supported\n"
             "# on this platform\"). -Dmetal_sdk=iphoneos -Dmetal_target=<ios triple>\n"
             "# builds one the device accepts.\n"
             "option('metal_sdk', type : 'string', value : 'macosx')\n"
             "option('metal_target', type : 'string', value : 'air64-apple-macos14.0')\n")
    options.write_text(text, encoding='utf-8', newline='\n')

text = build.read_text(encoding='utf-8')
if "metal_sdk = get_option('metal_sdk')" not in text:
    declare = "metal_std = get_option('metal_std')\n"
    if text.count(declare) != 1:
        raise SystemExit('dxmt meson.build: metal_std declaration changed')
    text = text.replace(declare, declare +
                        "metal_sdk = get_option('metal_sdk')\n"
                        "metal_target = get_option('metal_target')\n")
    air = ("arguments : [ '-sdk', 'macosx', 'metal', '-std=' + metal_std, "
           "'--target=air64-apple-macos14.0',")
    if text.count(air) != 1:
        raise SystemExit('dxmt meson.build: metalir generator changed')
    text = text.replace(air, ("arguments : [ '-sdk', metal_sdk, 'metal', '-std=' + metal_std, "
                              "'--target=' + metal_target,"))
    lib = "arguments : [ '-sdk', 'macosx', 'metallib', '-o', '@OUTPUT@', '@INPUT@'],"
    if text.count(lib) != 1:
        raise SystemExit('dxmt meson.build: metallib generator changed')
    text = text.replace(lib, "arguments : [ '-sdk', metal_sdk, 'metallib', '-o', '@OUTPUT@', '@INPUT@'],")
    build.write_text(text, encoding='utf-8', newline='\n')
print('dxmt meson: metal_sdk / metal_target options ready')
