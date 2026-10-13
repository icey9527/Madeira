/* metal_probe.mm - the Metal half of the on-device probe, Objective-C++.
 *
 * Deliberately free of airconv and Windows headers: windows_base.h's typedefs
 * clash with Foundation's when both are in one translation unit, so the airconv
 * side lives in airconv_probe.cpp and the two meet at a C ABI.
 *
 * For each fixture in a directory it asks airconv for a .metallib and then makes
 * Metal load it and build a pipeline -- newLibraryWithData, newFunctionWithName,
 * newRenderPipelineStateWithDescriptor.  That last call is where the D3D11 path
 * dies, with no Wine and no D3D11 in this loop.
 */
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>

#include <dirent.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

extern "C" int madeira_airconv_probe(const void *dxbc, unsigned len, int mode,
                                     void *out, unsigned out_cap, unsigned *out_len,
                                     char *note, unsigned note_cap);

namespace {

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

/* 0 = pipeline created, else the Metal error text. */
int metal_pipeline(const std::vector<char> &vs, const std::vector<char> &ps,
                   id<MTLDevice> device, std::string &note) {
    dispatch_data_t vs_data = dispatch_data_create(vs.data(), vs.size(), nullptr,
                                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t ps_data = dispatch_data_create(ps.data(), ps.size(), nullptr,
                                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> vs_lib = [device newLibraryWithData:vs_data error:&error];
    if (!vs_lib) {
        note = std::string("VS newLibraryWithData: ") +
               (error ? [[error localizedDescription] UTF8String] : "nil error");
        dispatch_release(ps_data); dispatch_release(vs_data);
        return -1;
    }
    id<MTLLibrary> ps_lib = [device newLibraryWithData:ps_data error:&error];
    if (!ps_lib) {
        note = std::string("PS newLibraryWithData: ") +
               (error ? [[error localizedDescription] UTF8String] : "nil error");
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
    id<MTLRenderPipelineState> pso =
        [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pso) {
        note = std::string("newRenderPipelineState: ") +
               (error ? [[error localizedDescription] UTF8String] : "nil error");
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

std::string airconv_fixture(const std::string &dir, const std::string &name, int mode,
                            std::vector<char> &metallib) {
    std::vector<char> dxbc;
    if (!read_file(dir + "/" + name, dxbc)) return "cannot read";
    std::string note(512, 0);
    unsigned out_len = 0;
    int rc = madeira_airconv_probe(dxbc.data(), (unsigned)dxbc.size(), mode,
                                   nullptr, 0, &out_len, &note[0], (unsigned)note.size());
    if (out_len == 0) return "airconv: " + note;
    note.assign(512, 0);
    metallib.resize(out_len);
    rc = madeira_airconv_probe(dxbc.data(), (unsigned)dxbc.size(), mode,
                               metallib.data(), (unsigned)metallib.size(), &out_len,
                               &note[0], (unsigned)note.size());
    if (rc != 0) return "airconv: " + note;
    return "";
}

} // namespace

extern "C" int madeira_metal_probe_run(const char *dir, const char *mode_text,
                                       char *report, unsigned report_cap) {
    std::string text = "airconv + Metal probe (metal_version ";
    text += (mode_text && strcmp(mode_text, "320") == 0) ? "3.2" : "3.1";
    text += "):\n";
    int mode = (mode_text && strcmp(mode_text, "320") == 0) ? 1 : 0;
    int failures = 0;

    std::vector<std::string> vs_files = dxbc_files(dir, "vs_");
    std::vector<std::string> ps_files = dxbc_files(dir, "ps_");
    if (vs_files.empty() || ps_files.empty()) {
        text += "no vs_*.dxbc / ps_*.dxbc in ";
        text += dir;
        text += "\n";
        if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
        return 2;
    }

    std::vector<char> vs_metallib;
    std::string err = airconv_fixture(dir, vs_files[0], mode, vs_metallib);
    if (!err.empty()) { text += vs_files[0] + ": " + err + "\n"; failures++; }
    else text += vs_files[0] + ": airconv OK, " + std::to_string(vs_metallib.size()) + " bytes\n";

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { text += "no Metal device\n"; failures++; }

    for (size_t i = 0; i < ps_files.size(); i++) {
        std::vector<char> ps_metallib;
        std::string perr = airconv_fixture(dir, ps_files[i], mode, ps_metallib);
        if (!perr.empty()) { text += ps_files[i] + ": " + perr + "\n"; failures++; continue; }
        text += ps_files[i] + ": airconv OK, " + std::to_string(ps_metallib.size()) + " bytes";
        if (!device || vs_metallib.empty()) { text += " | skipped Metal\n"; failures++; continue; }
        std::string note;
        int rc = metal_pipeline(vs_metallib, ps_metallib, device, note);
        if (rc != 0) { text += " | Metal FAILED: " + note + "\n"; failures++; }
        else text += " | " + note + "\n";
    }

    if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
    return failures ? 1 : 0;
}
