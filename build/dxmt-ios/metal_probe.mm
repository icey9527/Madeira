/* metal_probe.mm - the Metal half of the on-device probe, Objective-C++.
 *
 * Deliberately free of airconv and Windows headers: windows_base.h's typedefs
 * clash with Foundation's when both are in one translation unit, so the airconv
 * side lives in airconv_probe.cpp and the two meet at a C ABI.
 *
 * For each fixture in a directory it asks airconv for a .metallib and hands it
 * to Metal -- newLibraryWithData, newFunctionWithName, then
 * newRenderPipelineStateWithDescriptor, which is where the D3D11 path dies,
 * with no Wine and no D3D11 in this loop.
 *
 * Each fragment fixture is then run through three pipelines rather than one:
 * the pair airconv itself produces, one that swaps the vertex side for a
 * hand-written MSL function, and one all-MSL control.  A render pipeline
 * requires a vertex function, so "fragment alone with no VS" is not a valid
 * Metal descriptor and cannot answer that question.  One probe run already
 * showed the airconv pair failing even for a fragment module that carries no
 * function attributes at all, so "which side is refused" has to be answered
 * before any theory about the bitcode's attributes can be tested. */
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>

#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

extern "C" int madeira_airconv_probe(const void *dxbc, unsigned len, int mode,
                                     void *out, unsigned out_cap, unsigned *out_len,
                                     char *ir, unsigned ir_cap, unsigned *ir_len,
                                     char *note, unsigned note_cap);

