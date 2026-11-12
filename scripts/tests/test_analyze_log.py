import collections
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

_path = pathlib.Path(__file__).resolve().parent.parent / "analyze-log.py"
_spec = importlib.util.spec_from_file_location("analyze_log", _path)
analyze_log = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(analyze_log)


def event(millisecond, name, **details):
    return {"timestamp": f"2026-11-12T12:00:{millisecond // 1000:02d}.{millisecond % 1000:03d}Z",
            "event": name, "details": details}


def stats(events, **window):
    summary = analyze_log.summarize_changes(events, **window)
    return summary.nav, summary.counts


class NavigationStatsTests(unittest.TestCase):
    def test_overlapping_actions_are_timed_from_their_own_queue_time(self):
        nav, counts = stats([
            event(0, "change_queued", changeID="1", operation="action.focusNext"),
            event(100, "change_queued", changeID="2", operation="action.focusNext"),
            event(110, "change_started", changeID="1", operation="action.focusNext"),
            event(120, "ribbon_animation_started"),
            event(300, "navigation_focus_confirmed", focusConfirmed="true"),
            event(320, "change_completed", changeID="1", operation="action.focusNext"),
            event(330, "change_started", changeID="2", operation="action.focusNext"),
            event(340, "ribbon_animation_started"),
            event(500, "navigation_focus_confirmed", focusConfirmed="true"),
            event(520, "change_completed", changeID="2", operation="action.focusNext"),
        ])
        self.assertEqual(nav["action -> motion scheduled"], [120, 240])
        self.assertEqual(nav["action -> focus confirmed"], [300, 400])
        self.assertEqual(nav["action -> settled"], [320, 420])
        self.assertEqual(counts["actions"], 2)

    def test_merged_and_cancelled_actions_are_counted_incomplete_not_timed(self):
        nav, counts = stats([
            event(0, "change_queued", changeID="1", operation="action.focusNext"),
            event(10, "change_queued", changeID="2", operation="action.focusNext"),
            event(20, "change_queued", changeID="3", operation="action.focusNext"),
            event(30, "change_started", changeID="1", operation="action.focusNext"),
            event(40, "change_started", changeID="2", operation="action.focusNext"),
            event(50, "ribbon_animation_started"),
            event(200, "change_completed", changeID="2", operation="action.focusNext"),
        ])
        self.assertEqual(nav["action -> settled"], [190])
        self.assertEqual(nav["action -> motion scheduled"], [40])
        self.assertEqual(counts["incomplete: started, never completed"], 1)
        self.assertEqual(counts["incomplete: never started"], 1)

    def test_rejected_focus_is_counted_and_not_timed_as_confirmed(self):
        nav, counts = stats([
            event(0, "change_queued", changeID="1", operation="action.focusNext"),
            event(10, "change_started", changeID="1", operation="action.focusNext"),
            event(900, "navigation_focus_confirmed", focusConfirmed="false"),
        ])
        self.assertEqual(nav["action -> focus confirmed"], [])
        self.assertEqual(counts["focus rejected"], 1)

    def test_logs_without_change_ids_pair_by_queue_order(self):
        nav, counts = stats([
            event(0, "change_queued", operation="action.focusNext"),
            event(5, "change_queued", operation="refresh"),
            event(100, "change_queued", operation="action.focusPrevious"),
            event(110, "change_started", operation="action.focusNext"),
            event(320, "change_completed", operation="action.focusNext"),
            event(330, "change_started", operation="refresh"),
            event(340, "change_completed", operation="refresh"),
            event(350, "change_started", operation="action.focusPrevious"),
            event(520, "change_completed", operation="action.focusPrevious"),
        ])
        self.assertEqual(nav["action -> settled"], [320, 420])
        self.assertEqual(counts["actions"], 2)


def traced(millisecond, name, session="s1", uptime=None, **details):
    """An event as logged since 2026-11-13: with a session and a monotonic uptimeMs."""
    entry = event(millisecond, name, **details)
    entry["session"] = session
    entry["uptimeMs"] = float(5_000_000 + millisecond if uptime is None else uptime)
    return entry


