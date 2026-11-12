#!/usr/bin/env python3
"""Summarizes ~/Library/Logs/Stagehand/stagehand.log for performance work.

Usage:
  scripts/analyze-log.py [--since ISO] [--until ISO] [--split ISO] [--log PATH]
                         [--include-diagnostic-runs] [--high-load N]

Times are UTC ISO-8601 prefixes as written in the log, e.g. 2026-10-15T12:55.
--split prints the same report for before and after that time, for comparing
an installed build against the previous one. Acceptance and benchmark runs
(between diagnostic_run_began and diagnostic_run_ended) are skipped unless
--include-diagnostic-runs. Older logs lack those markers: the probe-driven runs
end with a manual pause a few seconds after a burst of switches. Run with
`python3 -I`.

Changes are paired by (session, changeID) over the whole log before --since,
--until or --split select them, so a range boundary never mispairs one; a change
that straddles the boundary is counted as cut, not timed. Durations use the
monotonic uptimeMs where logged. Logs before 2026-11-13 have no session: they
are split at each launch (session_started), where change IDs restart, or at a
30-minute gap, and labelled approximate; before 2026-11-12 they have no change
IDs either and pair by queue order, which a cancelled queue can misalign.

Sections:
  navigation   per-switch phases: action -> motion scheduled -> settled, focus
               time. Only change_completed counts as settled; a change that
               ended otherwise (change_ended: merged, superseded, noEffect,
               refused, skipped, interrupted, failed, cancelled) is counted by
               outcome, never timed.
  change traces  orphan events (no change_queued for their ID), duplicate
               terminal events, changes cut by the time range, and changes with
               no terminal event (log ended, or the session went on)
  changes      queue wait (queued -> started), processing (started -> terminal)
               and outcomes per origin (command, gesture, system) and operation
  felt delays  from each terminal event's trace (logs since 2026-11-13), per
               input source (keyboardTap, trackpad, hotKeyCallback, none) and
               outcome: input -> main (the input's own time to the handler on
               main), queue wait, and from the input (queued when there is
               none) to motion scheduled, first acknowledged write and focus
               confirmed; held typing: events and the oldest one's age
  gesture follows  gesture_follow_ended: how each live follow ended, its
               length, ticks, gaps, and touch to start and to first write
  focus by app focus confirmation per target pid (names resolved while running)
  motion       per-animation write statistics; *MotionGap is the longest a
               window went without moving, i.e. a visible freeze
  main thread  main_thread_stall events by the last event before them, and by
               the call most often running during them (activity)
  stall kind   stalls split by the main thread's own CPU during the wait:
               computing (CPU >= half the wait), starved (CPU under a tenth of
               it while the 1-minute load is at least --high-load: waiting for a
               CPU), or waiting (most likely on another app's reply)
  resources    resource_sample: footprint, CPU %, wakeups/s, threads
  timing       launch_timing and desktop_resume_refreshed
  drag and drop  drag_and_drop_ended: pointer gaps and Stagehand's own moves
  layouts      change_completed and superseded change_ended: Accessibility calls
               on the main thread and parking requests skipped or read, by kind
               of change
  lifecycle    lock/unlock, suspend/resume latency, pauses and failures
"""
import argparse
import collections
import json
import os
import re
import subprocess
from dataclasses import dataclass
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


SESSION_GAP_MS = 30 * 60 * 1000
# Near-zero main-thread CPU while the machine is loaded: waiting for a CPU, not for another app.
STARVED_CPU_FRACTION = 0.1
TRACE_EVENTS = {"change_queued", "change_started", "change_completed", "change_ended",
                "navigation_motion_planned", "ribbon_animation_started", "ribbon_animation_completed",
                "navigation_focus_confirmed"}
SYSTEM_OPERATIONS = {"observedFocus", "windowRemoval", "refresh", "preferences"}


