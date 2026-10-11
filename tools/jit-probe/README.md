# Madeira JIT Probe

Standalone iOS 15.6 diagnostic App using the production `JITAllocator.c`.
It links UIKit/Foundation and system libraries without FEX, Wine, DXMT or StikJIT.
CI builds it after the compile-only App check and publishes `Madeira-JIT-Probe.ipa`
under the separate `jit-probe` prerelease. The full App's `nightly` release stays
gated on a successful native build.

Install the IPA with TrollStore on the target iPad, without attaching a debugger.
Open the App and tap the test button. Expected results are 42 and then 43 after
rewriting the same code through the RW alias. Share `jit-probe.log` with the share
button. If execution terminates the App, reopen it and share the persisted log
before trying again. File Sharing also exposes the log through the Files App.

The probe is ad-hoc signed with `dynamic-codesigning` and `get-task-allow`.
The main App does not yet have an equivalent tested entitlement configuration.
The probe records code-signing status and device OS, bypasses the existing
`CS_DEBUGGED` readiness gate, and calls no debugger preparation protocol.
It deliberately leaves an execution fault to the OS rather than catching it and
reporting a false success. Logs are flushed before each execution attempt.
Build 2 disables production-only address-space reservation and Metal validation
constructors in the probe. The main App keeps both constructors. A POSIX log
marker is flushed on entry to `main`, before UIKit initializes. CI retains dSYM
symbols for interpreting device crash reports.

PASS proves this allocator can execute and rewrite a small anonymous code region
under this installation's permissions. It does not prove production pool sizing,
fixed-address mappings, FEX/Wine execution, or graphics compatibility.

Build on macOS with Xcode using `bash tools/ci/build-jit-probe.sh`.