def change(start, change_id, session="s1", operation="action.focusNext", settled=300, **queued):
    return [
        traced(start, "change_queued", session, changeID=change_id, operation=operation, **queued),
        traced(start + 10, "change_started", session, changeID=change_id, operation=operation),
        traced(start + 20, "ribbon_animation_started", session, changeID=change_id),
        traced(start + settled, "change_completed", session, changeID=change_id, operation=operation),
    ]


class ChangeTraceTests(unittest.TestCase):
    def test_two_sessions_reusing_change_ids_pair_within_their_own_session(self):
        events = change(0, "1", session="a", settled=300) + change(1000, "1", session="b", settled=100)
        summary = analyze_log.summarize_changes(events)
        self.assertEqual(summary.nav["action -> settled"], [300, 100])
        self.assertEqual(summary.nav["action -> motion scheduled"], [20, 20])
        self.assertEqual(summary.approximate_sessions, 0)
        self.assertFalse([key for key in summary.counts if key.startswith(analyze_log.INTEGRITY_PREFIXES)])

    def test_legacy_launches_reusing_ids_are_split_and_labelled_approximate(self):
        def launch(start, settled):
            return [event(start, "session_started"),
                    event(start + 1, "change_queued", changeID="1", operation="action.focusNext"),
                    event(start + 5, "change_started", changeID="1", operation="action.focusNext"),
                    event(start + settled, "change_completed", changeID="1", operation="action.focusNext")]
        summary = analyze_log.summarize_changes(launch(0, 301) + launch(2000, 101))
        self.assertEqual(summary.nav["action -> settled"], [300, 100])
        self.assertEqual(summary.approximate_sessions, 2)

    def test_legacy_sessions_split_where_ids_restart_or_after_a_long_gap(self):
        hour = 60 * 60 * 1000
        events = analyze_log.annotate_sessions([
            {"timestamp": "2026-11-12T10:00:00.000Z", "event": "change_queued", "details": {"changeID": "1"}},
            {"timestamp": "2026-11-12T10:00:01.000Z", "event": "change_queued", "details": {"changeID": "2"}},
            {"timestamp": "2026-11-12T10:00:02.000Z", "event": "change_queued", "details": {"changeID": "1"}},
            {"timestamp": "2026-11-12T11:00:02.000Z", "event": "resource_sample", "details": {}},
        ])
        self.assertEqual([e["_session"] for e in events], ["legacy-1", "legacy-1", "legacy-2", "legacy-3"])
        self.assertTrue(all(e["_approximate"] for e in events))
        self.assertEqual(events[3]["_t"] - events[2]["_t"], hour)

    def test_cancelled_and_interrupted_changes_are_counted_by_outcome_not_timed(self):
        summary = analyze_log.summarize_changes([
            traced(0, "change_queued", changeID="1", operation="action.focusNext", origin="command"),
            traced(5, "change_queued", changeID="2", operation="refresh", origin="system"),
            traced(10, "change_started", changeID="1", operation="action.focusNext"),
            traced(90, "change_ended", changeID="1", operation="action.focusNext", outcome="interrupted",
                   reason="manual"),
            traced(91, "change_ended", changeID="2", operation="refresh", outcome="cancelled", reason="manual"),
        ])
        self.assertEqual(summary.nav["action -> settled"], [])
        self.assertEqual(summary.counts["ended interrupted"], 1)
        self.assertEqual(summary.counts["ended cancelled"], 1)
        self.assertEqual(summary.counts["incomplete: started, never completed"], 0)
        action = summary.by_kind[("command", "action.focusNext")]
        self.assertEqual((action["wait"], action["processing"]), ([10], [80]))
        refresh = summary.by_kind[("system", "refresh")]
        self.assertEqual((refresh["wait"], refresh["outcomes"]["cancelled"]), ([], 1))

    def test_a_merged_step_is_not_timed_and_its_successor_keeps_its_own_motion_and_focus(self):
        summary = analyze_log.summarize_changes([
            traced(0, "change_queued", changeID="1", operation="action.focusNext"),
            traced(5, "change_queued", changeID="2", operation="action.focusNext"),
            traced(10, "change_started", changeID="1", operation="action.focusNext"),
            traced(11, "change_ended", changeID="1", operation="action.focusNext", outcome="merged",
                   successorChangeID="2", reason="navigation_batched"),
            traced(12, "change_started", changeID="2", operation="action.focusNext"),
            traced(15, "ribbon_animation_started", changeID="2"),
            traced(25, "ribbon_animation_started", gestureID="4", operation="gesture.preview.restore"),
            traced(205, "navigation_focus_confirmed", changeID="2", focusConfirmed="true"),
            traced(305, "change_completed", changeID="2", operation="action.focusNext"),
        ])
        self.assertEqual(summary.nav["action -> motion scheduled"], [10])
        self.assertEqual(summary.nav["action -> focus confirmed"], [200])
        self.assertEqual(summary.nav["action -> settled"], [300])
        self.assertEqual(summary.counts["ended merged"], 1)
        self.assertEqual(summary.by_kind[("command", "action.focusNext")]["outcomes"],
                         collections.Counter(completed=1, merged=1))

    def test_pairing_runs_before_the_time_range_so_boundary_changes_are_cut_not_mispaired(self):
        events = (change(0, "1", settled=3000)            # queued before --since, ends inside
                  + change(4000, "2", settled=200)       # entirely inside
                  + change(8000, "3", settled=3000)      # queued inside, ends after --until
                  + [traced(9000, "change_queued", "s2", changeID="4", operation="action.focusNext"),
                     traced(9010, "change_started", "s2", changeID="4", operation="action.focusNext")])
        summary = analyze_log.summarize_changes(events, since="2026-11-12T12:00:02",
                                                until="2026-11-12T12:00:10")
        self.assertEqual(summary.nav["action -> settled"], [200])
        self.assertEqual(summary.counts["cut by the time range: queued before it"], 1)
        self.assertEqual(summary.counts["cut by the time range: ended after it"], 1)
        self.assertEqual(summary.counts["no terminal event (log ended)"], 1)
        self.assertFalse([key for key in summary.counts if key.startswith("orphan")])

    def test_a_change_left_without_a_terminal_while_the_session_went_on_is_reported(self):
        events = [traced(0, "change_queued", changeID="1", operation="refresh"),
                  traced(5, "change_started", changeID="1", operation="refresh")] + change(100, "2")
        summary = analyze_log.summarize_changes(events)
        self.assertEqual(summary.counts["no terminal event (session went on)"], 1)

    def test_orphan_events_and_duplicate_terminals_are_reported(self):
        events = change(0, "1") + [
            traced(400, "change_completed", changeID="1", operation="action.focusNext"),
            traced(500, "change_started", changeID="9", operation="refresh"),
        ]
        summary = analyze_log.summarize_changes(events)
        self.assertEqual(summary.counts["duplicate terminal events"], 1)
        self.assertEqual(summary.counts["orphan change_started: no change_queued for its change ID"], 1)
        self.assertEqual(summary.nav["action -> settled"], [300])

    def test_durations_use_monotonic_uptime_when_the_wall_clock_steps(self):
        events = [traced(5000, "change_queued", uptime=100, changeID="1", operation="action.focusNext"),
                  traced(5010, "change_started", uptime=110, changeID="1", operation="action.focusNext"),
                  traced(1000, "change_completed", uptime=350, changeID="1", operation="action.focusNext")]
        summary = analyze_log.summarize_changes(events)
        self.assertEqual(summary.nav["action -> settled"], [250])

    def test_a_swipe_joins_the_change_it_queued_by_gesture_id(self):
        summary = analyze_log.summarize_changes([
            traced(0, "gesture_motion_started", gestureID="3"),
            traced(10, "gesture_motion_started", session="other", gestureID="3"),
            traced(55, "change_queued", changeID="1", operation="action.focusNext", origin="gesture", gestureID="3"),
            traced(400, "change_completed", changeID="1", operation="action.focusNext"),
        ])
        self.assertEqual(summary.nav["swipe start -> action"], [55])
        self.assertIn(("gesture", "action.focusNext"), summary.by_kind)


