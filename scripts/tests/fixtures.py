import copy
import json
from pathlib import Path

ENVIRONMENT = {"displayWidthPoints": 1800, "displayHeightPoints": 1169, "backingScale": 2,
               "maximumFramesPerSecond": 120, "ribbonFramesPerSecond": 60, "reduceMotion": False}
SETTINGS = {"gap": -140, "widthPresets": [0.5, 0.75, 1.0], "loggingEnabled": True, "busyProbes": True,
            "measuresStacking": False, "tiles": False, "switches": 3}


def switch(focus=220.0, settled=400.0, slid=True):
    return {"slid": slid, "motionScheduledMs": 12.0 if slid else None, "focusMs": focus,
            "focusRejected": False, "settledMs": settled, "timedOut": False, "frameWorkMs": [1.2, 1.4],
            "droppedFrames": 0, "focusedGapMs": 17.0, "largestGapMs": 40.0}


def switch_phase(focus_times, slid=True):
    return {"switches": [switch(focus=focus, slid=slid) for focus in focus_times],
            "mainThreadWaitsMs": [4.1, 5.0, 6.0],
            "stalls": [{"waitedMs": 120.0, "label": "read AXPosition", "phase": "ribbon_animation_started"}]}


def raw(focus_times=(200.0, 220.0, 240.0), tiles=False):
    phases = {
        "start": {"callMs": 1.2, "settledMs": 265.0, "timedOut": False, "mainThreadWaitsMs": [4.1, 5.0]},
        "sequential": switch_phase(focus_times),
        "rapid": {"settledMs": 900.0, "timedOut": False, "mainThreadWaitsMs": [4.1], "finalFocusMatches": True},
        "spaces": {"switches": [switch(slid=False)], "mainThreadWaitsMs": [4.1], "finalFocusMatches": True},
        "interface": {"appBarShowMs": [3.1, 3.3], "settingsOpenMs": [80.0, 82.0], "quickControlsOpenMs": [40.0]},
    }
    settings = dict(SETTINGS)
    if tiles:
        settings["tiles"] = True
        phases["panes"] = switch_phase(focus_times)
    return {"schema": 1, "result": "pass", "failures": [], "environment": dict(ENVIRONMENT),
            "settings": settings, "phases": phases}


def gesture(scenario="flick", expected="commit", outcome=None, touch_to_write=20.0, settled=400.0):
    outcome = outcome or expected
    return {"scenario": scenario, "expected": expected, "outcome": outcome, "outcomeMatches": outcome == expected,
            "gestureID": 1, "changeID": 2 if outcome == "commit" else None,
            "plannedStimulusMs": [0.0, 8.0], "actualStimulusMs": [0.5, 9.0], "largestStimulusLagMs": 1.0,
            "follow": {"handoff": "change" if outcome == "commit" else "settle",
                       "settleOperation": None if outcome == "commit" else "gesture.preview.restore",
                       "handoffChangeID": None, "durationMs": 60.0, "ticks": 7, "droppedTicks": 0,
                       "largestTickGapMs": 16.7, "largestCallbackGapMs": 18.0, "lateCallbacks": 0,
                       "startedAfterTouchMs": 4.0, "firstAcknowledgedWriteAfterTouchMs": touch_to_write,
                       "motionWritesSent": 14, "motionWritesAcknowledged": 14, "motionWritesUnacknowledged": 0,
                       "motionWritesFailed": 0},
            "release": dict(switch(focus=220.0 if expected == "commit" else None, settled=settled))}


def with_gestures(raw_document, **overrides):
    raw_document["settings"]["gestures"] = True
    raw_document["phases"]["gestures"] = {
        "coverage": "modelPath",
        "gestures": [gesture(**overrides), gesture("slowDrag"), gesture("reversal", "restore")],
        "mainThreadWaitsMs": [4.0, 5.0], "stalls": []}
    return raw_document


def meta(mode="busy", sha="a" * 40, repeat=1, repeats=1, logging=True, exit_status=0, outcome="pass", load=1.0):
    return {"schema": 1, "mode": mode, "flags": ["--busy"], "loggingEnabled": logging,
            "repeat": repeat, "repeats": repeats, "timeoutSeconds": 240,
            "git": {"sha": sha, "branch": "main", "dirty": False, "checkout": "/checkout"},
            "app": {"path": "/checkout/dist/Stagehand.app", "version": sha[:7],
                    "executableModified": "2026-11-12T10:00:00Z"},
            "machine": {"macOS": "27.0", "macOSBuild": "26A1", "model": "Mac14,9", "cpu": "Apple M2 Pro"},
            "loadAverageAtStart": {"1m": load, "5m": load},
            "startUtc": "2026-11-12T10:01:00Z", "endUtc": "2026-11-12T10:03:00Z",
            "outcome": outcome, "failureReasons": [] if exit_status == 0 else ["report has a line starting with FAIL"],
            "exitStatus": exit_status, "launchExitStatus": 0}


def write_run(directory, run_meta=None, run_raw=None, write_raw=True):
    directory = Path(directory)
    directory.mkdir(parents=True)
    (directory / "meta.json").write_text(json.dumps(run_meta or meta()))
    if write_raw:
        (directory / "raw.json").write_text(json.dumps(run_raw if run_raw is not None else raw()))
    (directory / "report.txt").write_text("not read by the comparison\n")
    return directory


def modified(document, change):
    document = copy.deepcopy(document)
    change(document)
    return document