def annotate_sessions(events):
    """Adds _session, _approximate and _t (uptimeMs when logged, else wall-clock ms) to each event.

    Logs before 2026-11-13 carry no session. They are split where a launch starts (session_started),
    where change IDs restart, or at a gap over 30 minutes, and marked approximate.
    """
    annotated = []
    legacy_sessions = 0
    legacy_key = None
    last_wall = None
    last_change_id = None
    for event in events:
        wall = ms(event["timestamp"])
        if "session" in event:
            key, approximate = event["session"], False
        else:
            change_id = event.get("details", {}).get("changeID") if event["event"] == "change_queued" else None
            restarted = (change_id is not None and change_id.isdigit() and last_change_id is not None
                         and int(change_id) <= last_change_id)
            gap = last_wall is not None and wall - last_wall > SESSION_GAP_MS
            if legacy_key is None or event["event"] == "session_started" or restarted or gap:
                legacy_sessions += 1
                legacy_key = f"legacy-{legacy_sessions}"
                last_change_id = None
            if change_id is not None and change_id.isdigit():
                last_change_id = int(change_id)
            last_wall = wall
            key, approximate = legacy_key, True
        annotated.append(dict(event, _session=key, _approximate=approximate, _t=float(event.get("uptimeMs", wall))))
    return annotated


def ensure_annotated(events):
    return events if not events or "_session" in events[0] else annotate_sessions(events)


class Trace:
    def __init__(self, session, change_id, queued):
        details = queued.get("details", {})
        self.session = session
        self.change_id = change_id
        self.approximate = queued["_approximate"]
        self.operation = details.get("operation", "")
        self.origin = details.get("origin") or (
            "system" if self.operation in SYSTEM_OPERATIONS else "command")
        self.gesture_id = details.get("gestureID")
        self.queued = queued
        self.started = None
        self.terminals = []
        self.motion = None
        self.focus = None
        self.last = queued

    @property
    def terminal(self):
        return self.terminals[0] if self.terminals else None

    @property
    def outcome(self):
        terminal = self.terminal
        if terminal is None:
            return None
        if terminal["event"] == "change_completed":
            return "completed"
        return terminal.get("details", {}).get("outcome", "ended")


def build_traces(events):
    """Pairs every change event with its change_queued by (session, changeID), over the whole log.

    Returns (traces in queue order, orphan events, gesture start times by (session, gestureID)).
    Events without a changeID (logs before 2026-11-12, and motion and focus before 2026-11-13) are
    given to the change processing at the time, which only approximate sessions rely on.
    """
    traces = {}
    order = []
    orphans = []
    gestures = {}
    current = {}
    legacy_queue = collections.defaultdict(collections.deque)
    legacy_count = collections.Counter()
    for event in events:
        name, d, session = event["event"], event.get("details", {}), event["_session"]
        if name == "gesture_motion_started" and "gestureID" in d:
            gestures.setdefault((session, d["gestureID"]), event)
        if name not in TRACE_EVENTS:
            continue
        change_id = d.get("changeID")
        if name == "change_queued":
            if change_id is None:
                legacy_count[session] += 1
                change_id = f"q{legacy_count[session]}"
                legacy_queue[session].append((change_id, d.get("operation", "")))
            key = (session, change_id)
            if key in traces:
                orphans.append((event, "change ID queued twice in one session"))
                continue
            traces[key] = Trace(session, change_id, event)
            order.append(traces[key])
            continue
        if name == "change_started" and change_id is None:
            queue = legacy_queue[session]
            while queue and queue[0][1] != d.get("operation", ""):
                queue.popleft()
            change_id = queue.popleft()[0] if queue else None
        if change_id is not None:
            key = (session, change_id)
        elif event["_approximate"]:
            key = current.get(session)
        else:
            key = None
        if key is None:
            continue
        trace = traces.get(key)
        if trace is None:
            orphans.append((event, "no change_queued for its change ID"))
            continue
        trace.last = event
        if name == "change_started":
            current[session] = key
            trace.started = event
        elif name in ("change_completed", "change_ended"):
            trace.terminals.append(event)
            if current.get(session) == key:
                current[session] = None
        elif name == "ribbon_animation_started":
            trace.motion = trace.motion or event
        elif name == "navigation_focus_confirmed" and d.get("focusConfirmed") != "false":
            trace.focus = trace.focus or event
    return order, orphans, gestures


@dataclass
class ChangeSummary:
    nav: dict
    counts: collections.Counter
    by_kind: dict
    approximate_sessions: int
    # (input source, outcome) -> felt delay -> ms values
    felt: dict


FELT_DELAYS = ("input -> main", "queue wait", "to motion scheduled", "to first acknowledged write",
               "to focus confirmed", "held input: oldest event age")