def stamped(start, change_id, outcome=None, **stamps):
    """A change whose terminal event carries felt-delay stamps (ms offsets from 5_000_000 + start)."""
    base = 5_000_000 + start
    details = {key: str(base + value) if key.endswith("UptimeMs") else str(value) for key, value in stamps.items()}
    terminal = (traced(start + 400, "change_ended", changeID=change_id, operation="action.focusNext",
                       outcome=outcome, reason="test", **details) if outcome else
                traced(start + 400, "change_completed", changeID=change_id, operation="action.focusNext", **details))
    return [traced(start, "change_queued", changeID=change_id, operation="action.focusNext"),
            traced(start + 10, "change_started", changeID=change_id, operation="action.focusNext"),
            terminal]


class FeltDelayTests(unittest.TestCase):
    def test_felt_delays_come_from_the_terminal_trace_by_input_source_and_outcome(self):
        keyboard = dict(inputSource="keyboardTap", inputEventUptimeMs=-6, inputReceivedUptimeMs=-5,
                        inputDeliveredUptimeMs=-2, queuedUptimeMs=0, startedUptimeMs=3,
                        motionScheduledUptimeMs=14, firstAcknowledgedWriteUptimeMs=34, focusConfirmedUptimeMs=294,
                        heldInputEvents=2, heldInputTransferAgeMs=300, oldestHeldInputAgeMs=120)
        events = (stamped(0, "1", **keyboard)
                  + stamped(1000, "2", inputSource="hotKeyCallback", inputReceivedUptimeMs=0,
                            inputDeliveredUptimeMs=0, queuedUptimeMs=0, startedUptimeMs=50)
                  + stamped(2000, "3", queuedUptimeMs=0, startedUptimeMs=5, motionScheduledUptimeMs=25)
                  + stamped(3000, "4", outcome="superseded", inputSource="trackpad", inputEventUptimeMs=-10,
                            inputReceivedUptimeMs=-9, inputDeliveredUptimeMs=-1, queuedUptimeMs=0,
                            startedUptimeMs=2, motionScheduledUptimeMs=8))
        felt = analyze_log.summarize_changes(events).felt

        keys = felt[("keyboardTap", "completed")]
        self.assertEqual(keys["input -> main"], [4])
        self.assertEqual(keys["queue wait"], [3])
        self.assertEqual(keys["to motion scheduled"], [20])
        self.assertEqual(keys["to first acknowledged write"], [40])
        self.assertEqual(keys["to focus confirmed"], [300])
        self.assertEqual(keys["held input: oldest event age"], [120])
        self.assertEqual(keys["held input events"], [2])
        self.assertEqual(felt[("hotKeyCallback", "completed")]["input -> main"], [0])
        self.assertEqual(felt[("hotKeyCallback", "completed")]["queue wait"], [50])
        self.assertEqual(felt[("none", "completed")]["to motion scheduled"], [25], "from queued without input")
        self.assertNotIn("input -> main", felt[("none", "completed")])
        self.assertEqual(felt[("trackpad", "superseded")]["input -> main"], [9])
        self.assertEqual(felt[("trackpad", "superseded")]["to motion scheduled"], [18])

    def test_changes_from_before_the_stamps_have_no_felt_delays(self):
        self.assertEqual(dict(analyze_log.summarize_changes(change(0, "1")).felt), {})

    def test_follows_are_summarized_by_how_they_ended(self):
        def follow(handoff, **details):
            base = dict(durationMilliseconds="55", ticks="7", droppedTicks="1", largestTickGapMilliseconds="33",
                        largestCallbackGapMilliseconds="35", lateCallbacks="0",
                        followStartedAfterTouchMilliseconds="40", firstAcknowledgedWriteAfterTouchMilliseconds="60",
                        motionWritesSent="14", motionWritesAcknowledged="13", motionWritesUnacknowledged="1",
                        motionWritesFailed="0", handoff=handoff)
            base.update(details)
            return traced(0, "gesture_follow_ended", **base)
        handoffs, numbers, counts = analyze_log.summarize_follows(analyze_log.annotate_sessions([
            follow("change", handoffChangeID="3"),
            follow("settle", settleOperation="gesture.preview.restore", durationMilliseconds="400",
                   droppedTicks="unknown", firstAcknowledgedWriteAfterTouchMilliseconds="none"),
            follow("cancelled"),
        ]))
        self.assertEqual(handoffs, {"change": 1, "settle (gesture.preview.restore)": 1, "cancelled": 1})
        self.assertEqual(numbers["durationMilliseconds"], [55, 400, 55])
        self.assertEqual(numbers["firstAcknowledgedWriteAfterTouchMilliseconds"], [60, 60])
        self.assertEqual(counts["dropped ticks"], 2)
        self.assertEqual(counts["dropped ticks unknown"], 1)
        self.assertEqual(counts["motionWritesUnacknowledged"], 3)


