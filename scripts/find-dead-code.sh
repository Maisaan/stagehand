#!/bin/bash
# Lists code nothing uses, with Periphery (brew install periphery).
# Builds into its own scratch directory, so the normal .build is left alone.
# Prints two scans: counting the tests as users, then without them (code that
# only tests use). Mark a deliberate keep with `// periphery:ignore` and a reason.
# STAGEHAND_PERIPHERY_SCRATCH overrides the scratch directory.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="${STAGEHAND_PERIPHERY_SCRATCH:-/tmp/sh-periphery}"
command -v periphery >/dev/null || { echo "Install Periphery: brew install periphery" >&2; exit 1; }
# SwiftPM writes the index store to <scratch>/out whatever -index-store-path says.
swift build --build-tests --scratch-path "$scratch" \
    -Xswiftc -index-store-path -Xswiftc "$scratch/out" >"$scratch.build.log" 2>&1 \
    || { echo "Build failed; see $scratch.build.log" >&2; exit 1; }
scan() {
    periphery scan --skip-build --index-store-path "$scratch/out" \
        --retain-codable-properties --quiet "$@" \
        | sed -E "s#^$PWD/##"
}
echo "== unused, tests counted as users"
scan
echo "== unused outside tests"
scan --exclude-tests
