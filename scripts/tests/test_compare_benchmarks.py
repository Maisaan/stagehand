import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fixtures

SCRIPT = Path(__file__).resolve().parents[1] / "compare-benchmarks.py"
spec = importlib.util.spec_from_file_location("compare_benchmarks", SCRIPT)
compare_benchmarks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare_benchmarks)


class CompareBenchmarksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def run_compare(self, baseline, candidate, *extra):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = compare_benchmarks.main([str(baseline), str(candidate), *extra])
        return status, out.getvalue() + err.getvalue()

    def section(self, output, phase, metric_key):
        lines = output.splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip() == phase)
        header = next(i for i in range(start, len(lines)) if f"({metric_key}, ms)" in lines[i])
        return "\n".join(lines[header:header + 4])

    def test_identical_runs_compare(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertNotIn("Refusing", output)
        self.assertIn("baseline 1 of 1 runs passed", output)
        self.assertIn("n=3 p50 220 p90 240 max 240", self.section(output, "sequential", "switches.focusMs"))

    def test_mismatched_mode_is_refused(self):
        baseline = fixtures.write_run(self.root / "base", fixtures.meta(mode="busy"))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(mode="responsive"))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 1)
        self.assertIn("Refusing to compare", output)
        self.assertIn('mode: baseline "busy", candidate "responsive"', output)
        self.assertNotIn("sequential", output)

    def test_mismatched_settings_are_refused_unless_allowed(self):
        baseline = fixtures.write_run(self.root / "base")
        changed = fixtures.modified(fixtures.raw(), lambda raw: raw["settings"].update(gap=8))
        candidate = fixtures.write_run(self.root / "cand", run_raw=changed)
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 1)
        self.assertIn("settings.gap: baseline -140, candidate 8", output)

        status, output = self.run_compare(baseline, candidate, "--allow-mismatch")
        self.assertEqual(status, 0)
        first_lines = output.splitlines()[:2]
        self.assertIn("Compared despite differences", first_lines[0])
        self.assertIn("settings.gap", first_lines[1])
        self.assertIn("sequential", output)

    def test_mismatched_environment_and_logging_are_refused(self):
        baseline = fixtures.write_run(self.root / "base")
        changed = fixtures.modified(fixtures.raw(), lambda raw: raw["environment"].update(backingScale=1))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(logging=False), changed)
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 1)
        self.assertIn("environment.backingScale: baseline 2, candidate 1", output)
        self.assertIn("logging: baseline true, candidate false", output)

    def test_runs_at_different_machine_load_are_refused(self):
        baseline = fixtures.write_run(self.root / "base", fixtures.meta(load=8.0))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40, load=11.0))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 1, output)
        self.assertIn("load at start differs", output)
        self.assertIn("baseline median 8.0 (range 8.0-8.0), candidate median 11.0", output)

    def test_runs_at_similar_machine_load_compare(self):
        baseline = fixtures.write_run(self.root / "base", fixtures.meta(load=8.0))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40, load=9.5))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertIn("start load median 9.5", output)

    def test_one_side_mixing_builds_is_refused(self):
        fixtures.write_run(self.root / "base/r1", fixtures.meta(sha="a" * 40))
        fixtures.write_run(self.root / "base/r2", fixtures.meta(sha="c" * 40))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40))
        status, output = self.run_compare(self.root / "base", candidate)
        self.assertEqual(status, 1)
        self.assertIn("baseline mixes builds", output)

    def test_builds_are_identified_by_the_bundle_not_the_runner_checkout(self):
        def with_build(version):
            return fixtures.modified(fixtures.raw(), lambda raw: raw.update(
                build={"version": version, "buildNumber": "812", "executableModified": "2026-11-13T01:00:00Z"}))
        fixtures.write_run(self.root / "base/r1", fixtures.meta(sha="a" * 40), with_build("1111111"))
        fixtures.write_run(self.root / "base/r2", fixtures.meta(sha="c" * 40), with_build("1111111"))
        fixtures.write_run(self.root / "cand/r1", fixtures.meta(sha="b" * 40), with_build("2222222"))
        fixtures.write_run(self.root / "cand/r2", fixtures.meta(sha="b" * 40), with_build("3333333"))
        status, output = self.run_compare(self.root / "base", self.root / "cand")
        self.assertEqual(status, 1)
        self.assertNotIn("baseline mixes builds", output)
        self.assertIn("candidate mixes builds: 2222222 #812", output)

    def test_missing_phase_is_reported_not_zero(self):
        baseline = fixtures.write_run(self.root / "base")
        without_rapid = fixtures.modified(fixtures.raw(), lambda raw: raw["phases"].pop("rapid"))
        candidate = fixtures.write_run(self.root / "cand", run_raw=without_rapid)
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertIn("GAP candidate cand: phase rapid missing", output)
        rapid = self.section(output, "rapid", "settledMs")
        self.assertIn("candidate  missing in every run", rapid)
        self.assertNotIn("change", rapid)

    def test_missing_panes_phase_is_reported_when_tiles_ran(self):
        with_tiles = fixtures.raw(tiles=True)
        baseline = fixtures.write_run(self.root / "base", run_raw=with_tiles)
        without_panes = fixtures.modified(with_tiles, lambda raw: raw["phases"].pop("panes"))
        candidate = fixtures.write_run(self.root / "cand", run_raw=without_panes)
        status, output = self.run_compare(baseline, candidate)
        self.assertIn("GAP candidate cand: phase panes missing", output)

    def test_panes_are_a_new_phase_next_to_an_old_column_run(self):
        columns = fixtures.modified(fixtures.raw(), lambda raw: (
            raw["settings"].pop("tiles"), raw["settings"].update(columnStacks=True),
            raw["phases"].update(members=fixtures.switch_phase((200.0, 220.0, 240.0)))))
        baseline = fixtures.write_run(self.root / "base", fixtures.meta(mode="busy-columns"), columns)
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(mode="busy-tiles", sha="b" * 40),
                                       fixtures.raw(tiles=True))
        status, output = self.run_compare(baseline, candidate, "--allow-mismatch")
        self.assertEqual(status, 0, output)
        self.assertNotIn("GAP", output)
        self.assertIn("candidate  missing in every run", self.section(output, "members", "switches.focusMs"))
        self.assertIn("baseline   missing in every run", self.section(output, "panes", "switches.focusMs"))

    def test_missing_switch_key_is_reported(self):
        baseline = fixtures.write_run(self.root / "base")
        no_focus = fixtures.modified(fixtures.raw(), lambda raw: raw["phases"]["sequential"]["switches"][0].pop("focusMs"))
        candidate = fixtures.write_run(self.root / "cand", run_raw=no_focus)
        status, output = self.run_compare(baseline, candidate)
        self.assertIn("sequential.switches[].focusMs missing in 1 of 3 switches", output)

    def with_trace(self, raw, first_write=20.0, unacknowledged=0):
        for phase in ["sequential", "spaces"]:
            for switch in raw["phases"][phase]["switches"]:
                switch.update(changeOutcome="completed", queueWaitMs=0.5,
                              firstAcknowledgedWriteMs=first_write if switch["slid"] else None,
                              motionEndedMs=250.0 if switch["slid"] else None,
                              motionWritesAcknowledged=14 if switch["slid"] else None,
                              motionWritesUnacknowledged=unacknowledged if switch["slid"] else None,
                              motionWritesFailed=0 if switch["slid"] else None)
        return raw

    def test_trace_metrics_are_compared_when_both_sides_have_them(self):
        baseline = fixtures.write_run(self.root / "base", run_raw=self.with_trace(fixtures.raw()))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40),
                                       self.with_trace(fixtures.raw(), first_write=30.0, unacknowledged=2))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        section = self.section(output, "sequential", "switches.firstAcknowledgedWriteMs")
        self.assertIn("baseline   n=3 p50 20", section)
        self.assertIn("candidate  n=3 p50 30", section)
        self.assertIn("unacknowledged motion writes per run: baseline 0; candidate 6", output)
        spaces = self.section(output, "spaces", "switches.firstAcknowledgedWriteMs")
        self.assertIn("1 no acknowledged write", spaces)
        self.assertNotIn("GAP", output)

    def test_trace_metrics_are_left_out_when_one_side_predates_them(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40),
                                       self.with_trace(fixtures.raw()))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        for key in ["queueWaitMs", "firstAcknowledgedWriteMs", "motionEndedMs"]:
            self.assertNotIn(key, output)
        self.assertNotIn("unacknowledged motion writes", output)
        self.assertNotIn("GAP", output)
        self.assertIn("switches.focusMs", output)

    def with_cost(self, raw, cpu=300.0, idle_cpu=40.0, unavailable_phase=None):
        def cost(cpu_ms, seconds):
            return {"available": True, "durationMs": seconds * 1000, "cpuMs": cpu_ms,
                    "cpuPercent": cpu_ms / seconds / 10, "idleWakeups": int(20 * seconds),
                    "idleWakeupsPerSecond": 20.0, "interruptWakeups": int(150 * seconds),
                    "interruptWakeupsPerSecond": 150.0}
        for phase in ["start", "sequential", "rapid", "spaces", "interface"]:
            raw["phases"][phase]["resourceCost"] = cost(cpu, 3.0)
        raw["phases"]["idle"] = {"seconds": 10.0, "latencyMonitorStopped": True, "resourceCost": cost(idle_cpu, 10.0)}
        if unavailable_phase:
            raw["phases"][unavailable_phase]["resourceCost"].update(
                available=False, cpuMs=None, cpuPercent=None, idleWakeups=None, idleWakeupsPerSecond=None,
                interruptWakeups=None, interruptWakeupsPerSecond=None)
        return raw

    def test_phase_resource_cost_and_idle_are_compared_when_both_sides_have_them(self):
        baseline = fixtures.write_run(self.root / "base", run_raw=self.with_cost(fixtures.raw()))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40),
                                       self.with_cost(fixtures.raw(), cpu=360.0, idle_cpu=55.0))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        sequential = self.section(output, "sequential", "resourceCost.cpuMs")
        self.assertIn("baseline   n=1 p50 300", sequential)
        self.assertIn("candidate  n=1 p50 360", sequential)
        idle = self.section(output, "idle", "resourceCost.cpuMs")
        self.assertIn("p50 +15.0 ms", idle)
        self.assertIn("idle wakeups (resourceCost.idleWakeupsPerSecond, /s)", output)
        self.assertIn("p50 +0.0 /s", output)
        self.assertNotIn("GAP", output)

    def test_phase_resource_cost_is_left_out_when_one_side_predates_it(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40), self.with_cost(fixtures.raw()))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertNotIn("resourceCost", output)
        self.assertNotIn("  idle", output.splitlines())
        self.assertNotIn("GAP", output)

    def test_an_unreadable_resource_sample_is_unavailable_not_zero(self):
        baseline = fixtures.write_run(self.root / "base", run_raw=self.with_cost(fixtures.raw()))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40),
                                       self.with_cost(fixtures.raw(), unavailable_phase="sequential"))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertIn("candidate  no samples  (1 unavailable)", self.section(output, "sequential", "resourceCost.cpuMs"))

    def test_stall_kinds_are_counted_when_both_sides_classify_stalls(self):
        def classified(raw, kind):
            for stall in raw["phases"]["sequential"]["stalls"]:
                stall.update(mainThreadCPUMs=2.0, loadAverage=40.0, kind=kind)
            raw["phases"]["rapid"]["stalls"] = [{"waitedMs": 90.0, "label": "unlabeled", "phase": "before",
                                                 "changeStep": None, "mainThreadCPUMs": None,
                                                 "loadAverage": None, "kind": None}]
            return raw
        baseline = fixtures.write_run(self.root / "base", run_raw=classified(fixtures.raw(), "waiting"))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40),
                                       classified(fixtures.raw(), "starved"))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertIn("starved stalls per run: baseline 0; candidate 1", output)
        self.assertIn("waiting stalls per run: baseline 1; candidate 0", output)
        self.assertIn("baseline   n=1 p50 90", self.section(output, "rapid", "stalls.waitedMs"))

    def test_stall_kinds_are_left_out_when_one_side_predates_them(self):
        baseline = fixtures.write_run(self.root / "base")
        classified = fixtures.modified(fixtures.raw(), lambda raw: raw["phases"]["sequential"]["stalls"][0].update(
            kind="computing"))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40), classified)
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertNotIn("computing stalls", output)
        self.assertNotIn("GAP", output)

    def test_gesture_scenarios_are_compared_one_scenario_at_a_time(self):
        baseline = fixtures.write_run(self.root / "base", fixtures.meta(mode="busy-gestures"),
                                      fixtures.with_gestures(fixtures.raw()))
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(mode="busy-gestures", sha="b" * 40),
                                       fixtures.with_gestures(fixtures.raw(), touch_to_write=35.0))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 0, output)
        self.assertNotIn("GAP", output)
        lines = output.splitlines()
        header = lines.index("   flick: touch to first acknowledged follow write "
                             "(gestures.follow.firstAcknowledgedWriteAfterTouchMs, ms)")
        self.assertIn("baseline   n=1 p50 20", lines[header + 1])
        self.assertIn("candidate  n=1 p50 35", lines[header + 2])
        slow = lines.index("   slowDrag: touch to first acknowledged follow write "
                           "(gestures.follow.firstAcknowledgedWriteAfterTouchMs, ms)")
        self.assertIn("candidate  n=1 p50 20", lines[slow + 2])
        self.assertIn("reversal: release to settled", output)
        self.assertNotIn("reversal: release to focus confirmed", output)
        self.assertIn("gestures not ending as their schedule should per run: baseline 0; candidate 0", output)

    def test_a_gesture_run_is_not_compared_with_one_without_gestures(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40),
                                       fixtures.with_gestures(fixtures.raw()))
        status, output = self.run_compare(baseline, candidate)
        self.assertEqual(status, 1)
        self.assertIn('settings.gestures: baseline false, candidate true', output)

    def test_a_missing_gesture_phase_is_reported_when_gestures_ran(self):
        baseline = fixtures.write_run(self.root / "base", run_raw=fixtures.with_gestures(fixtures.raw()))
        no_phase = fixtures.with_gestures(fixtures.raw())
        del no_phase["phases"]["gestures"]
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40), no_phase)
        status, output = self.run_compare(baseline, candidate)
        self.assertIn("GAP candidate cand: phase gestures missing", output)

    def test_null_focus_is_counted_as_unconfirmed_not_zero(self):
        baseline = fixtures.write_run(self.root / "base")
        unconfirmed = fixtures.raw(focus_times=(None, 220.0, 240.0))
        candidate = fixtures.write_run(self.root / "cand", run_raw=unconfirmed)
        status, output = self.run_compare(baseline, candidate)
        focus = self.section(output, "sequential", "switches.focusMs")
        self.assertIn("candidate  n=2 p50 240 p90 240 max 240  (1 focus unconfirmed)", focus)

    def test_failed_run_is_shown_and_left_out(self):
        fixtures.write_run(self.root / "base/r1", fixtures.meta(repeat=1, repeats=2))
        fixtures.write_run(self.root / "base/r2", fixtures.meta(repeat=2, repeats=2))
        fixtures.write_run(self.root / "cand/r1", fixtures.meta(sha="b" * 40, repeat=1, repeats=2))
        failing = fixtures.modified(fixtures.raw(focus_times=(900.0, 900.0, 900.0)), lambda raw: raw.update(
            result="fail", failures=["sequential: idle wait timed out after switch 2"]))
        fixtures.write_run(self.root / "cand/r2", fixtures.meta(sha="b" * 40, repeat=2, repeats=2,
                                                                exit_status=1, outcome="fail"), failing)
        status, output = self.run_compare(self.root / "base", self.root / "cand")
        self.assertEqual(status, 0, output)
        self.assertIn("candidate 1 of 2 runs passed", output)
        self.assertIn("FAILED candidate r2: runner marked the run fail", output)
        self.assertIn("FAILED candidate r2: app reported 'fail': sequential: idle wait timed out after switch 2", output)
        self.assertNotIn("900", self.section(output, "sequential", "switches.focusMs"))

    def test_missing_raw_json_is_a_failed_run(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", write_raw=False)
        status, output = self.run_compare(baseline, candidate)
        self.assertIn("FAILED candidate cand: raw.json missing", output)
        self.assertIn("Nothing to compare", output)

    def test_change_inside_baseline_spread_is_within_noise(self):
        fixtures.write_run(self.root / "base/r1", fixtures.meta(repeat=1, repeats=2), fixtures.raw((200.0, 200.0, 200.0)))
        fixtures.write_run(self.root / "base/r2", fixtures.meta(repeat=2, repeats=2), fixtures.raw((240.0, 240.0, 240.0)))
        fixtures.write_run(self.root / "quiet/r1", fixtures.meta(sha="b" * 40), fixtures.raw((220.0, 220.0, 220.0)))
        fixtures.write_run(self.root / "slow/r1", fixtures.meta(sha="c" * 40), fixtures.raw((300.0, 300.0, 300.0)))

        status, output = self.run_compare(self.root / "base", self.root / "quiet")
        focus = self.section(output, "sequential", "switches.focusMs")
        self.assertIn("spread p50 200-240", focus)
        self.assertIn("p50 -20.0 ms (-8%), p90 -20.0 ms (-8%), max -20.0 ms (-8%); within noise", focus)

        status, output = self.run_compare(self.root / "base", self.root / "slow")
        focus = self.section(output, "sequential", "switches.focusMs")
        self.assertIn("p50 +60.0 ms (+25%), p90 +60.0 ms (+25%), max +60.0 ms (+25%); outside baseline spread", focus)

        fixtures.write_run(self.root / "tail/r1", fixtures.meta(sha="d" * 40), fixtures.raw((220.0, 220.0, 300.0)))
        status, output = self.run_compare(self.root / "base", self.root / "tail")
        focus = self.section(output, "sequential", "switches.focusMs")
        self.assertIn("outside baseline spread: p90, max; within noise: p50", focus)

    def test_single_baseline_run_has_unknown_noise(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40))
        status, output = self.run_compare(baseline, candidate)
        self.assertIn("noise unknown: baseline has fewer than 2 runs", output)

    def test_empty_directory_is_an_error(self):
        (self.root / "empty").mkdir()
        baseline = fixtures.write_run(self.root / "base")
        status, output = self.run_compare(baseline, self.root / "empty")
        self.assertEqual(status, 1)
        self.assertIn("no benchmark results", output)

    def test_runs_isolated_as_a_command(self):
        baseline = fixtures.write_run(self.root / "base")
        candidate = fixtures.write_run(self.root / "cand", fixtures.meta(sha="b" * 40))
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(baseline), str(candidate)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("== busy:", result.stdout)


if __name__ == "__main__":
    unittest.main()
