/* airconv_probe.mm - on-device airconv + Metal probe, C ABI.
 *
 * Why this lives in the app's static library: the two questions this answers
 * cannot be asked from Swift without new Xcode files, and the ObjC spellings of
 * the Metal calls are already known here (the d3d12 path uses the same
 * newLibraryWithData: API through its generated shim).
 *
 * What it does, per run:
 *   1. for every DXBC fixture in a directory, run airconv exactly the way
 *      airconv_cli.cpp does (initializeModule -> SM50Initialize ->
 *      convertDXBC -> optimise -> linkMSAD/SamplePos/Tessellation ->
 *      MetallibWriter) and keep the .metallib bytes;
 *   2. hand those bytes to Metal: newLibraryWithData, newFunctionWithName, and
 *      - the step that fails in the D3D11 path - newRenderPipelineStateWithDescriptor.
 *
 * That reproduces "Compiler encountered an internal error" with no Wine, no
 * D3D11 and no game in the loop, so airconv's codegen can be bisected in
 * seconds.  Everything is reported as text; the caller writes it out.
 */
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>

#include "airconv_context.hpp"
#include "airconv_public.h"
#include "dxbc_converter.hpp"
#include "metallib_writer.hpp"

#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

#include <dirent.h>
#include <string>
#include <vector>
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <memory>

using namespace llvm;

