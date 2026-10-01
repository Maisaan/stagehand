#!/bin/bash
set -euo pipefail
# Runs the short focus and navigation acceptance check against disposable windows.
# Quit the normal Stagehand first. Do not type or click until it prints a result.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${STAGEHAND_APP:-/Applications/Stagehand.app}"
if pgrep -f "Stagehand.app/Contents/MacOS/Stagehand" >/dev/null; then
    echo "Quit Stagehand first so only one controller manages windows." >&2
    exit 1
fi
[[ -d "$root/dist/AcceptanceProbe.app" ]] || "$root/scripts/build-acceptance-probe.sh" >/dev/null
report="$(mktemp -t stagehand-acceptance)"
# Launch through LaunchServices: running the binary from a shell would make
# macOS check the terminal's Accessibility permission instead of Stagehand's.
open -W -n "$app" --args --acceptance "$root/dist/AcceptanceProbe.app" --acceptance-output "$report"
cat "$report"
rm -f "$report"
