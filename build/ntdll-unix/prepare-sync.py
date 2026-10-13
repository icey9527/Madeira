import pathlib
import sys

source_root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
relative = 'dlls/ntdll/unix/sync.c'

# iOS 15 (Madeira port): wine's futex_wait/futex_wake_one gate the os_sync_*
# calls behind `__builtin_available( macOS 14.4, * )`.  That check is always
# true on iOS, so on 15.6 (os_sync needs 17.4) the weak-imported symbol is NULL
# and the call jumps to address 0; name iOS so the __ulock_* path is taken.
text = (source_root / relative).read_text(encoding='utf-8')
original = 'if (__builtin_available( macOS 14.4, * ))'
replacement = 'if (__builtin_available( macOS 14.4, iOS 17.4, * ))'
count = text.count(original)
if count != 2:
    raise SystemExit(
        f'wine sync.c availability pattern changed: expected 2 occurrences of '
        f'{original!r}, found {count}')
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(text.replace(original, replacement), encoding='utf-8')
print(f'iOS os_sync availability guarded in {relative} ({count} sites)')
