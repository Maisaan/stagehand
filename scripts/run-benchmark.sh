#!/bin/bash
set -euo pipefail
# Measures startup, navigation latency, ribbon frame cost, main-thread stalls, and
# interface load times against disposable probe windows. Quit Stagehand first and
# keep hands off the keyboard and trackpad. Runs responsive probes, then busy probes
# that load their main thread like Chrome or an Electron app.
# STAGEHAND_APP selects the build (default dist/Stagehand.app). BENCHMARK_MODES
# limits the modes, e.g. BENCHMARK_MODES=busy. A -quiet suffix (busy-quiet)
# turns diagnostic logging off to measure its cost.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${STAGEHAND_APP:-$root/dist/Stagehand.app}"
if pgrep -f "Stagehand.app/Contents/MacOS/Stagehand" >/dev/null; then
    echo "Quit Stagehand first so only one controller manages windows." >&2
    exit 1
fi
"$root/scripts/build-acceptance-probe.sh" >/dev/null
for mode in ${BENCHMARK_MODES:-responsive busy}; do
    report="$(mktemp -t stagehand-benchmark)"
    extra=()
    [[ "$mode" == busy* ]] && extra=(--busy)
    [[ "$mode" == *-quiet ]] && extra+=(--no-diagnostics)
    open -W -n "$app" --args --benchmark "$root/dist/AcceptanceProbe.app" ${extra[@]+"${extra[@]}"} --acceptance-output "$report" &
    open_pid=$!
    deadline=$((SECONDS + 240))
    while kill -0 "$open_pid" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            pkill -f "$app/Contents/MacOS/Stagehand" 2>/dev/null || true
            pkill -f "AcceptanceProbe.app/Contents/MacOS/AcceptanceProbe" 2>/dev/null || true
            echo "FAIL: benchmark timed out" >&2
            exit 1
        fi
        sleep 1
    done
    cat "$report"
    rm -f "$report"
    echo
done