namespace {

std::string metal_version_name(int mode) {
    return mode == 1 ? "SM50_SHADER_METAL_320" : "SM50_SHADER_METAL_310";
}

/* DXBC -> metallib bytes, mirroring airconv_cli.cpp.  Returns 0 or a negative
 * code; `note` explains any failure. */
int airconv_to_metallib(const void *dxbc, unsigned len, int mode,
                        std::vector<char> &out, std::string &note) {
    LLVMContext context;
    Module module("default", context);
    dxmt::initializeModule(module);

    sm50_shader_t sm50 = nullptr;
    sm50_error_t err = nullptr;
    if (SM50Initialize(dxbc, len, &sm50, nullptr, &err)) {
        note = std::string("SM50Initialize: ") + (err ? SM50GetErrorMessageString(err) : "failed");
        if (err) SM50FreeError(err);
        return -2;
    }
    std::unique_ptr<dxmt::dxbc::SM50ShaderInternal> hold;
    auto shader = dxmt::dxbc::with_parsed_program((dxmt::dxbc::SM50ShaderInternal *)sm50, hold);

    SM50_SHADER_COMMON_DATA data;
    data.metal_version = (mode == 1) ? SM50_SHADER_METAL_320 : SM50_SHADER_METAL_310;
    data.next = 0;
    data.type = SM50_SHADER_COMMON;

    if (Error e = dxmt::dxbc::convertDXBC(shader, "shader_main", context, module,
                                          (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&data)) {
        note = std::string("convertDXBC: ") + toString(std::move(e));
        SM50Destroy(sm50);
        return -3;
    }
    SM50Destroy(sm50);

    dxmt::runOptimizationPasses(module);
    dxmt::linkMSAD(module);
    dxmt::linkSamplePos(module);
    dxmt::linkTessellation(module);

    std::string bytes;
    raw_string_ostream stream(bytes);
    dxmt::metallib::MetallibWriter writer;
    writer.Write(module, stream);
    stream.flush();
    out.assign(bytes.begin(), bytes.end());
    note = "ok";
    return 0;
}

/* 0 = pipeline created, otherwise the Metal error, in `note`. */
int metal_pipeline(const std::vector<char> &vs, const std::vector<char> &ps,
                   id<MTLDevice> device, std::string &note) {
    dispatch_data_t vs_data = dispatch_data_create(vs.data(), vs.size(), nullptr,
                                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t ps_data = dispatch_data_create(ps.data(), ps.size(), nullptr,
                                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> vs_lib = [device newLibraryWithData:vs_data error:&error];
    if (!vs_lib) {
        note = std::string("VS newLibraryWithData: ") + [[error localizedDescription] UTF8String];
        dispatch_release(ps_data); dispatch_release(vs_data);
        return -1;
    }
    id<MTLLibrary> ps_lib = [device newLibraryWithData:ps_data error:&error];
    if (!ps_lib) {
        note = std::string("PS newLibraryWithData: ") + [[error localizedDescription] UTF8String];
        [vs_lib release];
        dispatch_release(ps_data); dispatch_release(vs_data);
        return -2;
    }
    id<MTLFunction> vs_fn = [vs_lib newFunctionWithName:@"shader_main"];
    id<MTLFunction> ps_fn = [ps_lib newFunctionWithName:@"shader_main"];
    if (!vs_fn || !ps_fn) {
        note = "shader_main missing from the metallib";
        if (vs_fn) [vs_fn release];
        if (ps_fn) [ps_fn release];
        [vs_lib release]; [ps_lib release];
        dispatch_release(ps_data); dispatch_release(vs_data);
        return -3;
    }
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vs_fn;
    desc.fragmentFunction = ps_fn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pso) {
        note = std::string("newRenderPipelineState: ") + [[error localizedDescription] UTF8String];
    } else {
        note = "pipeline OK";
        [pso release];
    }
    [desc release];
    [vs_fn release]; [ps_fn release];
    [vs_lib release]; [ps_lib release];
    dispatch_release(ps_data); dispatch_release(vs_data);
    return pso ? 0 : -4;
}

std::vector<std::string> dxbc_files(const char *dir, const char *prefix) {
    std::vector<std::string> out;
    DIR *d = opendir(dir);
    if (!d) return out;
    struct dirent *e;
    while ((e = readdir(d))) {
        std::string name = e->d_name;
        if (name.size() > 5 && name.compare(name.size() - 5, 5, ".dxbc") == 0 &&
            name.compare(0, strlen(prefix), prefix) == 0)
            out.push_back(name);
    }
    closedir(d);
    std::sort(out.begin(), out.end());
    return out;
}

bool read_file(const std::string &path, std::vector<char> &out) {
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0) { fclose(f); return false; }
    out.resize((size_t)size);
    size_t got = fread(out.data(), 1, (size_t)size, f);
    fclose(f);
    return got == (size_t)size;
}

} // namespace

extern "C" int madeira_airconv_probe(const void *dxbc, unsigned len, int mode,
                                     void *out, unsigned out_cap, unsigned *out_len,
                                     char *note, unsigned note_cap);

int madeira_airconv_probe(const void *dxbc, unsigned len, int mode,
                          void *out, unsigned out_cap, unsigned *out_len,
                          char *note, unsigned note_cap) {
    std::vector<char> bytes;
    std::string text;
    int rc = airconv_to_metallib(dxbc, len, mode, bytes, text);
    if (out_len) *out_len = (unsigned)bytes.size();
    if (rc == 0 && bytes.size() > out_cap) { rc = -4; text = "output buffer too small"; }
    if (rc == 0 && out && bytes.size()) memcpy(out, bytes.data(), bytes.size());
    if (note && note_cap) {
        strncpy(note, text.c_str(), note_cap - 1);
        note[note_cap - 1] = 0;
    }
    return rc;
}

/* Run every fixture in `dir` and report as text.  Returns 0 when every pipeline
 * was created, 1 when at least one step failed, 2 for a bad directory. */
extern "C" int madeira_metal_probe_run(const char *dir, const char *mode_text,
                                       char *report, unsigned report_cap);

int madeira_metal_probe_run(const char *dir, const char *mode_text,
                            char *report, unsigned report_cap) {
    std::string text = "--- airconv + Metal probe (mode ";
    text += mode_text ? mode_text : "?";
    text += ") ---\n";
    int mode = (mode_text && strcmp(mode_text, "320") == 0) ? 1 : 0;

    std::vector<std::string> vs_files = dxbc_files(dir, "vs_");
    std::vector<std::string> ps_files = dxbc_files(dir, "ps_");
    if (vs_files.empty() || ps_files.empty()) {
        text += "no vs_*.dxbc / ps_*.dxbc in ";
        text += dir;
        text += "\n";
        if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
        return 2;
    }

    std::vector<char> vs_dxbc, vs_metallib;
    std::string note;
    std::string vs_path = std::string(dir) + "/" + vs_files[0];
    if (!read_file(vs_path, vs_dxbc)) { text += "cannot read " + vs_path + "\n"; }
    else if (airconv_to_metallib(vs_dxbc.data(), (unsigned)vs_dxbc.size(), mode, vs_metallib, note) != 0) {
        text += vs_files[0] + ": airconv FAILED: " + note + "\n";
    } else {
        text += vs_files[0] + ": airconv OK, " + std::to_string(vs_metallib.size()) + " bytes\n";
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        text += "no Metal device\n";
        if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
        return 1;
    }

    int failures = 0;
    for (size_t i = 0; i < ps_files.size(); i++) {
        std::vector<char> ps_dxbc, ps_metallib;
        std::string ps_path = std::string(dir) + "/" + ps_files[i];
        if (!read_file(ps_path, ps_dxbc)) { text += ps_files[i] + ": cannot read\n"; failures++; continue; }
        if (airconv_to_metallib(ps_dxbc.data(), (unsigned)ps_dxbc.size(), mode, ps_metallib, note) != 0) {
            text += ps_files[i] + ": airconv FAILED: " + note + "\n";
            failures++;
            continue;
        }
        text += ps_files[i] + ": airconv OK, " + std::to_string(ps_metallib.size()) + " bytes";
        if (vs_metallib.empty()) { text += " (no VS metallib, skipped Metal)\n"; failures++; continue; }
        int rc = metal_pipeline(vs_metallib, ps_metallib, device, note);
        if (rc != 0) { text += " | Metal FAILED: " + note + "\n"; failures++; }
        else text += " | " + note + "\n";
    }

    if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
    return failures ? 1 : 0;
}
