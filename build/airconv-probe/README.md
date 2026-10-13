# airconv probe: reproduce the Metal "Compiler encountered an internal error"

The D3D11 path dies in the Metal compiler as soon as a pixel shader **reads** a
texture (`Load` and `Sample` alike), while only *binding* a texture or sampler is
fine.  The on-device self test (`MetalSelfTest` in the app, marker-triggered)
proved the OS itself accepts every shape we tried -- direct bindings and classic
argument buffers alike -- so the failing shape is what **airconv emits**.

This directory makes that reproducible in minutes instead of per-game:

    DXBC fixture  ->  airconv (in process)  ->  .metallib bytes
                  ->  MTLDevice.newLibraryWithData  ->  makeRenderPipelineState
                  ->  Documents/metal-selftest.txt

No Wine, no D3D11, no game.  The airconv call lives in the app's static library
(`build/dxmt-ios/airconv_probe.cpp`, C ABI so Swift can reach it with
`@_silgen_name`), and the fixtures are pushed to `Documents/airconv-probe/`.

## Why not a host CLI

`airconv_cli` is the natural driver, but this project's host LLVM build is turned
down to tablegen only (`-DLLVM_TARGETS_TO_BUILD=` empty in
`build/llvm-ios/build.sh`), so there is no host-side AIR backend to link against.
The iOS LLVM already has it and is already linked into the app, so the probe runs
in process, where one install can also test several codegen variants.

## Fixtures

| file | shader | why |
| --- | --- | --- |
| `vs_simple.dxbc` | `vs_4_0`, `SV_VertexID` only | a vertex shader with no resources, for the pipeline |
| `ps_sample.dxbc` | `ps_4_0`, `tex.Sample(smp, uv)` | the case that kills the D3D11 path |
| `ps_read.dxbc` | `ps_4_0`, `tex.Load(int3(...))` | same failure with no sampler involved |
| `ps_cbuffer.dxbc` | `ps_4_0`, `return tint` from `cbuffer b0` | measured separately: the CB value arrives as 0 on 15.6 |

Regenerate with `build-mkdxbc.bat` (MSVC + `d3dcompiler.lib`, no SDK extras) then
`mkdxbc.exe .`.

## The recipe the probe must mirror

`dxmt/src/airconv/airconv_cli.cpp` is the reference; the probe repeats it:

```cpp
LLVMContext ctx; Module M("default", ctx);
dxmt::initializeModule(M);
SM50Initialize(dxbc, len, &sm50, nullptr, &err);      // + with_parsed_program
dxmt::dxbc::convertDXBC(shader, "shader_main", ctx, M, &data);
dxmt::runOptimizationPasses(M);
dxmt::linkMSAD(M); dxmt::linkSamplePos(M); dxmt::linkTessellation(M);
dxmt::metallib::MetallibWriter().Write(M, stream);    // -> .metallib bytes
```

`SM50_SHADER_COMPILATION_ARGUMENT_DATA` carries the flags the D3D11 path passes,
so the probe should start from exactly those (that is what ships today) and then
change one thing at a time.