def felt_delays(details):
    """A terminal event's felt delays (ms), from its trace stamps; empty for logs that predate them."""
    def stamp(key):
        value = details.get(key)
        try:
            return float(value) if value is not None else None
        except ValueError:
            return None
    queued = stamp("queuedUptimeMs")
    if queued is None:
        return {}
    event_time = stamp("inputEventUptimeMs")
    received = stamp("inputReceivedUptimeMs")
    delivered = stamp("inputDeliveredUptimeMs")
    input_time = event_time if event_time is not None else received
    origin = input_time if input_time is not None else queued
    delays = {}
    if delivered is not None and input_time is not None:
        delays["input -> main"] = delivered - input_time
    started = stamp("startedUptimeMs")
    if started is not None:
        delays["queue wait"] = started - queued
    for name, key in (("to motion scheduled", "motionScheduledUptimeMs"),
                      ("to first acknowledged write", "firstAcknowledgedWriteUptimeMs"),
                      ("to focus confirmed", "focusConfirmedUptimeMs")):
        value = stamp(key)
        if value is not None:
            delays[name] = value - origin
    oldest = stamp("oldestHeldInputAgeMs")
    if oldest is not None:
        delays["held input: oldest event age"] = oldest
    return delays


def summarize_changes(events, since="", until="9999"):
    """Per-change latencies (ms) and counts for changes queued in [since, until).

    Pairing runs over every event first and filters after, so a range boundary never mispairs a
    change; a change that straddles the boundary is counted as cut, not timed.
    """
    events = ensure_annotated(events)
    traces, orphans, gestures = build_traces(events)
    nav = collections.defaultdict(list)
    counts = collections.Counter()
    by_kind = collections.defaultdict(lambda: {"wait": [], "processing": [], "outcomes": collections.Counter()})
    felt = collections.defaultdict(lambda: collections.defaultdict(list))
    within = lambda event: since <= event["timestamp"] < until
    last_progress = collections.defaultdict(lambda: float("-inf"))
    for trace in traces:
        for event in [trace.started, *trace.terminals]:
            if event is not None:
                last_progress[trace.session] = max(last_progress[trace.session], event["_t"])
    for event in events:
        d = event.get("details", {})
        if not within(event) or event["event"] != "navigation_focus_confirmed":
            continue
        if d.get("focusConfirmed") == "false":
            counts["focus rejected"] += 1
        if d.get("focusReport"):
            report_ = json.loads(d["focusReport"])
            nav["focus attempt (driver)"].append(report_["elapsedMilliseconds"])
            nav["focus attempt pid " + str(report_.get("targetPID"))].append(report_["elapsedMilliseconds"])
    for event, reason in orphans:
        if within(event):
            counts[f"orphan {event['event']}: {reason}"] += 1
    approximate_sessions = set()
    legacy_gesture = None
    for trace in traces:
        queued, terminal = trace.queued, trace.terminal
        if not within(queued):
            if terminal is not None and within(terminal):
                counts["cut by the time range: queued before it"] += 1
            continue
        if trace.approximate:
            approximate_sessions.add(trace.session)
        if len(trace.terminals) > 1:
            counts["duplicate terminal events"] += 1
        if terminal is not None and not within(terminal):
            counts["cut by the time range: ended after it"] += 1
            continue
        is_action = trace.operation.startswith("action.")
        if is_action:
            counts["actions"] += 1
        kind = by_kind[(trace.origin, trace.operation)]
        begin = queued["_t"]
        if trace.started is not None:
            kind["wait"].append(trace.started["_t"] - begin)
            if terminal is not None:
                kind["processing"].append(terminal["_t"] - trace.started["_t"])
        if terminal is not None:
            kind["outcomes"][trace.outcome] += 1
            if trace.outcome != "completed":
                counts[f"ended {trace.outcome}"] += 1
            terminal_details = terminal.get("details", {})
            delays = felt_delays(terminal_details)
            if delays:
                group = felt[(terminal_details.get("inputSource", "none"), trace.outcome)]
                group["changes"].append(1)
                for name, value in delays.items():
                    group[name].append(value)
                if "heldInputEvents" in terminal_details:
                    group["held input events"].append(float(terminal_details["heldInputEvents"]))
        else:
            unfinished = "log ended" if trace.last["_t"] >= last_progress[trace.session] else "session went on"
            kind["outcomes"]["no terminal"] += 1
            if not trace.approximate:
                counts[f"no terminal event ({unfinished})"] += 1
        if trace.gesture_id is not None and (trace.session, trace.gesture_id) in gestures:
            nav["swipe start -> action"].append(begin - gestures[(trace.session, trace.gesture_id)]["_t"])
        if not is_action:
            continue
        if trace.motion is not None:
            nav["action -> motion scheduled"].append(trace.motion["_t"] - begin)
        if trace.focus is not None:
            nav["action -> focus confirmed"].append(trace.focus["_t"] - begin)
        if trace.outcome == "completed":
            nav["action -> settled"].append(terminal["_t"] - begin)
        elif terminal is None and trace.started is not None:
            counts["incomplete: started, never completed"] += 1
        elif terminal is None:
            counts["incomplete: never started"] += 1
    # Logs before gesture IDs: a swipe's action is the next action queued after its start.
    for event in events:
        if not event["_approximate"] or not within(event):
            continue
        name, operation = event["event"], event.get("details", {}).get("operation", "")
        if name == "gesture_motion_started":
            legacy_gesture = event
        elif name == "change_queued" and operation.startswith("action.") and legacy_gesture is not None:
            if legacy_gesture["_session"] == event["_session"]:
                nav["swipe start -> action"].append(event["_t"] - legacy_gesture["_t"])
            legacy_gesture = None
        elif name == "gesture_motion_resolved":
            legacy_gesture = None
    return ChangeSummary(nav, counts, by_kind, len(approximate_sessions), felt)


