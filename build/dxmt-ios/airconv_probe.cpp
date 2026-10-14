/* airconv_probe.cpp - the airconv half of the on-device probe, plain C++.
 *
 * Kept in its own translation unit because the Windows typedefs these headers
 * pull in (windows_base.h) clash with Foundation's BOOL/INT when the same TU
 * also imports Metal; metal_probe.mm talks to this through a C ABI instead.
 *
 * Reproduces exactly what airconv_cli.cpp does, so the Metal compiler can be
 * asked whether it accepts airconv's output for a shader that reads a texture --
 * the shape that kills the D3D11 path with "Compiler encountered an internal
 * error" while the OS accepts plain Metal shaders of every shape we tried.
 */
#include "airconv_context.hpp"
#include "airconv_public.h"
#include "metallib_writer.hpp"
#include "dxbc_converter.hpp"

#include "llvm/IR/DiagnosticInfo.h"
#include "llvm/IR/DiagnosticPrinter.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace llvm;

/* Collects whatever LLVM would otherwise print, and never aborts: the module
 * this probe builds is the one Apple's Metal compiler reads, so its diagnostics
 * are the interesting part. */
struct RecordingDiagnosticHandler : public llvm::DiagnosticHandler {
    std::string *out;
    explicit RecordingDiagnosticHandler(std::string *o) : out(o) {}
    bool handleDiagnostics(const llvm::DiagnosticInfo &info) override {
        llvm::raw_string_ostream stream(*out);
        llvm::DiagnosticPrinterRawOStream printer(stream);
        info.print(printer);
        stream << '\n';
        stream.flush();
        return true;
    }
};

namespace dxmt::dxbc {
/* airconv_cli.cpp declares this itself: it is not in a header. */
llvm::Error convertDXBC(
    sm50_shader_t pShader, const char *name, llvm::LLVMContext &context,
    llvm::Module &module, SM50_SHADER_COMPILATION_ARGUMENT_DATA *pArgs
);
} // namespace dxmt::dxbc

extern "C" int madeira_airconv_probe(const void *dxbc, unsigned len, int mode,
                                     void *out, unsigned out_cap, unsigned *out_len,
                                     char *ir, unsigned ir_cap, unsigned *ir_len,
                                     char *note, unsigned note_cap) {
    std::string text;
    std::string raw_diag;
    std::string ir_text;
    std::vector<char> bytes;

    if (!dxbc || !len) { text = "no DXBC"; }
    else {
        LLVMContext context;
        /* parse_shader (dxbc_converter.cpp) turns opaque pointers off before it
         * builds its module, and airconv reads pointer element types all over
         * (getNonOpaquePointerElementType); without this the probe asserts on the
         * first fixture.  Same setting, so the module this probe hands Metal is
         * the one the D3D11 path would hand it. */
        context.setOpaquePointers(false);
        /* Record diagnostics instead of letting the default handler abort the
         * process: airconv's own LLVM is the first one to see this module, so a
         * fatal diagnostic here is the message the Metal compiler would also
         * have complained about -- and the last version of this probe died
         * before it could say anything. */
        context.setDiagnosticHandler(std::make_unique<RecordingDiagnosticHandler>(&raw_diag));
        Module module("default", context);
        dxmt::initializeModule(module);

        sm50_shader_t sm50 = nullptr;
        sm50_error_t err = nullptr;
        if (SM50Initialize(dxbc, len, &sm50, nullptr, &err)) {
            text = std::string("SM50Initialize: ") + (err ? SM50GetErrorMessageString(err) : "failed");
            if (err) SM50FreeError(err);
        } else {
            std::unique_ptr<dxmt::dxbc::SM50ShaderInternal> hold;
            auto shader = dxmt::dxbc::with_parsed_program((dxmt::dxbc::SM50ShaderInternal *)sm50, hold);

            SM50_SHADER_COMMON_DATA data;
            /* The D3D11 runtime takes this from the device's Metal version, which
             * on iOS 15.6 lands on the 3.1 arm; mode 1 selects the 3.2 arm. */
            data.metal_version = (mode == 1) ? SM50_SHADER_METAL_320 : SM50_SHADER_METAL_310;
            data.next = 0;
            data.type = SM50_SHADER_COMMON;

            if (Error e = dxmt::dxbc::convertDXBC(shader, "shader_main", context, module,
                                                  (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&data)) {
                text = std::string("convertDXBC: ") + toString(std::move(e));
            } else {
                dxmt::runOptimizationPasses(module);
                {
                    std::string verify_text;
                    llvm::raw_string_ostream vstream(verify_text);
                    if (llvm::verifyModule(module, &vstream)) {
                        text = std::string("verifyModule: ") + verify_text;
                    }
                    vstream.flush();
                }
                dxmt::linkMSAD(module);
                dxmt::linkSamplePos(module);
                dxmt::linkTessellation(module);
                std::string bitcode;
                raw_string_ostream stream(bitcode);
                dxmt::metallib::MetallibWriter writer;
                writer.Write(module, stream);
                stream.flush();
                bytes.assign(bitcode.begin(), bitcode.end());
                /* The IR text is what lets a failing shader be diffed against the
                 * ones Apple's LLVM accepts: the compiler service aborts inside
                 * its own LLVM while reading the module, so the construct it
                 * chokes on is in here. */
                std::string ir;
                raw_string_ostream ir_stream(ir);
                module.print(ir_stream, nullptr);
                ir_stream.flush();
                ir_text = ir;
                text = "ok";
            }
            SM50Destroy(sm50);
        }
    }

    if (out_len) *out_len = (unsigned)bytes.size();
    if (out && out_cap) {
        if (bytes.size() > out_cap) text = "output buffer too small";
        else if (!bytes.empty()) memcpy(out, bytes.data(), bytes.size());
    }
    if (ir_len) *ir_len = (unsigned)ir_text.size();
    if (ir && ir_cap && !ir_text.empty()) {
        size_t n = ir_text.size() < ir_cap ? ir_text.size() : ir_cap;
        memcpy(ir, ir_text.data(), n);
    }
    /* The diagnostics ride along in the report without changing the verdict:
     * warnings are normal here, and only a failed conversion is a failure. */
    bool ok = (text == "ok");
    if (!raw_diag.empty()) text += (ok ? " | diagnostics: " : " | diagnostics: ") + raw_diag;
    if (note && note_cap) { strncpy(note, text.c_str(), note_cap - 1); note[note_cap - 1] = 0; }
    return ok ? 0 : -1;
}
