import hashlib
import pathlib
import sys

mode, directory = sys.argv[1:]
if mode not in ('ccache', 'downloads'):
    raise SystemExit('Expected ccache or downloads')
root = pathlib.Path(directory).expanduser()
fingerprint = hashlib.sha256()
if root.is_dir():
    for source in sorted(root.rglob('*')):
        if not source.is_file():
            continue
        if mode == 'ccache' and not source.name.endswith(('M', 'R')):
            continue
        fingerprint.update(source.relative_to(root).as_posix().encode('utf-8') + b'\0')
        fingerprint.update(str(source.stat().st_size).encode('ascii') + b'\0')
        with source.open('rb') as stream:
            while chunk := stream.read(1024 * 1024):
                fingerprint.update(chunk)
print(fingerprint.hexdigest())
