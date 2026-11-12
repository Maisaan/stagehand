#!/bin/bash
set -euo pipefail
# Measures startup, navigation latency, ribbon frame cost, main-thread stalls, and
# interface load times against disposable probe windows. Quit Stagehand first and
# keep hands off the keyboard and trackpad. Runs responsive probes, then busy probes
# that load their main thread like Chrome or an Electron app.
# STAGEHAND_APP selects the build (default dist/Stagehand.app). BENCHMARK_MODES
# limits the modes, e.g. BENCHMARK_MODES=busy. A -quiet suffix (busy-quiet)
# turns diagnostic logging off to measure its cost. A -stacking suffix
# (busy-stacking) also measures when the destination reaches the front; its
# window-list polling stalls Stagehand's main thread, so leave it off when
# comparing latency or stalls. A -tiles suffix (busy-tiles) is unrelated to
# -stacking: it arranges two probe windows side by side in one tile first, so
# switches cross a multi-pane tile, and adds pane switches inside the tile.
# Each run is saved to BENCHMARK_RESULTS_DIR (default ~/Library/Application Support/Stagehand/Benchmarks)
# as <UTC>-<sha7>[-dirty]-<mode>[-r<N>]/ with report.txt, raw.json, meta.json and
# diagnostic.log. BENCHMARK_REPEAT=N runs each mode N times (default 3). BENCHMARK_TIMEOUT caps
# each run in seconds (default 240). Compare result sets with
# scripts/compare-benchmarks.py. Exits non-zero when any run times out or fails,
# after running the remaining modes.
# BENCHMARK_LAUNCH=direct runs the app's executable without LaunchServices. It is
# for the tests' stub app only: macOS would then check the terminal's
# Accessibility permission, not Stagehand's.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${STAGEHAND_APP:-$root/dist/Stagehand.app}"
# Not under ~/Library/Logs: cleaners such as Mole delete that folder, and saved baselines with it.
results_root="${BENCHMARK_RESULTS_DIR:-$HOME/Library/Application Support/Stagehand/Benchmarks}"
# Single runs vary by 10 to 30 percent; three give a median and a spread to judge a change by.
repeats="${BENCHMARK_REPEAT:-3}"
timeout_seconds="${BENCHMARK_TIMEOUT:-240}"
launch="${BENCHMARK_LAUNCH:-open}"
probe="$root/dist/AcceptanceProbe.app"

if ! [[ "$repeats" =~ ^[1-9][0-9]*$ ]]; then
    echo "BENCHMARK_REPEAT must be a positive whole number, not '$repeats'." >&2
    exit 1
fi
if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "BENCHMARK_TIMEOUT must be a positive whole number of seconds, not '$timeout_seconds'." >&2
    exit 1
fi
if [[ "$launch" != open && "$launch" != direct ]]; then
    echo "BENCHMARK_LAUNCH must be 'open' or 'direct', not '$launch'." >&2
    exit 1
fi
if [[ ! -d "$app" ]]; then
    echo "Stagehand build not found at $app. Set STAGEHAND_APP or run scripts/build-app.sh." >&2
    exit 1
fi
if [[ "$launch" == open ]]; then
    if pgrep -f "Stagehand.app/Contents/MacOS/Stagehand" >/dev/null; then
        echo "Quit Stagehand first so only one controller manages windows." >&2
        exit 1
    fi
    "$root/scripts/build-acceptance-probe.sh" >/dev/null
fi

executable="$app/Contents/MacOS/Stagehand"
# The checkout that holds the app, else the runner's own; only the former built it.
checkout="$(git -C "$(dirname "$app")" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
checkout_holds_app=true
git -C "$(dirname "$app")" rev-parse --show-toplevel >/dev/null 2>&1 || checkout_holds_app=false
git_sha="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo unknown)"
git_branch="$(git -C "$checkout" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
git_dirty=false
[[ -n "$(git -C "$checkout" status --porcelain --untracked-files=no 2>/dev/null)" ]] && git_dirty=true
name_base="${git_sha:0:7}"
[[ "$git_dirty" == true ]] && name_base+="-dirty"
app_version="" app_build_number=""
if [[ -f "$app/Contents/Info.plist" ]]; then
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
    app_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
fi
executable_modified=""
[[ -f "$executable" ]] && executable_modified="$(date -u -r "$(stat -f %m "$executable")" +%Y-%m-%dT%H:%M:%SZ)"

write_meta() {
    META_PATH="$1" \
    META_MODE="$mode" META_FLAGS="$(printf '%s\n' ${flags[@]+"${flags[@]}"})" META_LOGGING="$logging" \
    META_REPEAT="$index" META_REPEATS="$repeats" META_TIMEOUT="$timeout_seconds" \
    META_GIT_SHA="$git_sha" META_GIT_BRANCH="$git_branch" META_GIT_DIRTY="$git_dirty" META_CHECKOUT="$checkout" \
    META_CHECKOUT_HOLDS_APP="$checkout_holds_app" \
    META_APP="$app" META_APP_VERSION="$app_version" META_APP_BUILD_NUMBER="$app_build_number" \
    META_EXECUTABLE_MODIFIED="$executable_modified" \
    META_MACOS="$(sw_vers -productVersion)" META_MACOS_BUILD="$(sw_vers -buildVersion)" \
    META_MODEL="$(sysctl -n hw.model)" META_CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)" \
    META_LOAD1="$load1" META_LOAD5="$load5" META_START="$started" META_END="${ended:-}" \
    META_EXIT="${run_status:-}" META_OUTCOME="$outcome" \
    META_REASONS="$(printf '%s\n' ${reasons[@]+"${reasons[@]}"})" META_LAUNCH_EXIT="${launch_status:-}" \
    python3 -I -c '
