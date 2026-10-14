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


# iOS 15 (Madeira port): MTLCopyAllDevices exists on iOS only from 18.0 and is
# weak-imported, so below that it binds to NULL and an unconditional call jumps
# to address 0 (measured on the device: D3D11 device enumeration crashed inside
# this function with pc=0).  Below iOS 18 there is one device, returned as a +1
# array so the Copy rule the callers release by still holds.
#
# The @available() form is deliberate.  A plain NULL test is the idiom for a
# weak import, but Metal's header declares this function without weak_import
# (the SDK's .tbd marks the symbol weak, the declaration does not), so clang
# warns -Wpointer-bool-conversion, folds the test to true and deletes the
# fallback -- shipping the same jump to 0 from a build that looks clean.  With
# @available() the compiler must emit a runtime version check, and the fallback
# stays reachable (checked with clang -target arm64-apple-ios15.6: only this
# form keeps -initWithObjects:count: in the object, which is what
# build/dxmt-ios/build.sh and tools/ci/verify-startup.sh now require).
#
# Both edits to this one file share a buffer and it is written once, and the
# written file is read back and checked.  That is not belt-and-braces: the
# second rewrite below used to re-read the pristine source and write the file
# again, which silently dropped this guard -- and with it the whole fix -- from
# every build from the commit that added the gpuResourceID experiment until the
# bug was found by disassembling a shipped dylib on the device.
relative = 'winemetal/unix/winemetal_unix.c'
source = (source_root / relative).read_text(encoding='utf-8')

original = '  params->ret = (obj_handle_t)MTLCopyAllDevices();\n'
replacement = (
    '  /* iOS < 18: MTLCopyAllDevices is weak-imported and NULL; use the one\n'
    '   * device there is, as a +1 array (the Copy rule the callers release). */\n'
    '  if (@available(macOS 10.11, iOS 18.0, *)) {\n'
    '    params->ret = (obj_handle_t)MTLCopyAllDevices();\n'
    '  } else {\n'
    '    id<MTLDevice> device = MTLCreateSystemDefaultDevice();\n'
    '    params->ret = (obj_handle_t)(device ? [[NSArray alloc] initWithObjects:&device count:1]\n'
    '                                        : [[NSArray alloc] init]);\n'
    '    [device release];\n'
    '  }\n'
)
if source.count(original) != 1:
    raise SystemExit(f'DXMT MTLCopyAllDevices pattern changed: {original!r}')
source = source.replace(original, replacement)
# Receipts: both must be in the file this script leaves behind.  The first one
# is also what tools/ci/verify-startup.sh greps the built dylib for, and the
# second is the name of the helper the block below injects.
mtlcad_marker = 'if (@available(macOS 10.11, iOS 18.0, *)) {'
print(f'iOS {sys.argv[3]} optional MTLCopyAllDevices: {relative}')

# iOS 15 (Madeira port) EXPERIMENT: MTLResource.gpuResourceID is a Metal 3
# (iOS 16) API -- calling it on 15.6 raises NSInvalidArgumentException
# ("-[AGXG13GFamilySampler gpuResourceID]: unrecognized selector") and the
# process dies. DXMT encodes these ids into its argument buffers; below iOS 16
# there is no id to encode, so hand the encoder 0, the value DXMT itself uses
# when argument buffers are unavailable (see the support_argument_buffers
# ternary). What this build measures is whether the shaders airconv generates
# actually need a real id -- device creation and the MSAA query decide that.
helper_anchor = '#import <Metal/Metal.h>\n'
if source.count(helper_anchor) != 1:
    raise SystemExit('DXMT winemetal_unix.c: Metal import anchor changed')
helper = helper_anchor + ('/* iOS 15: gpuResourceID is Metal 3 (iOS 16); encode 0 when there is none. */\nstatic inline uint64_t madeira_gpu_resource_id(id resource) {\n  if (@available(iOS 16.0, macOS 13.0, *))\n    return resource ? (uint64_t)[resource gpuResourceID]._impl : 0;\n  return 0;\n}\n')
source = source.replace(helper_anchor, helper)
replacements = (
    ('info->gpu_resource_id = info->support_argument_buffers ? [sampler gpuResourceID]._impl : 0;',
     'info->gpu_resource_id = info->support_argument_buffers ? madeira_gpu_resource_id(sampler) : 0;'),
    ('info->gpu_resource_id = [ret gpuResourceID]._impl;',
     'info->gpu_resource_id = madeira_gpu_resource_id(ret);'),
    ('params->gpu_resource_id = [ret gpuResourceID]._impl;',
     'params->gpu_resource_id = madeira_gpu_resource_id(ret);'),
    ('info->gpu_resource_id = t ? [t gpuResourceID]._impl : 0;',
     'info->gpu_resource_id = t ? madeira_gpu_resource_id(t) : 0;'),
)
total = 0
for original, replacement in replacements:
    count = source.count(original)
    if count == 0:
        raise SystemExit(f'DXMT gpuResourceID pattern missing: {original!r}')
    total += count
    source = source.replace(original, replacement)
