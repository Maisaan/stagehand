#!/usr/bin/env python3
"""Summarizes ~/Library/Logs/Stagehand/stagehand.log for performance work.

Usage:
  scripts/analyze-log.py [--since ISO] [--until ISO] [--split ISO] [--log PATH]
                         [--include-diagnostic-runs]

Times are UTC ISO-8601 prefixes as written in the log, e.g. 2026-10-15T12:55.
--split prints the same report for before and after that time, for comparing
an installed build against the previous one. Acceptance and benchmark runs
(between diagnostic_run_began and diagnostic_run_ended) are skipped unless
--include-diagnostic-runs. Older logs lack those markers: the probe-driven runs
end with a manual pause a few seconds after a burst of switches. Run with
`python3 -I`.

Sections:
  navigation   per-switch phases: action -> first motion -> settled, focus time
  focus by app focus confirmation per target pid (names resolved while running)
  motion       per-animation write statistics; *MotionGap is the longest a
               window went without moving, i.e. a visible freeze
  main thread  main_thread_stall events by the last event before them
  lifecycle    lock/unlock, suspend/resume latency, pauses and failures
"""
import argparse
import collections
import json
import os
import subprocess
from datetime import datetime


def ms(timestamp):
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp() * 1000


def pct(values):
    values = sorted(values)
    if not values:
        return "n=0"
    n = len(values)
    at = lambda p: values[min(n - 1, int(n * p))]
    return f"n={n} p50={at(0.5):.0f} p90={at(0.9):.0f} max={values[-1]:.0f}"


def process_name(pid):
    try:
        out = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout
        return os.path.basename(out.strip()) or "exited"
    except OSError:
        return "?"


def report(events, title):
    print(f"== {title}: {len(events)} events"
          + (f", {events[0]['timestamp']} .. {events[-1]['timestamp']}" if events else ""))
    if not events:
        return
    nav = collections.defaultdict(list)
    focus_by_pid = collections.defaultdict(list)
    motion = collections.defaultdict(list)
    stalls = collections.defaultdict(list)
    lifecycle = []
    pending = {}
    for event in events:
        name, t, d = event["event"], ms(event["timestamp"]), event.get("details", {})
        operation = d.get("operation", "")
        if name == "change_queued" and operation.startswith("action."):
            pending["queued"] = t
            pending.pop("motion", None)
        elif name == "ribbon_animation_started" and "queued" in pending and "motion" not in pending:
            pending["motion"] = t
            nav["action -> first motion"].append(t - pending["queued"])
        elif name == "navigation_focus_confirmed":
            if "queued" in pending:
                nav["action -> focus confirmed"].append(t - pending["queued"])
            if d.get("focusReport"):
                report_ = json.loads(d["focusReport"])
                nav["focus attempt (driver)"].append(report_["elapsedMilliseconds"])
                focus_by_pid[report_.get("targetPID")].append(report_["elapsedMilliseconds"])
        elif name == "change_completed" and operation.startswith("action.") and "queued" in pending:
            nav["action -> settled"].append(t - pending.pop("queued"))
        elif name == "gesture_motion_started":
            pending["gesture"] = t
        elif name == "change_queued" and "gesture" in pending:
            nav["swipe start -> action"].append(t - pending.pop("gesture"))
        if name == "ribbon_animation_completed":
            for key in ("elapsedMilliseconds", "slowestMotionWriteMilliseconds",
                        "largestMotionGapMilliseconds", "focusedMotionGapMilliseconds"):
                if key in d:
                    motion[key].append(float(d[key]))
            if "motionPositionsRequested" in d and int(d["motionPositionsRequested"]) > 0:
                motion["writes sent / requested %"].append(
                    100 * int(d["motionWritesSent"]) / int(d["motionPositionsRequested"]))
        if name == "main_thread_stall":
            stalls[d.get("lastEvent", "?")].append(float(d.get("waitedMilliseconds", 0)))
        if name in ("screen_locked", "screen_unlocked", "desktop_suspended", "desktop_resumed",
                    "started", "paused", "automatic_pause", "layout_failed", "automatic_resume_failed",
                    "ribbon_position_commit_failed", "refresh_starved", "ribbon_animation_stalled"):
            lifecycle.append((event["timestamp"], name, d.get("reason") or d.get("relation") or ""))

    print("-- navigation (ms)")
    for key in ("swipe start -> action", "action -> first motion", "action -> focus confirmed",
                "action -> settled", "focus attempt (driver)"):
        print(f"  {key:28s} {pct(nav[key])}")
    print("-- focus attempt by target app (ms)")
    for pid, values in sorted(focus_by_pid.items(), key=lambda item: -len(item[1]))[:10]:
        print(f"  {str(pid):>7} {process_name(pid)[:24]:24s} {pct(values)}")
    print("-- motion per animation (ms unless noted)")
    for key, values in motion.items():
        print(f"  {key:32s} {pct(values)}")
    print("-- main thread stalls >= 50 ms, by last event before them")
    if not stalls:
        print("  none (or logging predates the watchdog)")
    for last, values in sorted(stalls.items(), key=lambda item: -sum(item[1])):
        print(f"  {last:32s} total={sum(values):.0f} {pct(values)}")
    print("-- lifecycle")
    unlocked = None
    for timestamp, name, extra in lifecycle:
        note = ""
        if name == "screen_unlocked":
            unlocked = ms(timestamp)
        elif name == "desktop_resumed" and unlocked is not None:
            note = f"  ({ms(timestamp) - unlocked:.0f} ms after unlock)"
            unlocked = None
        print(f"  {timestamp} {name} {extra}{note}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", action="append",
                        help="log file; repeatable (default: stagehand.1.log then stagehand.log)")
    parser.add_argument("--since", default="")
    parser.add_argument("--until", default="9999")
    parser.add_argument("--split", default=None)
    parser.add_argument("--include-diagnostic-runs", action="store_true")
    args = parser.parse_args()
    events = []
    in_diagnostic_run = False
    directory = os.path.expanduser("~/Library/Logs/Stagehand")
    paths = args.log or [p for p in (os.path.join(directory, "stagehand.1.log"),
                                     os.path.join(directory, "stagehand.log")) if os.path.exists(p)]
    lines = []
    for path in paths:
        with open(path) as handle:
            lines.extend(handle)
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event["event"] == "diagnostic_run_began":
            in_diagnostic_run = True
        if not (in_diagnostic_run and not args.include_diagnostic_runs) \
                and args.since <= event["timestamp"] < args.until:
            events.append(event)
        if event["event"] == "diagnostic_run_ended":
            in_diagnostic_run = False
    if args.split:
        report([e for e in events if e["timestamp"] < args.split], f"before {args.split}")
        report([e for e in events if e["timestamp"] >= args.split], f"after {args.split}")
    else:
        report(events, "log")


if __name__ == "__main__":
    main()