FOLLOW_NUMBERS = ("durationMilliseconds", "ticks", "largestTickGapMilliseconds", "largestCallbackGapMilliseconds",
                  "lateCallbacks", "followStartedAfterTouchMilliseconds",
                  "firstAcknowledgedWriteAfterTouchMilliseconds")


def summarize_follows(events):
    """gesture_follow_ended: handoffs, and each number over the follows that have it."""
    handoffs = collections.Counter()
    numbers = collections.defaultdict(list)
    counts = collections.Counter()
    for event in events:
        if event["event"] != "gesture_follow_ended":
            continue
        d = event.get("details", {})
        handoff = d.get("handoff", "?")
        handoffs[f"{handoff} ({d['settleOperation']})" if handoff == "settle" and "settleOperation" in d
                 else handoff] += 1
        for key in FOLLOW_NUMBERS:
            if d.get(key, "none") != "none":
                numbers[key].append(float(d[key]))
        if d.get("droppedTicks") == "unknown":
            counts["dropped ticks unknown"] += 1
        elif "droppedTicks" in d:
            counts["dropped ticks"] += int(d["droppedTicks"])
        for key in ("motionWritesSent", "motionWritesUnacknowledged", "motionWritesFailed"):
            counts[key] += int(d.get(key, 0))
    return handoffs, numbers, counts


def stall_kind(waited, cpu, load, high_load):
    if cpu >= waited / 2:
        return "computing"
    if cpu < waited * STARVED_CPU_FRACTION and load is not None and load >= high_load:
        return "starved"
    return "waiting"


INTEGRITY_PREFIXES = ("orphan", "duplicate", "cut by", "no terminal")