for pattern in ('[sampler gpuResourceID]', '[ret gpuResourceID]', '[t gpuResourceID]'):
    if pattern in source:
        raise SystemExit(f'DXMT winemetal_unix.c still calls {pattern}')
gpu_marker = 'madeira_gpu_resource_id'

output = output_root / relative
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(source, encoding='utf-8')

# The file the build compiles is the only thing that matters, so check it.
written = output.read_text(encoding='utf-8')
for marker in (mtlcad_marker, gpu_marker):
    if marker not in written:
        raise SystemExit(f'{relative}: {marker!r} missing from the written file')
print(f'iOS {sys.argv[3]} gpuResourceID guarded in {relative} ({total} sites)')


# iOS 15 (Madeira port): airconv stamps everything it emits as macOS, and the
# Metal runtime refuses such a library outright --
#
#   Failed to create MTLLibrary: ... "This library format is not supported on
#   this platform (or was built with an old version of the tools)"
#
# which is where the first real Draw() died on the device (d3dchk3 stage 2: the
# clear+readback path before it worked, D3DCompile and both Create*Shader calls
# returned S_OK).  The stamps an iOS 15.6 device accepts were read off the
# embedded command library this project already ships for iOS: container
# platform 0x0001 (iOS), OS 0x82, OS version 15.0, and per-function version tags
# air 2.4 / Metal 2.4.  Emit those.  AIRCONV-ios-stamps
airconv_files = (
    ('airconv/airconv_context.cpp', (
        ('"air64-apple-macosx14.0.0"', '"air64-apple-ios15.0.0"'),
    ), ('air64-apple-ios15.0.0',)),
    ('airconv/dxbc_converter.cpp', (
        ('"air64-apple-macosx15.0.0"', '"air64-apple-ios15.0.0"'),
        ('createUnsignedInteger(2), createUnsignedInteger(7), createUnsignedInteger(0)',
         'createUnsignedInteger(2), createUnsignedInteger(4), createUnsignedInteger(0)'),
        ('createUnsignedInteger(2), createUnsignedInteger(6), createUnsignedInteger(0)',
         'createUnsignedInteger(2), createUnsignedInteger(4), createUnsignedInteger(0)'),
        ('createString("Metal"), createUnsignedInteger(3), createUnsignedInteger(2), createUnsignedInteger(0)',
         'createString("Metal"), createUnsignedInteger(2), createUnsignedInteger(4), createUnsignedInteger(0)'),
        ('createString("Metal"), createUnsignedInteger(3), createUnsignedInteger(1), createUnsignedInteger(0)',
         'createString("Metal"), createUnsignedInteger(2), createUnsignedInteger(4), createUnsignedInteger(0)'),
    ), ('air64-apple-ios15.0.0',)),
    ('airconv/dxso_compile.cpp', (
        ('"air64-apple-macosx15.0.0"', '"air64-apple-ios15.0.0"'),
        ('{u32_md(2), u32_md(7), u32_md(0)}', '{u32_md(2), u32_md(4), u32_md(0)}'),
    ), ('air64-apple-ios15.0.0',)),
    ('airconv/ffp_compile.cpp', (
        ('"air64-apple-macosx15.0.0"', '"air64-apple-ios15.0.0"'),
        ('{u32_md(2), u32_md(7), u32_md(0)}', '{u32_md(2), u32_md(4), u32_md(0)}'),
        ('{MDString::get(context, "Metal"), u32_md(3), u32_md(2), u32_md(0)}',
         '{MDString::get(context, "Metal"), u32_md(2), u32_md(4), u32_md(0)}'),
    ), ('air64-apple-ios15.0.0',)),
    ('airconv/metallib_writer.hpp', (
        ('enum class Platform : uint16_t { MTLBPlatform_macOS = 0x8001 };',
         'enum class Platform : uint16_t { MTLBPlatform_macOS = 0x8001, MTLBPlatform_iOS = 0x0001 };'),
        ('enum class OS : uint8_t {\n  MTLBOS_macOS = 0x81,\n};',
         'enum class OS : uint8_t {\n  MTLBOS_macOS = 0x81,\n  MTLBOS_iOS = 0x82,\n};'),
    ), ('MTLBOS_iOS',)),
    ('airconv/metallib_writer.cpp', (
        # iOS 15 (Madeira port): DXMT already dumps the compiled module on the
        # DXSO path (dxso_compile.cpp, DXMT_AIRCONV_DUMP).  The D3D11 path -- the
        # one that dies inside Apple's compiler as soon as a shader reads a
        # texture -- had no such hook, so this one sits in MetallibWriter::Write,
        # the single point every stage's module passes through, and drops the
        # LLVM IR text next to an index line.  The IR is what the rejected shader
        # has to be diffed with, and it is written before the Metal call that
        # wedges, so the dump survives a hung run.  Off unless the variable is
        # set (the app sets it from an env.DXMT_AIRCONV_DUMP line in madeira.cfg).
        ('#include "metallib_writer.hpp"\n',
         '#include "metallib_writer.hpp"\n#include <atomic>\n#include <cstdio>\n'
         '#include <cstdlib>\n#include <string>\n#include <unistd.h>\n'),
        ('void MetallibWriter::Write(const llvm::Module &module, raw_ostream &OS) {\n',
         '/* see prepare-compat.py: env-gated dump of the module AGX is about to get */\n'
         'static void MadeiraDumpAirconvModule(const llvm::Module &module) {\n'
         '  const char *dir = std::getenv("DXMT_AIRCONV_DUMP");\n'
         '  if (!dir || !dir[0])\n'
         '    return;\n'
         '  static std::atomic<uint64_t> counter{0};\n'
         '  uint64_t n = counter.fetch_add(1, std::memory_order_relaxed);\n'
         '  char stem[64];\n'
         '  std::snprintf(stem, sizeof(stem), "airconv_%d_%llu", (int)getpid(),\n'
         '                (unsigned long long)n);\n'
         '  std::string base = std::string(dir) + "/" + stem;\n'
         '  std::string text;\n'
         '  raw_string_ostream stream(text);\n'
         '  module.print(stream, nullptr);\n'
         '  stream.flush();\n'
         '  if (FILE *fp = std::fopen((base + ".ll").c_str(), "wb")) {\n'
         '    std::fwrite(text.data(), 1, text.size(), fp);\n'
         '    std::fclose(fp);\n'
         '  }\n'
         '  std::string index;\n'
         '  for (const llvm::Function &function : module)\n'
         '    index += function.getName().str() + "\\n";\n'
         '  if (FILE *fp = std::fopen((std::string(dir) + "/index.txt").c_str(), "ab")) {\n'
         '    std::string line = std::string(stem) + " " + std::to_string(text.size()) + " bytes\\n" + index;\n'
         '    std::fwrite(line.data(), 1, line.size(), fp);\n'
         '    std::fclose(fp);\n'
         '  }\n'
         '}\n'
         '\n'
         'void MetallibWriter::Write(const llvm::Module &module, raw_ostream &OS) {\n'
         '  MadeiraDumpAirconvModule(module);\n'),
        ('  header.Platform = Platform::MTLBPlatform_macOS;',
         '  header.Platform = Platform::MTLBPlatform_iOS;'),
        ('  header.VersionMajor = 2;\n  header.VersionMinor = 7;',
         '  header.VersionMajor = 2;\n  header.VersionMinor = 6;'),
        ('  header.OS = OS::MTLBOS_macOS;',
         '  header.OS = OS::MTLBOS_iOS;'),
        ('  header.OSVersionMajor = 14;\n  header.OSVersionMinor = 4;',
         '  header.OSVersionMajor = 15;\n  header.OSVersionMinor = 0;'),
        # one per function type (vertex, fragment, object, mesh, kernel)
        ('          .airVersionMajor = 2,\n          .airVersionMinor = 6,\n          .languageVersionMajor = 3,\n          .languageVersionMinor = 1,',
         '          .airVersionMajor = 2,\n          .airVersionMinor = 4,\n          .languageVersionMajor = 2,\n          .languageVersionMinor = 4,',
         None),
    ), ('MTLBPlatform_iOS', 'header.Platform = Platform::MTLBPlatform_iOS;', 'MadeiraDumpAirconvModule', 'DXMT_AIRCONV_DUMP',
        'header.VersionMajor = 2;', 'header.VersionMinor = 6;',
        'header.OS = OS::MTLBOS_iOS;', 'header.OSVersionMajor = 15;',
        'header.OSVersionMinor = 0;')),
)

