#!/bin/bash
# Prints a digest over the sources that build.sh compiles into the DXMT iOS
# archive.  The digest is embedded in the archive as a string (build.sh writes
# obj/dxmt_ios_stamp.c) and recomputed from the working tree by
# tools/ci/verify-startup.sh, which fails the build when the two disagree.
#
# Why it exists: the archive comes from an actions/cache entry keyed by
# hashFiles('build/dxmt-ios/**'), and that key used to name only build.sh and
# prepare-compat.py.  When the probe's airconv_probe.cpp / metal_probe.mm were
# added, every run restored the older archive, linked it, stayed green, and
# shipped an IPA whose probe half contained none of the tracing those commits
# added -- three device rounds wrote "about to call the probe" and nothing else,
# because the code that produces the rest was never in the app.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# The same file set at both call sites, named relative to this directory so the
# digest does not depend on where the checkout lives.
sources() {
    find . -maxdepth 1 -type f \
        \( -name '*.sh' -o -name '*.py' -o -name '*.c' -o -name '*.cc' \
           -o -name '*.cpp' -o -name '*.mm' -o -name '*.h' -o -name '*.hpp' \) \
        -print
}

count="$(sources | wc -l | tr -d " ")"
if [ "$count" -eq 0 ]; then
    echo "source-stamp: no sources found in $DIR" >&2
    exit 1
fi

# pipefail matters here: without it a broken stage (an xargs that cannot find its
# command, say) would leave the final sha256sum hashing empty input, and the
# digest would be a constant that never notices a changed source.
if command -v sha256sum >/dev/null 2>&1; then
    sources | LC_ALL=C sort | LC_ALL=C xargs sha256sum | LC_ALL=C sha256sum | cut -d" " -f1
else
    # macOS ships shasum -a 256 instead; same output format, same digest.
    sources | LC_ALL=C sort | LC_ALL=C xargs shasum -a 256 | LC_ALL=C shasum -a 256 | cut -d" " -f1
fi
