import pathlib
import sys

src_path = pathlib.Path(sys.argv[1]) / "dlls/ntdll/signal_arm64ec.c"
# Read bytes: Path.read_text() translates newlines, so a CRLF checkout would
# look LF-only here and we would rewrite the whole file with LF on the way out.
raw_bytes = src_path.read_bytes()
raw = raw_bytes.decode("utf-8")
if "MADEIRA_HYBRID_LOG" in raw:
    raise SystemExit("signal_arm64ec.c already patched")

crlf = b"\r\n" in raw_bytes
text = raw.replace("\r\n", "\n")

OLD_PTR = '''static void update_hybrid_pointer( void *module, const IMAGE_SECTION_HEADER *sec, UINT rva, void *ptr )
{
    if (!rva) return;

    if (rva < sec->VirtualAddress || rva >= sec->VirtualAddress + sec->Misc.VirtualSize)
        ERR( "rva %x outside of section %s (%lx-%lx)\\n", rva,
             sec->Name, sec->VirtualAddress, sec->VirtualAddress + sec->Misc.VirtualSize );
    else
        *(void **)get_rva( module, rva ) = ptr;
}'''

NEW_PTR = '''static void update_hybrid_pointer( void *module, const IMAGE_SECTION_HEADER *sec, UINT rva, void *ptr )
{
    if (!rva) return;

    if (rva < sec->VirtualAddress || rva >= sec->VirtualAddress + sec->Misc.VirtualSize)
        ERR( "rva %x outside of section %s (%lx-%lx)\\n", rva,
             sec->Name, sec->VirtualAddress, sec->VirtualAddress + sec->Misc.VirtualSize );
    else
    {
        /* MADEIRA_HYBRID_LOG: what the slot held, and what we put there, so a
         * later call through it can be matched against this line. */
        void **slot = (void **)get_rva( module, rva );
        void *was = *slot;
        *slot = ptr;
        ERR( "[hybrid-set] module=%p rva=%x slot=%p was=%p now=%p\\n",
             module, rva, (void *)slot, was, ptr );
    }
}'''

OLD_META = '''    ERR( "arm64ec_update_hybrid_metadata: module=%p dispatch_call_rva=%lx check_call=%p\\n",
         module, (unsigned long)metadata->__os_arm64x_dispatch_call, arm64x_check_call );'''

NEW_META = '''    ERR( "arm64ec_update_hybrid_metadata: module=%p dispatch_call_rva=%lx check_call=%p\\n",
         module, (unsigned long)metadata->__os_arm64x_dispatch_call, arm64x_check_call );
    /* MADEIRA_HYBRID_LOG: the metadata's own slot list, before anything is
     * written -- a zero here is a slot the module's arm64ec metadata does not
     * describe, so nothing can patch it. */
    ERR( "[hybrid-meta] module=%p redir=%lx call=%lx no_redirect=%lx fptr=%lx icall=%lx icall_cfg=%lx ret=%lx\\n",
         module, (unsigned long)metadata->RedirectionMetadata,
         (unsigned long)metadata->__os_arm64x_dispatch_call,
         (unsigned long)metadata->__os_arm64x_dispatch_call_no_redirect,
         (unsigned long)metadata->__os_arm64x_dispatch_fptr,
         (unsigned long)metadata->__os_arm64x_dispatch_icall,
         (unsigned long)metadata->__os_arm64x_dispatch_icall_cfg,
         (unsigned long)metadata->__os_arm64x_dispatch_ret );'''

for old, new, label in ((OLD_PTR, NEW_PTR, "update_hybrid_pointer"), (OLD_META, NEW_META, "metadata log")):
    if text.count(old) != 1:
        raise SystemExit(f"{label}: pattern found {text.count(old)} times")
    text = text.replace(old, new)

if crlf:
    text = text.replace("\n", "\r\n")
src_path.write_bytes(text.encode("utf-8"))
print("signal_arm64ec.c: hybrid-slot logging in place")