for relative, pairs, markers in airconv_files:
    src = (source_root / relative).read_text(encoding='utf-8')
    for entry in pairs:
        original, replacement = entry[0], entry[1]
        want = entry[2] if len(entry) > 2 else 1
        count = src.count(original)
        if want is None:
            if count < 1:
                raise SystemExit(f'{relative}: no match for {original!r}')
        elif count != want:
            raise SystemExit(f'{relative}: expected {want} match(es), found {count}: {original!r}')
        src = src.replace(original, replacement)
    out = output_root / relative
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(src, encoding='utf-8')
    written = out.read_text(encoding='utf-8')
    for marker in markers:
        if marker not in written:
            raise SystemExit(f'{relative}: {marker!r} missing from the written file')
    if 'air64-apple-macosx' in written:
        raise SystemExit(f'{relative}: a macOS AIR target survives')
    print(f'iOS {sys.argv[3]} airconv stamps: {relative}')


# ---------------------------------------------------------------------------
# iOS 15.6: bisect the one thing the device still refuses.
#
# The D3D11 path dies inside Apple's Metal compiler -- AGXMetal13_3 raises
# "Compiler encountered an internal error" from newRenderPipelineStateWithDescriptor,
# i.e. while the compiler service reads the AIR module -- exactly when a fragment
# shader reads a texture.  Everything else works on this device: MSL argument
# buffers, direct [[texture(n)]] binding, and metadata-declared argument buffers
# all build pipelines (measured; Documents/metal-selftest-A-D on the iPad).
#
# So the difference is in the AIR *shape* airconv emits.  This section adds one
# switch, MADEIRA_AIRCONV_VARIANT (env, read from madeira.cfg), that changes that
# shape without a rebuild per variant:
#
#   0 (default) nothing changed -- repro
#   1           air.max_textures 128 -> 31   (128 is macOS's; an iOS device's
#               per-stage texture argument table is 31, and only a shader that
#               actually uses a texture has to make that claim real)
#   2           drop the per-texture/sampler 64-bit metadata member (the
#               `air.indirect_constant` group); the shader is fed constants
#   3           both
#
# The switch is a runtime env var, so one build answers all of them: set the
# variant in madeira.cfg, launch, read the dump and the PSO error.
probe_header = """#pragma once

#include <cstdlib>

/* See build/dxmt-ios/prepare-compat.py: MADEIRA_AIRCONV_VARIANT changes the AIR
 * shape so the device can bisect what Apple's Metal compiler refuses. */
namespace dxmt::airconv_probe {

inline int variant() {
  static const int v = [] {
    const char *s = std::getenv("MADEIRA_AIRCONV_VARIANT");
    return s ? std::atoi(s) : 0;
  }();
  return v;
}

/* 1 / 3: declare air.max_textures as 31 instead of 128. */
inline bool textures_31() { return variant() == 1 || variant() >= 3; }

/* 2 / 3: leave the per-texture/sampler metadata member out of the argument
 * buffer and feed the shader the constants it would have read: array length 1
 * (clamp a 2D index to 0) and minLOD clamp 0.  TextureMetadata(1, 0.0f). */
inline bool drop_metadata() { return variant() == 2 || variant() >= 3; }

} // namespace dxmt::airconv_probe
"""
probe_out = output_root / 'airconv/ios15_probe.hpp'
probe_out.parent.mkdir(parents=True, exist_ok=True)
probe_out.write_text(probe_header, encoding='utf-8')
if 'MADEIRA_AIRCONV_VARIANT' not in probe_out.read_text(encoding='utf-8'):
    raise SystemExit('ios15_probe.hpp: the switch went missing from the file')