namespace {

/* Progress goes to a file as it happens: the last time this ran the app died
 * before anything was written, and a crash inside the probe cannot be reported
 * by the caller.  Appending + fflush means the last line survives. */
std::string g_progress_path;

/* POSIX-only, and the very first thing the entry point does: if the app dies
 * before this file exists, the call itself never ran (Swift/C mismatch or a
 * load-time problem), which is a different bug from a crash inside the probe. */
void trace_posix(const std::string &path, const char *what) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, what, strlen(what));
    (void)write(fd, "\n", 1);
    close(fd);
}
void progress(const std::string &line) {
    if (g_progress_path.empty()) return;
    FILE *f = fopen(g_progress_path.c_str(), "a");
    if (!f) return;
    fputs(line.c_str(), f);
    fputc('\n', f);
    fclose(f);
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

/* The whole error, not just localizedDescription: the domain, the code and the
 * userInfo keys are what say whether a failure came from the compiler service,
 * from the pipeline linkage or from the descriptor itself.  Every UTF8String is
 * checked: converting a nil string raises, and this helper exists to explain a
 * failure, not to add one. */
static std::string error_text(NSError *error) {
    if (!error) return "nil error";
    const char *dom = [[error domain] UTF8String];
    const char *desc = [[error localizedDescription] UTF8String];
    std::string out = std::string(dom ? dom : "?") + " code=" +
                      std::to_string((long)[error code]) + " \"" +
                      (desc ? desc : "?") + "\"";
    NSDictionary *info = [error userInfo];
    if (info) {
        for (id key in info) {
            if ([key isEqualToString:NSLocalizedDescriptionKey]) continue;
            NSString *value = [info objectForKey:key];
            if (![value isKindOfClass:[NSString class]]) value = [value description];
            if (!value) continue;
            const char *ks = [[key description] UTF8String];
            const char *vs = [value UTF8String];
            if (!ks || !vs) continue;
            out += " [";
            out += ks;
            out += "=";
            out += vs;
            out += "]";
        }
    }
    return out;
}

/* 0 = pipeline created, else the failing step's text.  A side may be a metallib
 * airconv produced (as bytes) or a function Apple compiled from MSL.  A render
 * pipeline requires both sides, so every row supplies both. */
static int metal_pipeline(const std::vector<char> *vs_metallib, id<MTLFunction> vs_fn_in,
                          const std::vector<char> *ps_metallib, id<MTLFunction> ps_fn_in,
                          id<MTLDevice> device, std::string &note) {
    if (!vs_metallib && !vs_fn_in) { note = "no vertex function"; return -1; }
    if (!ps_metallib && !ps_fn_in) { note = "no fragment function"; return -1; }
    id<MTLLibrary> vs_lib = nil, ps_lib = nil;
    id<MTLFunction> vs_fn = vs_fn_in, ps_fn = ps_fn_in;
    dispatch_data_t vs_data = nullptr, ps_data = nullptr;
    if (!vs_fn) {
        vs_data = dispatch_data_create(vs_metallib->data(), vs_metallib->size(), nullptr,
                                       DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error = nil;
        vs_lib = [device newLibraryWithData:vs_data error:&error];
        if (!vs_lib) {
            note = std::string("VS newLibraryWithData: ") + error_text(error);
            dispatch_release(vs_data);
            return -2;
        }
        vs_fn = [vs_lib newFunctionWithName:@"shader_main"];
        if (!vs_fn) {
            note = "shader_main missing from the VS metallib";
            [vs_lib release]; dispatch_release(vs_data);
            return -3;
        }
    }
    if (!ps_fn) {
        ps_data = dispatch_data_create(ps_metallib->data(), ps_metallib->size(), nullptr,
                                       DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error = nil;
        ps_lib = [device newLibraryWithData:ps_data error:&error];
        if (!ps_lib) {
            note = std::string("PS newLibraryWithData: ") + error_text(error);
            if (vs_lib) { [vs_fn release]; [vs_lib release]; dispatch_release(vs_data); }
            dispatch_release(ps_data);
            return -4;
        }
        ps_fn = [ps_lib newFunctionWithName:@"shader_main"];
        if (!ps_fn) {
            note = "shader_main missing from the PS metallib";
            if (vs_lib) { [vs_fn release]; [vs_lib release]; dispatch_release(vs_data); }
            [ps_lib release]; dispatch_release(ps_data);
            return -5;
        }
    }
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vs_fn;
    desc.fragmentFunction = ps_fn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError *error = nil;
    id<MTLRenderPipelineState> pso =
        [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pso) note = std::string("newRenderPipelineState: ") + error_text(error);
    else { note = "pipeline OK"; [pso release]; }
    [desc release];
    if (vs_lib) { [vs_fn release]; [vs_lib release]; dispatch_release(vs_data); }
    if (ps_lib) { [ps_fn release]; [ps_lib release]; dispatch_release(ps_data); }
    return pso ? 0 : -6;
}

std::string airconv_fixture(const std::string &dir, const std::string &name, int mode,
                            std::vector<char> &metallib) {
    progress(name + ": read");
    std::vector<char> dxbc;
    if (!read_file(dir + "/" + name, dxbc)) return "cannot read";
    progress(name + ": " + std::to_string(dxbc.size()) + " bytes of DXBC");
    std::string note(512, 0);
    unsigned out_len = 0;
    int rc = madeira_airconv_probe(dxbc.data(), (unsigned)dxbc.size(), mode,
                                   nullptr, 0, &out_len, nullptr, 0, nullptr,
                                   &note[0], (unsigned)note.size());
    if (out_len == 0) { progress(name + ": airconv produced nothing: " + note); return "airconv: " + note; }
    progress(name + ": airconv wants " + std::to_string(out_len) + " bytes");
    std::vector<char> ir(1u << 22);
    unsigned ir_len = 0;
    metallib.resize(out_len);
    note.assign(512, 0);
    rc = madeira_airconv_probe(dxbc.data(), (unsigned)dxbc.size(), mode,
                               metallib.data(), (unsigned)metallib.size(), &out_len,
                               ir.data(), (unsigned)ir.size(), &ir_len,
                               &note[0], (unsigned)note.size());
    if (rc != 0) { progress(name + ": airconv FAILED: " + note); return "airconv: " + note; }
    if (metallib.empty()) {
        progress(name + ": airconv returned rc=0 and no bytes: " + note);
        return "airconv returned nothing: " + std::string(note);
    }
    if (ir_len) {
        FILE *f = fopen((dir + "/" + name + ".ll").c_str(), "wb");
        if (f) { fwrite(ir.data(), 1, ir_len, f); fclose(f); }
    }
    progress(name + ": airconv OK, " + std::to_string(metallib.size()) + " bytes of metallib, " +
             std::to_string(ir_len) + " bytes of IR");
    return "";
}

/* Hand-written MSL that matches the AIR shape airconv emits, so one variable at
 * a time can be swapped.
 *
 * The vertex function is the shape of the VS airconv generated for d3dchk5-4:
 * it returns two float4s (position first) and takes no input layout, only the
 * vertex-id family.  The fragment function is the shape of that module's PS:
 * it takes the incoming position directly rather than a [[stage_in]] struct.
 * The hand-written cases A-G in metal-cases/ all pair Apple's fragment shaders
 * with Apple's own VSOut{pos,uv} vertex stage, so none of them has ever
 * exercised airconv's interface shape -- this is that gap. */
static const char *kMslVertex =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VSOut { float4 pos [[position]]; float4 tc0; };\n"
    "vertex VSOut shader_main(uint vid [[vertex_id]], uint base [[base_vertex]]) {\n"
    "    float2 t[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "    float2 p = t[vid - base];\n"
    "    VSOut o;\n"
    "    o.pos = float4(p, 0.0, 1.0);\n"
    "    o.tc0 = float4(p * 0.5 + 0.5, 0.0, 1.0);\n"
    "    return o;\n"
    "}\n";

static const char *kMslFragment =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "fragment float4 shader_main(float4 pos [[position]]) {\n"
    "    return float4(1.0, 0.0, 1.0, 1.0);\n"
    "}\n";

/* One row per vertex/fragment combination to try.  Row 0 is the pair the D3D11
 * path uses (airconv's own VS with airconv's own PS); rows 1 and 2 replace one
 * side at a time, and row 3 is the all-MSL control.  Row 2 exists because every
 * airconv pair failed while MSL-VS + airconv-PS passed for ps_cbuffer: the
 * airconv vertex module has to be ruled in or out on its own before any
 * fragment-side theory is worth testing. */
struct Pair {
    const char *what;
    int vs_msl; /* 1 = use Apple's MSL vertex function */
    int ps_msl; /* 1 = use Apple's MSL fragment function */
};
static const Pair kPairs[] = {
    { "airconv VS + airconv PS",   0, 0 },
    { "MSL VS + airconv PS",       1, 0 },
    { "airconv VS + MSL PS",       0, 1 },
    { "MSL VS + MSL PS (control)", 1, 1 },
};

/* One .metallib built by Apple's own frontend, from the source above.  Returns
 * the compiler's message on failure: if this does not build, the interface is
 * not writable in MSL at all and the pairs below mean nothing. */
static id<MTLFunction> msl_function(id<MTLDevice> device, const char *source, const char *what,
                                    std::string &why) {
    NSError *error = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:[NSString stringWithUTF8String:source]
                                              options:nil
                                                error:&error];
    if (!lib) { why = std::string(what) + ": " + error_text(error); return nil; }
    id<MTLFunction> fn = [lib newFunctionWithName:@"shader_main"];
    if (!fn) why = std::string(what) + ": shader_main missing";
    [lib release];
    return fn;
}

} // namespace

extern "C" int madeira_metal_probe_run(const char *dir, const char *mode_text,
                                       char *report, unsigned report_cap) {
    /* Both of these are POSIX-only and come before any C++ object exists, so
     * they survive a crash, an abort or a kill: entry.txt says the entry point
     * was reached, stderr.txt catches whatever LLVM prints before it dies. */
    std::string dir_str = dir ? dir : "";
    trace_posix(dir_str + "/entry.txt", "entry reached");
    {
        int fd = open((dir_str + "/stderr.txt").c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { dup2(fd, STDERR_FILENO); close(fd); }
    }

    std::string text = "airconv + Metal probe (metal_version ";
    text += (mode_text && strcmp(mode_text, "320") == 0) ? "3.2" : "3.1";
    text += "):\n";
    int mode = (mode_text && strcmp(mode_text, "320") == 0) ? 1 : 0;
    int failures = 0;

    g_progress_path = std::string(dir) + "/progress.txt";
    progress("--- run start, mode " + std::to_string(mode) + " ---");

    std::vector<std::string> vs_files = dxbc_files(dir, "vs_");
    std::vector<std::string> ps_files = dxbc_files(dir, "ps_");
    if (vs_files.empty() && ps_files.empty()) {
        text += "no vs_*.dxbc / ps_*.dxbc in ";
        text += dir;
        text += "\n";
        if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
        return 2;
    }

    /* The VS is one fixture, as in the D3D11 path; the PS is the loop. */
    std::vector<char> vs_metallib;
    bool have_vs = false;
    if (!vs_files.empty()) {
        std::string err = airconv_fixture(dir, vs_files[0], mode, vs_metallib);
        if (!err.empty()) { text += "VS " + vs_files[0] + ": " + err + "\n"; failures++; }
        else {
            have_vs = true;
            text += "VS " + vs_files[0] + ": airconv OK, " +
                    std::to_string(vs_metallib.size()) + " bytes\n";
        }
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { text += "no Metal device\n"; failures++; }

    /* The MSL fixtures.  If Apple's own frontend cannot build airconv's
     * interface from source, the whole comparison is moot, so that is said
     * once, up front. */
    id<MTLFunction> msl_vs = nil, msl_ps = nil;
    std::string msl_vs_why, msl_ps_why;
    if (device) {
        msl_vs = msl_function(device, kMslVertex, "MSL vertex fixture", msl_vs_why);
        if (!msl_vs) { text += msl_vs_why + "\n"; failures++; }
        msl_ps = msl_function(device, kMslFragment, "MSL fragment fixture", msl_ps_why);
        if (!msl_ps) { text += msl_ps_why + "\n"; failures++; }
    }

    for (size_t i = 0; i < ps_files.size(); i++) {
        std::vector<char> ps_metallib;
        std::string perr = airconv_fixture(dir, ps_files[i], mode, ps_metallib);
        if (!perr.empty()) { text += ps_files[i] + ": " + perr + "\n"; failures++; continue; }
        text += ps_files[i] + ": airconv OK, " + std::to_string(ps_metallib.size()) + " bytes\n";
        if (!device) { text += "  (no Metal device; skipped)\n"; failures++; continue; }

        /* Swapping one side at a time is the whole point: airconv's VS paired
         * with airconv's PS is what the D3D11 path does, and if that fails
         * while airconv's PS paired with Apple's MSL VS succeeds, the fault is
         * in how the two airconv modules refer to each other -- not in either
         * module on its own, and not in the attributes the bitcode carries. */
        for (size_t k = 0; k < sizeof(kPairs) / sizeof(kPairs[0]); ++k) {
            const Pair &p = kPairs[k];
            const char *what = p.what;
            progress(std::string(ps_files[i]) + " [" + what + "]: start");
            std::string note;
            int rc;
            if (p.vs_msl && !msl_vs) { rc = -98; note = msl_vs_why; }
            else if (p.ps_msl && !msl_ps) { rc = -98; note = msl_ps_why; }
            else {
                /* A row either brings its own MSL vertex function or uses the
                 * module airconv produced for this fragment. */
                const std::vector<char> *vs_mb = p.vs_msl ? nullptr : &vs_metallib;
                if (vs_mb && !have_vs) {
                    rc = -97;
                    note = "no VS metallib (the airconv VS fixture failed)";
                } else {
                    rc = metal_pipeline(
                        vs_mb, p.vs_msl ? msl_vs : nullptr,
                        p.ps_msl ? nullptr : &ps_metallib, p.ps_msl ? msl_ps : nullptr,
                        device, note);
                }
            }
            progress(std::string(ps_files[i]) + " [" + what + "]: rc=" + std::to_string(rc) +
                     " note=" + note);
            text += "  [";
            text += what;
            text += "] ";
            if (rc == 0) text += note + "\n";
            else { text += "FAILED: " + note + "\n"; failures++; }
        }
    }

    progress(std::string("--- run end, failures=") + std::to_string(failures) + " ---");
    if (msl_vs) [msl_vs release];
    if (msl_ps) [msl_ps release];
    if (report && report_cap) { strncpy(report, text.c_str(), report_cap - 1); report[report_cap - 1] = 0; }
    return failures ? 1 : 0;
}