class StallKindTests(unittest.TestCase):
    def test_near_zero_cpu_at_high_load_is_starved_and_at_low_load_waiting(self):
        self.assertEqual(analyze_log.stall_kind(200, 150, 3.0, high_load=10), "computing")
        self.assertEqual(analyze_log.stall_kind(200, 5, 167.0, high_load=10), "starved")
        self.assertEqual(analyze_log.stall_kind(200, 5, 2.0, high_load=10), "waiting")
        self.assertEqual(analyze_log.stall_kind(200, 60, 167.0, high_load=10), "waiting")
        self.assertEqual(analyze_log.stall_kind(200, 5, None, high_load=10), "waiting")


class CommandTests(unittest.TestCase):
    def run_analyzer(self, events, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "stagehand.log"
            log.write_text("".join(json.dumps(e) + "\n" for e in events) + "not json\n")
            result = subprocess.run([sys.executable, "-I", str(_path), "--log", str(log), *arguments],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_mixed_legacy_and_traced_log_reports_with_split_and_starved_stalls(self):
        legacy = [event(0, "session_started"),
                  event(1, "change_queued", changeID="1", operation="action.focusNext"),
                  event(2, "change_started", changeID="1", operation="action.focusNext"),
                  event(300, "change_completed", changeID="1", operation="action.focusNext")]
        stall = traced(4100, "main_thread_stall", waitedMilliseconds="200", mainThreadCPUMilliseconds="2",
                       loadAverage="167.0", lastEvent="change_started")
        output = self.run_analyzer(legacy + [traced(3000, "session_started")] + change(4000, "1") + [stall],
                                   "--split", "2026-11-12T12:00:03", "--high-load", "10")
        before, after = output.split("== after")
        self.assertIn("1 launch(es) without session IDs", before)
        self.assertNotIn("without session IDs", after)
        self.assertIn("change traces: all paired", after)
        self.assertIn("starved", after)
        self.assertIn("command  action.focusNext", after)

    def test_felt_delays_and_follows_are_reported(self):
        events = stamped(0, "1", inputSource="keyboardTap", inputEventUptimeMs=-6, inputReceivedUptimeMs=-5,
                         inputDeliveredUptimeMs=-2, queuedUptimeMs=0, startedUptimeMs=3,
                         focusConfirmedUptimeMs=294)
        events.append(traced(500, "gesture_follow_ended", handoff="settle", settleOperation="gesture.preview.restore",
                             durationMilliseconds="380", ticks="23", droppedTicks="0",
                             largestCallbackGapMilliseconds="21", motionWritesSent="40"))
        output = self.run_analyzer(events)
        self.assertIn("-- felt delays (ms) by input source and outcome", output)
        self.assertIn("  keyboardTap completed (n=1)", output)
        self.assertRegex(output, r"input -> main +n=1 p50=4 ")
        self.assertRegex(output, r"to focus confirmed +n=1 p50=300 ")
        self.assertIn("gesture follows (gesture_follow_ended, n=1; ms unless noted): ended by "
                      "settle (gesture.preview.restore) 1", output)
        self.assertRegex(output, r"durationMilliseconds +n=1 p50=380 ")

    def test_a_diagnostic_run_is_left_out_without_dropping_another_session(self):
        events = ([traced(0, "diagnostic_run_began", session="bench", kind="benchmark")]
                  + change(100, "1", session="app")
                  + change(200, "1", session="bench", settled=900)
                  + [traced(1500, "diagnostic_run_ended", session="bench", kind="benchmark")])
        output = self.run_analyzer(events)
        self.assertRegex(output, r"action -> settled +n=1 p50=300 ")


if __name__ == "__main__":
    unittest.main()