def report(all_events, title, since="", until="9999", high_load=None):
    high_load = high_load if high_load is not None else (os.cpu_count() or 1)
    events = [e for e in all_events if since <= e["timestamp"] < until]
    print(f"== {title}: {len(events)} events"
          + (f", {events[0]['timestamp']} .. {events[-1]['timestamp']}" if events else ""))
    if not events:
        return
    summary = summarize_changes(all_events, since, until)
    nav, nav_counts = summary.nav, summary.counts
    motion = collections.defaultdict(list)
    stalls = collections.defaultdict(list)
    stalls_by_activity = collections.defaultdict(list)
    stall_kinds = collections.defaultdict(list)
    stall_loads = []
    resources = collections.defaultdict(list)
    timing = collections.defaultdict(list)
    drags = []
    layouts = collections.defaultdict(lambda: collections.defaultdict(list))
    park_reasons = collections.Counter()
    lifecycle = []
    for event in events:
        name, t, d = event["event"], ms(event["timestamp"]), event.get("details", {})
        operation = d.get("operation", "")
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
            if "mainThreadCPUMilliseconds" in d:
                waited = float(d.get("waitedMilliseconds", 0))
                load = float(d["loadAverage"]) if "loadAverage" in d else None
                kind = stall_kind(waited, float(d["mainThreadCPUMilliseconds"]), load, high_load)
                stall_kinds[kind].append(waited)
            if "loadAverage" in d:
                stall_loads.append(float(d["loadAverage"]))
            if "activity" in d:
                # The most-sampled label, without its count or the pid, so one
                # call groups across apps.
                top = re.sub(r" pid=-?\d+| x\d+$", "", d["activity"].split(", ")[0])
                stalls_by_activity[top].append(float(d.get("waitedMilliseconds", 0)))
        if name == "resource_sample":
            for key in ("footprintMegabytes", "cpuPercent", "idleWakeupsPerSecond",
                        "interruptWakeupsPerSecond", "threads"):
                if key in d:
                    resources[key].append(float(d[key]))
        if name == "launch_timing":
            for key, value in d.items():
                timing["launch " + key].append(float(value))
        if name == "desktop_resume_refreshed":
            timing["resume refresh milliseconds"].append(float(d.get("milliseconds", 0)))
        # A superseded slide carries the same cost fields; before change_ended it was a change_completed.
        if name in ("change_completed", "change_ended") and "appCallsOnMain" in d:
            kind = operation.split(".")[0]
            for key in ("appCallsOnMain", "parkRequests", "parkSkipped"):
                if key in d:
                    layouts[kind][key].append(float(d[key]))
            for part in d.get("parkReadReasons", "").split():
                reason, _, count = part.partition(":")
                park_reasons[reason] += int(count or 0)
        if name == "drag_and_drop_ended":
            drags.append((event["timestamp"], d))
        if name in ("screen_locked", "screen_unlocked", "desktop_suspended", "desktop_resumed",
                    "started", "paused", "automatic_pause", "layout_failed", "automatic_resume_failed",
                    "ribbon_position_commit_failed", "refresh_starved", "ribbon_animation_stalled"):
            lifecycle.append((event["timestamp"], name, d.get("reason") or d.get("relation") or ""))

    print("-- navigation (ms)" + (f"; {summary.approximate_sessions} launch(es) without session IDs, paired"
                                  " approximately by queue order" if summary.approximate_sessions else ""))
    for key in ("swipe start -> action", "action -> motion scheduled", "action -> focus confirmed",
                "action -> settled", "focus attempt (driver)"):
        print(f"  {key:28s} {pct(nav[key])}")
    print("  " + ", ".join(f"{key} {value}" for key, value in sorted(nav_counts.items())
                           if not key.startswith(INTEGRITY_PREFIXES)))
    integrity = [(key, value) for key, value in sorted(nav_counts.items()) if key.startswith(INTEGRITY_PREFIXES)]
    print("-- change traces: " + (", ".join(f"{key} {value}" for key, value in integrity) or "all paired"))
    if summary.by_kind:
        print("-- changes by origin and operation (ms): queue wait, processing, outcomes")
        for (origin, operation), kind in sorted(summary.by_kind.items(),
                                                key=lambda item: -sum(item[1]["outcomes"].values()))[:20]:
            outcomes = ", ".join(f"{name} {count}" for name, count in kind["outcomes"].most_common())
            print(f"  {origin:8s} {operation[:34]:34s} wait {pct(kind['wait'])}")
            print(f"  {'':8s} {'':34s} processing {pct(kind['processing'])}; {outcomes}")
    if summary.felt:
        print("-- felt delays (ms) by input source and outcome; from the input's own time, queued when it has none")
        for (source, outcome), group in sorted(summary.felt.items(), key=lambda item: -len(item[1]["changes"])):
            print(f"  {source} {outcome} (n={len(group['changes'])})")
            for name in FELT_DELAYS:
                if group[name]:
                    print(f"    {name:30s} {pct(group[name])}")
            if group["held input events"]:
                print(f"    {'held input events':30s} total={sum(group['held input events']):.0f}"
                      f" {pct(group['held input events'])}")
    handoffs, follow_numbers, follow_counts = summarize_follows(events)
    if handoffs:
        print(f"-- gesture follows (gesture_follow_ended, n={sum(handoffs.values())}; ms unless noted): ended by "
              + ", ".join(f"{name} {count}" for name, count in handoffs.most_common()))
        for key in FOLLOW_NUMBERS:
            if follow_numbers[key]:
                print(f"  {key:44s} {pct(follow_numbers[key])}")
        print("  " + ", ".join(f"{key} {value}" for key, value in sorted(follow_counts.items())))
    print("-- focus attempt by target app (ms)")
    by_pid = [(key.removeprefix("focus attempt pid "), values) for key, values in nav.items()
              if key.startswith("focus attempt pid ")]
    for pid, values in sorted(by_pid, key=lambda item: -len(item[1]))[:10]:
        print(f"  {pid:>7} {process_name(pid)[:24]:24s} {pct(values)}")
    print("-- motion per animation (ms unless noted)")
    for key, values in motion.items():
        print(f"  {key:32s} {pct(values)}")
    print("-- main thread stalls >= 50 ms, by last event before them")
    if not stalls:
        print("  none (or logging predates the watchdog)")
    for last, values in sorted(stalls.items(), key=lambda item: -sum(item[1])):
        print(f"  {last:32s} total={sum(values):.0f} {pct(values)}")
    if stalls_by_activity:
        print("-- main thread stalls >= 50 ms, by the call most often running during them")
        for label, values in sorted(stalls_by_activity.items(), key=lambda item: -sum(item[1]))[:15]:
            print(f"  {label[:60]:60s} total={sum(values):.0f} {pct(values)}")
    if stall_kinds:
        print(f"-- main thread stalls by kind (main thread CPU during the wait; starved: under"
              f" {STARVED_CPU_FRACTION:.0%} of it at load >= {high_load:g})")
        for kind, values in sorted(stall_kinds.items()):
            print(f"  {kind:12s} total={sum(values):.0f} {pct(values)}")
        if stall_loads:
            print(f"  load average during stalls {pct(stall_loads)}")
    if resources:
        print("-- resources (resource_sample, one a minute)")
        for key, values in resources.items():
            print(f"  {key:28s} {pct(values)}")
    if timing:
        print("-- timing (ms)")
        for key, values in timing.items():
            print(f"  {key:40s} {pct(values)}")
    if drags:
        print("-- drag and drop (per drag)")
        for timestamp, d in drags[-15:]:
            print(f"  {timestamp} dur={d.get('durationMilliseconds')} gap={d.get('longestPointerGapMilliseconds')}"
                  f" travel={d.get('heldFingerTravelDuringGap')} dock={d.get('dockControlEventsWithheld')}"
                  f" synthetic={d.get('syntheticPointerEvents', '-')}")
    if layouts:
        print("-- layouts (per change_completed)")
        for kind, values in sorted(layouts.items()):
            for key, numbers in values.items():
                print(f"  {kind:12s} {key:16s} total={sum(numbers):.0f} {pct(numbers)}")
        if park_reasons:
            print("  parking reads by reason: " + ", ".join(f"{k} {v}" for k, v in park_reasons.most_common()))
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


