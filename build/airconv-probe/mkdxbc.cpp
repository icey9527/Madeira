/* mkdxbc - compile the airconv probe fixtures to DXBC blobs (Windows, MSVC).
 *
 * The probe loop this belongs to: DXMT's airconv is handed these DXBC blobs and
 * writes a .metallib; the app then loads that .metallib on the device with
 * newLibraryWithData and reports whether the Metal compiler accepts it.  That
 * reproduces the "Compiler encountered an internal error" that kills the D3D11
 * path when a pixel shader READS a texture, with no Wine and no D3D11 in the
 * loop, so airconv's codegen can be bisected in minutes instead of per-game.
 *
 * Build:  cl /nologo /O2 /MT /EHsc /Fe:mkdxbc.exe mkdxbc.cpp /link d3dcompiler.lib
 * Run:    mkdxbc.exe <output-dir>          (writes four .dxbc files)
 */
#include <windows.h>
#include <d3dcompiler.h>
#include <stdio.h>

#pragma comment(lib, "d3dcompiler.lib")

struct Fixture {
    const char *file;
    const char *entry;
    const char *target;
    const char *source;
};

static const char *vs_source =
    "struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
    "VSOut vs_main(uint id : SV_VertexID) {\n"
    "  float2 t[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
    "  VSOut o; o.pos = float4(t[id], 0, 1); o.uv = o.pos.xy * 0.5 + 0.5; return o;\n"
    "}\n";

static const char *ps_sample_source =
    "struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
    "Texture2D tex : register(t0);\n"
    "SamplerState smp : register(s0);\n"
    "float4 ps_main(VSOut i) : SV_Target { return tex.Sample(smp, i.uv); }\n";

static const char *ps_read_source =
    "struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
    "Texture2D tex : register(t0);\n"
    "float4 ps_main(VSOut i) : SV_Target { return tex.Load(int3(int2(i.pos.xy), 0)); }\n";

static const char *ps_cbuffer_source =
    "struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
    "cbuffer CB : register(b0) { float4 tint; };\n"
    "float4 ps_main(VSOut i) : SV_Target { return tint; }\n";

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : ".";
    Fixture fixtures[] = {
        { "vs_simple.dxbc",   "vs_main", "vs_4_0", vs_source },
        { "ps_sample.dxbc",   "ps_main", "ps_4_0", ps_sample_source },
        { "ps_read.dxbc",     "ps_main", "ps_4_0", ps_read_source },
        { "ps_cbuffer.dxbc",  "ps_main", "ps_4_0", ps_cbuffer_source },
    };
    int i, bad = 0;
    for (i = 0; i < (int)(sizeof fixtures / sizeof fixtures[0]); i++) {
        ID3DBlob *blob = NULL, *err = NULL;
        HRESULT hr = D3DCompile(fixtures[i].source, strlen(fixtures[i].source), fixtures[i].file,
                                NULL, NULL, fixtures[i].entry, fixtures[i].target, 0, 0, &blob, &err);
        printf("%-16s %s hr=0x%08x %s\n", fixtures[i].file, fixtures[i].target,
               (unsigned)hr, SUCCEEDED(hr) ? "OK" : "FAILED");
        if (FAILED(hr)) {
            if (err) printf("    %s\n", (const char *)err->GetBufferPointer());
            bad++;
        } else {
            char path[MAX_PATH];
            _snprintf_s(path, sizeof path, _TRUNCATE, "%s\\%s", dir, fixtures[i].file);
            FILE *f = fopen(path, "wb");
            if (!f) { printf("    cannot write %s\n", path); bad++; }
            else {
                fwrite(blob->GetBufferPointer(), 1, blob->GetBufferSize(), f);
                fclose(f);
                printf("    wrote %s (%u bytes)\n", path, (unsigned)blob->GetBufferSize());
            }
        }
        if (err) err->Release();
        if (blob) blob->Release();
    }
    return bad ? 1 : 0;
}
