import os
import sys
from pathlib import Path


def prepare(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for relative in (Path(), Path("dlls"), Path("dlls/ntdll")):
        target = destination / relative
        target.mkdir(exist_ok=True)
        for entry in (source / relative).iterdir():
            path = target / entry.name
            if relative == Path() and (entry.name in ("dlls", ".git") or entry.name.startswith("build-")):
                continue
            if relative == Path("dlls") and entry.name == "ntdll":
                continue
            if relative == Path("dlls/ntdll") and entry.name in ("loader.c", "signal_arm64.c"):
                continue
            if not path.exists() and not path.is_symlink():
                os.symlink(entry.resolve(), path, target_is_directory=entry.is_dir())

    text = (source / "dlls/ntdll/loader.c").read_text(encoding="utf-8")
    old = "    RtlLeaveCriticalSection( &loader_section );\n    pWow64LdrpInitialize( context );"
    new = """    if (!NtCurrentTeb()->ThreadLocalStoragePointer)
    {
        NTSTATUS tls_status = alloc_thread_tls();
        if (tls_status != STATUS_SUCCESS)
        {
            ERR( "[wow-native-tls] initialization failed status=%lx\\n", tls_status );
            NtTerminateProcess( GetCurrentProcess(), tls_status );
        }
    }
    ERR( "[wow-native-tls] initialized before CPU backend: teb=%p tls=%p\\n",
         NtCurrentTeb(), NtCurrentTeb()->ThreadLocalStoragePointer );
    RtlLeaveCriticalSection( &loader_section );
    pWow64LdrpInitialize( context );"""
    if text.count(old) != 1:
        raise SystemExit("Wine init_wow64 pattern changed; review TLS initialization order")
    text = text.replace(old, new)
    old = "    if (!entry) return STATUS_SUCCESS;\n\n    if (TRACE_ON(relay))"
    new = """    if (NtCurrentTeb()->WowTebOffset)
        ERR( "[wow-native-attach] module=%s reason=%u entry=%p tls=%p\\n",
             debugstr_w(wm->ldr.BaseDllName.Buffer), reason, entry,
             NtCurrentTeb()->ThreadLocalStoragePointer );
    if (!entry) return STATUS_SUCCESS;

    if (TRACE_ON(relay))"""
    if text.count(old) != 1:
        raise SystemExit("Wine MODULE_InitDLL pattern changed; review native attach diagnostics")
    text = text.replace(old, new)
    (destination / "dlls/ntdll/loader.c").write_text(text, encoding="utf-8")
    print("Prepared native WoW64 loader with TLS initialized before CPU backend loading")
    # signal_arm64.c: the iOS unwind-stall guard (call_seh_handlers /
    # RtlUnwindEx) ended a 32-bit C++ throw (0x20474343) after only three
    # identical Pc/Sp steps, one step before call_seh_handlers would have
    # finished on its own, so NtRaiseException tore the pseudo-process down
    # before any guest handler ran (EDEN_chs.exe and narci2.exe, 2026-10-12).
    # With MADEIRA_UNWIND_GUARD=0 the same throw dispatched and the game
    # reached its loading window, so the bound is raised and made settable
    # through MADEIRA_UNWIND_GUARD_REPEATS. A genuinely stuck walk still
    # ends; a tight loop of thousands of identical steps is sub-millisecond.
    sig = (source / "dlls/ntdll/signal_arm64.c").read_text(encoding="utf-8")
    sig = sig.replace("\r\n", "\n")

    sig_old = "    static int enabled = -1;\n    static LONG reported;"
    sig_new = "    static int enabled = -1;\n    static int threshold = -1;\n    static LONG reported;"
    if sig.count(sig_old) != 1:
        raise SystemExit("Wine signal_arm64.c enabled/reported pattern changed; review unwind guard")
    sig = sig.replace(sig_old, sig_new)

    sig_old = """    if (++p->repeats < 3) return FALSE;
    if (enabled < 0)
    {
        UNICODE_STRING nm, val;
        WCHAR buf[8];
        RtlInitUnicodeString( &nm, L"MADEIRA_UNWIND_GUARD" );
        val.Buffer = buf; val.Length = 0; val.MaximumLength = sizeof(buf);
        enabled = !(!RtlQueryEnvironmentVariable_U( NULL, &nm, &val ) && val.Length && buf[0] == '0');
    }
    if (!enabled) return FALSE;"""
    sig_new = """    if (enabled < 0 || threshold < 0)
    {
        UNICODE_STRING nm, val;
        WCHAR buf[16];
        RtlInitUnicodeString( &nm, L"MADEIRA_UNWIND_GUARD" );
        val.Buffer = buf; val.Length = 0; val.MaximumLength = sizeof(buf);
        enabled = !(!RtlQueryEnvironmentVariable_U( NULL, &nm, &val ) && val.Length && buf[0] == '0');

        threshold = 4096;
        RtlInitUnicodeString( &nm, L"MADEIRA_UNWIND_GUARD_REPEATS" );
        val.Buffer = buf; val.Length = 0; val.MaximumLength = sizeof(buf);
        if (!RtlQueryEnvironmentVariable_U( NULL, &nm, &val ) && val.Length)
        {
            int n = 0, i;
            for (i = 0; i < val.Length / (int)sizeof(WCHAR) && buf[i] >= '0' && buf[i] <= '9'; i++)
                n = n * 10 + (buf[i] - '0');
            if (n > 0) threshold = n;
        }
    }
    if (++p->repeats < threshold) return FALSE;
    if (!enabled) return FALSE;"""
    if sig.count(sig_old) != 1:
        raise SystemExit("Wine signal_arm64.c unwind-stall pattern changed; review unwind guard")
    sig = sig.replace(sig_old, sig_new)

    sig_old = '        ERR( "[unwind-stall] %s code=%08lx pc=%I64x lr=%I64x sp=%I64x fp=%I64x: no progress, walk stopped\\n",\n             walk, rec ? (ULONG)rec->ExceptionCode : 0, context->Pc, context->Lr, context->Sp, context->Fp );'
    sig_new = '        ERR( "[unwind-stall] %s code=%08lx pc=%I64x lr=%I64x sp=%I64x fp=%I64x repeats=%d: no progress, walk stopped\\n",\n             walk, rec ? (ULONG)rec->ExceptionCode : 0, context->Pc, context->Lr, context->Sp, context->Fp,\n             p->repeats );'
    if sig.count(sig_old) != 1:
        raise SystemExit("Wine signal_arm64.c unwind-stall log pattern changed; review unwind guard")
    sig = sig.replace(sig_old, sig_new)

    if "if (++p->repeats < threshold) return FALSE;" not in sig or "threshold = 4096;" not in sig:
        raise SystemExit("generated signal_arm64.c failed unwind guard verification")
    (destination / "dlls/ntdll/signal_arm64.c").write_text(sig, encoding="utf-8")
    print("Prepared native WoW64 signal_arm64.c with relaxed unwind-stall guard")



if __name__ == "__main__":
    prepare(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
