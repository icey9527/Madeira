import hashlib
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
script = (root / 'tools/ci/build-all.sh').read_text(encoding='utf-8')


def orchestration(source):
    sections = [source.split('stage_deps() {', 1)[0]]
    for name in ('wine_host_command', 'stage_wine'):
        match = re.search(rf'(?ms)^{name}\(\) \{{.*?^\}}', source)
        if not match:
            raise ValueError(f'Missing Wine build function: {name}')
        sections.append(match.group())
    return '\n'.join(sections)


fingerprint = hashlib.sha256(orchestration(script).encode('utf-8'))
directories = [f'build/{name}' for name in ('ntdll-unix', 'wineserver', 'win32u-unix', 'madsync', 'hidpad', 'crypto-unix', 'gnutls-ios', 'freetype-ios')]
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z', '--', *directories]).split(b'\0')
for entry in sorted(entry for entry in tracked if entry):
    fingerprint.update(entry + b'\0')
content_hash = fingerprint.hexdigest()
baseline_content_hash = 'e41e111347756c114017e3ff51c230cfadeebe60a31ea532a7186a6d2861474d'
baseline_cache_key = '4336add262b784d8ce5414c3821390dbd2f33e40912a04acd3b9042128120c49'
print(baseline_cache_key if content_hash == baseline_content_hash else content_hash)