import json, os
e = os.environ
def lines(key): return [line for line in e[key].split("\n") if line]
def number(key): return int(e[key]) if e[key] else None
meta = {
    "schema": 1,
    "mode": e["META_MODE"], "flags": lines("META_FLAGS"), "loggingEnabled": e["META_LOGGING"] == "true",
    "repeat": int(e["META_REPEAT"]), "repeats": int(e["META_REPEATS"]), "timeoutSeconds": int(e["META_TIMEOUT"]),
    "git": {"sha": e["META_GIT_SHA"], "branch": e["META_GIT_BRANCH"], "dirty": e["META_GIT_DIRTY"] == "true",
            "checkout": e["META_CHECKOUT"], "holdsApp": e["META_CHECKOUT_HOLDS_APP"] == "true"},
    "app": {"path": e["META_APP"], "version": e["META_APP_VERSION"] or None,
            "buildNumber": e["META_APP_BUILD_NUMBER"] or None,
            "executableModified": e["META_EXECUTABLE_MODIFIED"] or None},
    "machine": {"macOS": e["META_MACOS"], "macOSBuild": e["META_MACOS_BUILD"], "model": e["META_MODEL"],
                "cpu": e["META_CPU"] or None},
    "loadAverageAtStart": {"1m": float(e["META_LOAD1"]), "5m": float(e["META_LOAD5"])},
    "startUtc": e["META_START"], "endUtc": e["META_END"] or None,
    "outcome": e["META_OUTCOME"], "failureReasons": lines("META_REASONS"),
    "exitStatus": number("META_EXIT"), "launchExitStatus": number("META_LAUNCH_EXIT"),
}
with open(e["META_PATH"], "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
'
}

stop_run() {
    pkill -f "$executable" 2>/dev/null || true
    pkill -f "$probe/Contents/MacOS/AcceptanceProbe" 2>/dev/null || true
    kill "$launch_pid" 2>/dev/null || true
}

mkdir -p "$results_root"
failed_runs=()
for mode in ${BENCHMARK_MODES:-responsive busy}; do
    for ((index = 1; index <= repeats; index++)); do
        flags=()
        [[ "$mode" == busy* ]] && flags=(--busy)
        logging=true
        [[ "$mode" == *-quiet* ]] && flags+=(--no-diagnostics) && logging=false
        [[ "$mode" == *-stacking* ]] && flags+=(--stacking)
        [[ "$mode" == *-tiles* ]] && flags+=(--tiles)
        started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        name="$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$started" +%Y%m%dT%H%M%SZ)-$name_base-$mode"
        (( repeats > 1 )) && name+="-r$index"
        dir="$results_root/$name"
        mkdir "$dir"
        read -r _ load1 load5 _ < <(sysctl -n vm.loadavg)
        ended="" run_status="" launch_status="" outcome=running reasons=()
        write_meta "$dir/meta.json"

        app_arguments=(--benchmark "$probe" ${flags[@]+"${flags[@]}"}
            --acceptance-output "$dir/report.txt" --raw-output "$dir/raw.json" --diagnostic-log "$dir/diagnostic.log")
        if [[ "$launch" == direct ]]; then
            "$executable" "${app_arguments[@]}" &
        else
            open -W -n "$app" --args "${app_arguments[@]}" &
        fi
        launch_pid=$!
        deadline=$((SECONDS + timeout_seconds))
        timed_out=false
        while kill -0 "$launch_pid" 2>/dev/null; do
            if (( SECONDS >= deadline )); then
                timed_out=true
                stop_run
                break
            fi
            sleep 1
        done
        if wait "$launch_pid"; then launch_status=0; else launch_status=$?; fi

        report="$dir/report.txt"
        [[ -s "$report" ]] && cat "$report"
        [[ "$timed_out" == true ]] && reasons+=("timed out after ${timeout_seconds}s")
        if [[ ! -s "$report" ]]; then
            reasons+=("no report")
        else
            grep -q '^FAIL' "$report" && reasons+=("report has a line starting with FAIL")
            [[ "$(tail -n 1 "$report")" == "Result: PASS" ]] || reasons+=("report's last line is not 'Result: PASS'")
        fi
        if [[ "$timed_out" == true ]]; then
            outcome=timeout
        elif (( ${#reasons[@]} > 0 )); then
            outcome=fail
        else
            outcome=pass
        fi
        run_status=0
        [[ "$outcome" != pass ]] && run_status=1 && failed_runs+=("$name: ${reasons[*]}")
        ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        write_meta "$dir/meta.json"
        echo "Saved $outcome run to $dir"
        echo
    done
done

if (( ${#failed_runs[@]} > 0 )); then
    echo "FAIL: ${#failed_runs[@]} benchmark run(s) failed:" >&2
    printf '  %s\n' "${failed_runs[@]}" >&2
    exit 1
fi