print(f'iOS {sys.argv[3]} airconv variant switch: airconv/ios15_probe.hpp')

CONST = ('llvm::ConstantInt::get(llvm::Type::getInt64Ty(ctx.builder.getContext()), '
         '1ull << 32)')
variant_files = (
    ('airconv/airconv_context.cpp', (
        ('#include "airconv_context.hpp"\n',
         '#include "airconv_context.hpp"\n#include "ios15_probe.hpp"\n'),
        ('  M.addModuleFlag(Module::ModFlagBehavior::Max, "air.max_textures", 128);',
         '  /* 128 is macOS\'s per-stage texture count; an iOS device is 31. */\n'
         '  M.addModuleFlag(\n'
         '    Module::ModFlagBehavior::Max, "air.max_textures",\n'
         '    dxmt::airconv_probe::textures_31() ? 31 : 128\n'
         '  );'),
    ), ('dxmt::airconv_probe::textures_31()',)),
    ('airconv/dxbc_converter.cpp', (
        ('#include "dxbc_converter.hpp"\n',
         '#include "dxbc_converter.hpp"\n#include "ios15_probe.hpp"\n'),
        ('    sampler.arg_metadata_index = binding_table.DefineInteger64(\n'
         '      "meta_s" + std::to_string(range_id), attr_index + 2\n'
         '    );',
         '    /* Defined even when the member is dropped: the reader below captures\n'
         '     * it by value, and an uninitialised index would be UB. */\n'
         '    sampler.arg_metadata_index = 0;\n'
         '    if (!dxmt::airconv_probe::drop_metadata())\n'
         '      sampler.arg_metadata_index = binding_table.DefineInteger64(\n'
         '        "meta_s" + std::to_string(range_id), attr_index + 2\n'
         '      );'),
        ('      [=, index = sampler.arg_metadata_index](pvalue) {\n'
         '        // ignore index in SM 5.0\n'
         '        return get_item_in_argbuf_binding_table(binding_table_index, index);\n'
         '      }',
         '      [=, index = sampler.arg_metadata_index](pvalue) -> IRValue {\n'
         '        if (dxmt::airconv_probe::drop_metadata())\n'
         '          return make_irvalue([=](context ctx) -> pvalue { return ' + CONST + '; });\n'
         '        return get_item_in_argbuf_binding_table(binding_table_index, index);\n'
         '      }'),
        ('    srv.arg_metadata_index = binding_table.DefineInteger64(\n'
         '      "meta_t" + std::to_string(range_id), attr_index + 1\n'
         '    );',
         '    srv.arg_metadata_index = 0;  /* see the sampler above */\n'
         '    if (!dxmt::airconv_probe::drop_metadata())\n'
         '      srv.arg_metadata_index = binding_table.DefineInteger64(\n'
         '        "meta_t" + std::to_string(range_id), attr_index + 1\n'
         '      );'),
        ('        [=, index = srv.arg_metadata_index](pvalue) {\n'
         '          // ignore index in SM 5.0\n'
         '          return get_item_in_argbuf_binding_table(binding_table_index, index);\n'
         '        },\n'
         '        false',
         '        [=, index = srv.arg_metadata_index](pvalue) -> IRValue {\n'
         '          if (dxmt::airconv_probe::drop_metadata())\n'
         '            return make_irvalue([=](context ctx) -> pvalue { return ' + CONST + '; });\n'
         '          return get_item_in_argbuf_binding_table(binding_table_index, index);\n'
         '        },\n'
         '        false'),
    ), ('dxmt::airconv_probe::drop_metadata()',)),
    ('dxmt/dxmt_context.cpp', (
        ('#include "util_madeira_switch.hpp"\n',
         '#include "util_madeira_switch.hpp"\n#include "../airconv/ios15_probe.hpp"\n'),
        ('      encoded_buffer[arg.StructurePtrOffset + 2] = (uint64_t)std::bit_cast<uint32_t>(sampler->lod_bias);',
         '      if (!dxmt::airconv_probe::drop_metadata())\n'
         '        encoded_buffer[arg.StructurePtrOffset + 2] = (uint64_t)std::bit_cast<uint32_t>(sampler->lod_bias);'),
        ('          encoded_buffer[arg.StructurePtrOffset + 1] = TextureMetadata(srv.texture->arrayLength(viewIdChecked), min_lod);',
         '          if (!dxmt::airconv_probe::drop_metadata())\n'
         '            encoded_buffer[arg.StructurePtrOffset + 1] = TextureMetadata(srv.texture->arrayLength(viewIdChecked), min_lod);'),
    ), ('dxmt::airconv_probe::drop_metadata()',)),
)

for relative, pairs, markers in variant_files:
    # Read what the section above left behind when it wrote this file, not the
    # pristine source: several of these files already carry the iOS AIR stamps,
    # and re-reading source_root here would write them back to macOS -- the same
    # silent drop the note at the top of this script is about.
    out = output_root / relative
    src = (out if out.exists() else source_root / relative).read_text(encoding='utf-8')
    for entry in pairs:
        original, replacement = entry[0], entry[1]
        count = src.count(original)
        if count != 1:
            raise SystemExit(f'{relative}: expected 1 match, found {count}: {original[:70]!r}')
        src = src.replace(original, replacement)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(src, encoding='utf-8')
    written = out.read_text(encoding='utf-8')
    for marker in markers:
        if marker not in written:
            raise SystemExit(f'{relative}: {marker!r} missing from the written file')
    print(f'iOS {sys.argv[3]} airconv variant switch: {relative}')