def without_diagnostic_runs(events):
    """Drops acceptance and benchmark runs, per session so another launch's events are kept."""
    inside = set()
    kept = []
    for event in events:
        session = event["_session"]
        if event["event"] == "diagnostic_run_began":
            inside.add(session)
        if session not in inside:
            kept.append(event)
        if event["event"] == "diagnostic_run_ended":
            inside.discard(session)
    return kept


def load_events(paths):
    events = []
    for path in paths:
        with open(path) as handle:
            for line in handle:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return annotate_sessions(events)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", action="append",
                        help="log file; repeatable (default: stagehand.1.log then stagehand.log)")
    parser.add_argument("--since", default="")
    parser.add_argument("--until", default="9999")
    parser.add_argument("--split", default=None)
    parser.add_argument("--include-diagnostic-runs", action="store_true")
    parser.add_argument("--high-load", type=float, default=None,
                        help="1-minute load at which a stall with near-zero main-thread CPU counts as starved"
                             " (default: this Mac's CPU count)")
    args = parser.parse_args()
    directory = os.path.expanduser("~/Library/Logs/Stagehand")
    paths = args.log or [p for p in (os.path.join(directory, "stagehand.1.log"),
                                     os.path.join(directory, "stagehand.log")) if os.path.exists(p)]
    events = load_events(paths)
    if not args.include_diagnostic_runs:
        events = without_diagnostic_runs(events)
    if args.split:
        report(events, f"before {args.split}", args.since, min(args.until, args.split), args.high_load)
        report(events, f"after {args.split}", max(args.since, args.split), args.until, args.high_load)
    else:
        report(events, "log", args.since, args.until, args.high_load)


if __name__ == "__main__":
    main()
