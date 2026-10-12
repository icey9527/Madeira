import pathlib
import sys

source_root = pathlib.Path(sys.argv[1])
output_root = pathlib.Path(sys.argv[2])
deployment = tuple(int(part) for part in sys.argv[3].split('.'))
sources = (
    'airconv/nt/air_builder.cpp',
    'airconv/dxbc_converter_gs.cpp',
    'airconv/dxbc_signature.cpp',
)
for relative in sources:
    output = output_root / relative
    if deployment >= (16, 3):
        output.unlink(missing_ok=True)
        continue
    source = (source_root / relative).read_text(encoding='utf-8')
    if '#include <format>' not in source or 'std::format(' not in source:
        raise SystemExit(f'DXMT format compatibility pattern changed: {relative}')
    output.parent.mkdir(parents=True, exist_ok=True)
    compatible = source.replace('#include <format>', '#include <fmt/format.h>')
    compatible = compatible.replace('std::format(', 'fmt::format(')
    output.write_text(compatible, encoding='utf-8')
    print(f'iOS {sys.argv[3]} format compatibility: {relative}')

relative = 'winemetal/unix/cache.c'
source = (source_root / relative).read_text(encoding='utf-8')
replacements = (
    ('extern void MTLSetShaderCachePath(NSString* path);',
     'extern void MTLSetShaderCachePath(NSString* path) __attribute__((weak_import));'),
    ('extern NSString* MTLGetShaderCachePath();',
     'extern NSString* MTLGetShaderCachePath() __attribute__((weak_import));'),
    ('_WMTSetMetalShaderCachePath(void *obj) {\n  struct unixcall_setmetalcachepath *params = obj;',
     '_WMTSetMetalShaderCachePath(void *obj) {\n  struct unixcall_setmetalcachepath *params = obj;\n'
     '  if (!MTLSetShaderCachePath || !MTLGetShaderCachePath) {\n'
     '    params->ret_success = 0;\n'
     '    return 0;\n'
     '  }'),
)
for original, replacement in replacements:
    if source.count(original) != 1:
        raise SystemExit(f'DXMT Metal cache compatibility pattern changed: {original}')
    source = source.replace(original, replacement)
output = output_root / relative
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(source, encoding='utf-8')
print(f'iOS {sys.argv[3]} optional Metal cache symbols: {relative}')
