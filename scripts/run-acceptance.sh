#!/bin/bash
set -euo pipefail
# Runs the short focus and navigation acceptance check against disposable windows.
# Quit the normal Stagehand first. Do not type or click until it prints a result.
# Exits 0 only when the report starts with PASS. STAGEHAND_APP selects the build;
# it defaults to dist/Stagehand.app when present, otherwise /Applications.
# STAGEHAND_ACCEPTANCE_TIMEOUT caps the run in seconds (default 180).
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${STAGEHAND_APP:-}" ]]; then
    app="$STAGEHAND_APP"
elif [[ -d "$root/dist/Stagehand.app" ]]; then
    app="$root/dist/Stagehand.app"
else
    app="/Applications/Stagehand.app"
fi
timeout_seconds="${STAGEHAND_ACCEPTANCE_TIMEOUT:-180}"
if [[ ! -d "$app" ]]; then
    echo "Stagehand build not found at $app. Set STAGEHAND_APP or run scripts/build-app.sh." >&2
    exit 1
fi
if pgrep -f "Stagehand.app/Contents/MacOS/Stagehand" >/dev/null; then
    echo "Quit Stagehand first so only one controller manages windows." >&2
    exit 1
fi
[[ -d "$root/dist/AcceptanceProbe.app" ]] || "$root/scripts/build-acceptance-probe.sh" >/dev/null
report="$(mktemp -t stagehand-acceptance)"
trap 'rm -f "$report"' EXIT
echo "Running acceptance with $app (timeout ${timeout_seconds}s)"
# Launch through LaunchServices: running the binary from a shell would make
# macOS check the terminal's Accessibility permission instead of Stagehand's.
# `open -W` has no timeout of its own, so run it in the background and watch it.
open -W -n "$app" --args --acceptance "$root/dist/AcceptanceProbe.app" --acceptance-output "$report" &
open_pid=$!
deadline=$((SECONDS + timeout_seconds))
while kill -0 "$open_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
        echo "FAIL: the acceptance run did not finish within ${timeout_seconds}s; stopping Stagehand." >&2
        pkill -f "$app/Contents/MacOS/Stagehand" 2>/dev/null || true
        pkill -f "AcceptanceProbe.app/Contents/MacOS/AcceptanceProbe" 2>/dev/null || true
        sleep 1
        kill "$open_pid" 2>/dev/null || true
        [[ -s "$report" ]] && cat "$report"
        exit 1
    fi
    sleep 1
done
wait "$open_pid" || true
if [[ ! -s "$report" ]]; then
    echo "FAIL: Stagehand wrote no acceptance report. Check Accessibility permission and ~/Library/Logs/Stagehand/stagehand.log." >&2
    exit 1
fi
cat "$report"
# The first line of the report is the verdict: "PASS: ..." or "FAIL: ...".
if head -n 1 "$report" | grep -q '^PASS'; then
    exit 0
fi
exit 1
