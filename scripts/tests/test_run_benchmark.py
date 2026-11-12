import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / "run-benchmark.sh"

STUB = """#!/bin/bash
while (( $# )); do
    case "$1" in
        --acceptance-output) report="$2"; shift ;;
        --raw-output) raw="$2"; shift ;;
        --diagnostic-log) log="$2"; shift ;;
        --busy) busy=1 ;;
    esac
    shift
done
behavior="${STUB_BEHAVIOR:-pass}"
[[ -n "${busy:-}" && -n "${STUB_BUSY_BEHAVIOR:-}" ]] && behavior="$STUB_BUSY_BEHAVIOR"
echo '{"schema": 1, "result": "pass"}' > "$raw"
echo 'event' > "$log"
case "$behavior" in
    pass) printf 'Benchmark\\nResult: PASS\\n' > "$report" ;;
    fail-line) printf 'FAIL: the probe windows did not appear.\\nResult: PASS\\n' > "$report" ;;
    no-verdict) printf 'Benchmark\\nResult: PASS\\nextra\\n' > "$report" ;;
    no-report) ;;
    hang)
        printf 'Benchmark\\n' > "$report"
        while :; do sleep 0.2; done ;;
esac
"""


class RunBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "Stagehand.app"
        executable = self.app / "Contents/MacOS/Stagehand"
        executable.parent.mkdir(parents=True)
        executable.write_text(STUB)
        executable.chmod(0o755)
        self.results = self.root / "results"

    def tearDown(self):
        self.temporary.cleanup()

    def run_runner(self, modes, **environment):
        env = dict(os.environ, STAGEHAND_APP=str(self.app), BENCHMARK_RESULTS_DIR=str(self.results),
                   BENCHMARK_LAUNCH="direct", BENCHMARK_MODES=modes, BENCHMARK_REPEAT="1")
        env.update(environment)
        return subprocess.run(["/bin/bash", str(RUNNER)], env=env, capture_output=True, text=True, timeout=60)

    def run_dirs(self):
        return sorted(self.results.iterdir()) if self.results.exists() else []

    def meta(self, directory):
        return json.loads((directory / "meta.json").read_text())

    def test_results_folder_with_a_space_in_its_path_works(self):
        spaced = self.results / "Application Support" / "Benchmarks"
        result = self.run_runner("busy", BENCHMARK_RESULTS_DIR=str(spaced))
        self.assertEqual(result.returncode, 0, result.stderr)
        [directory] = sorted(spaced.iterdir())
        self.assertTrue((directory / "meta.json").is_file())

    def test_each_mode_runs_three_times_by_default(self):
        env = dict(os.environ, STAGEHAND_APP=str(self.app), BENCHMARK_RESULTS_DIR=str(self.results),
                   BENCHMARK_LAUNCH="direct", BENCHMARK_MODES="busy")
        env.pop("BENCHMARK_REPEAT", None)
        result = subprocess.run(["/bin/bash", str(RUNNER)], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([d.name.rsplit("-", 1)[1] for d in self.run_dirs()], ["r1", "r2", "r3"])

    def test_passing_repeats_save_one_directory_each(self):
        result = self.run_runner("busy-tiles", BENCHMARK_REPEAT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        directories = self.run_dirs()
        self.assertEqual([d.name.rsplit("-", 3)[1:] for d in directories],
                         [["busy", "tiles", "r1"], ["busy", "tiles", "r2"]])
        for repeat, directory in enumerate(directories, start=1):
            self.assertRegex(directory.name, r"^\d{8}T\d{6}Z-[0-9a-f]{7}(-dirty)?-busy-tiles-r[12]$")
            self.assertEqual(sorted(p.name for p in directory.iterdir()),
                             ["diagnostic.log", "meta.json", "raw.json", "report.txt"])
            meta = self.meta(directory)
            self.assertEqual(meta["mode"], "busy-tiles")
            self.assertEqual(meta["flags"], ["--busy", "--tiles"])
            self.assertTrue(meta["loggingEnabled"])
            self.assertEqual((meta["repeat"], meta["repeats"]), (repeat, 2))
            self.assertEqual((meta["outcome"], meta["exitStatus"]), ("pass", 0))
            self.assertRegex(meta["git"]["sha"], r"^[0-9a-f]{40}$")
            self.assertEqual(meta["app"]["path"], str(self.app))
            self.assertIsNotNone(meta["app"]["executableModified"])
            for key in ["macOS", "macOSBuild", "model"]:
                self.assertTrue(meta["machine"][key])
            self.assertEqual(set(meta["loadAverageAtStart"]), {"1m", "5m"})
            self.assertTrue(meta["startUtc"].endswith("Z") and meta["endUtc"].endswith("Z"))

    def test_meta_names_the_app_bundle_apart_from_the_runner_checkout(self):
        plist = self.app / "Contents/Info.plist"
        plist.write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1234567-dirty</string>
<key>CFBundleVersion</key><string>812</string>
</dict></plist>
''')
        result = self.run_runner("busy")
        self.assertEqual(result.returncode, 0, result.stderr)
        [directory] = self.run_dirs()
        meta = self.meta(directory)
        self.assertEqual((meta["app"]["version"], meta["app"]["buildNumber"]), ("1234567-dirty", "812"))
        self.assertFalse(meta["git"]["holdsApp"])
        self.assertEqual(meta["git"]["checkout"], str(RUNNER.parents[1]))

    def test_single_run_has_no_repeat_suffix_and_quiet_turns_logging_off(self):
        result = self.run_runner("busy-quiet")
        self.assertEqual(result.returncode, 0, result.stderr)
        [directory] = self.run_dirs()
        self.assertTrue(directory.name.endswith("-busy-quiet"))
        meta = self.meta(directory)
        self.assertEqual(meta["flags"], ["--busy", "--no-diagnostics"])
        self.assertFalse(meta["loggingEnabled"])

    def test_gestures_suffix_asks_the_app_for_synthetic_gestures(self):
        result = self.run_runner("busy-quiet-gestures")
        self.assertEqual(result.returncode, 0, result.stderr)
        [directory] = self.run_dirs()
        self.assertEqual(self.meta(directory)["flags"], ["--busy", "--no-diagnostics", "--gestures"])

    def test_a_larger_workspace_is_passed_to_the_app_and_named(self):
        result = self.run_runner("busy", BENCHMARK_WINDOWS="12")
        self.assertEqual(result.returncode, 0, result.stderr)
        [directory] = self.run_dirs()
        self.assertTrue(directory.name.endswith("-busy-w12"))
        self.assertEqual(self.meta(directory)["flags"], ["--busy", "--probe-windows", "12"])

    def test_too_few_windows_for_the_probe_apps_are_rejected(self):
        for value in ["2", "twelve"]:
            result = self.run_runner("busy", BENCHMARK_WINDOWS=value)
            self.assertEqual(result.returncode, 1)
            self.assertIn("BENCHMARK_WINDOWS must be a whole number of at least 3", result.stderr)
        self.assertEqual(self.run_dirs(), [])

    def test_failing_mode_still_runs_the_rest_then_exits_non_zero(self):
        result = self.run_runner("busy responsive", STUB_BUSY_BEHAVIOR="fail-line")
        self.assertEqual(result.returncode, 1)
        failed, passed = self.run_dirs()
        self.assertTrue(failed.name.endswith("-busy") and passed.name.endswith("-responsive"))
        self.assertEqual(self.meta(failed)["outcome"], "fail")
        self.assertEqual(self.meta(failed)["exitStatus"], 1)
        self.assertIn("report has a line starting with FAIL", self.meta(failed)["failureReasons"])
        self.assertEqual(self.meta(passed)["outcome"], "pass")
        self.assertIn("1 benchmark run(s) failed", result.stderr)

    def test_last_line_must_be_exactly_the_pass_verdict(self):
        result = self.run_runner("responsive", STUB_BEHAVIOR="no-verdict")
        self.assertEqual(result.returncode, 1)
        [directory] = self.run_dirs()
        self.assertEqual(self.meta(directory)["failureReasons"], ["report's last line is not 'Result: PASS'"])

    def test_missing_report_fails_and_keeps_the_directory(self):
        result = self.run_runner("responsive", STUB_BEHAVIOR="no-report")
        self.assertEqual(result.returncode, 1)
        [directory] = self.run_dirs()
        self.assertTrue((directory / "raw.json").exists())
        self.assertEqual(self.meta(directory)["failureReasons"], ["no report"])

    def test_timeout_stops_the_app_and_keeps_partial_output(self):
        result = self.run_runner("responsive busy", STUB_BUSY_BEHAVIOR="hang", BENCHMARK_TIMEOUT="2")
        self.assertEqual(result.returncode, 1)
        responsive, busy = sorted(self.run_dirs(), key=lambda d: d.name.endswith("-busy"))
        meta = self.meta(busy)
        self.assertEqual((meta["outcome"], meta["exitStatus"]), ("timeout", 1))
        self.assertIn("timed out after 2s", meta["failureReasons"])
        self.assertEqual((busy / "report.txt").read_text(), "Benchmark\n")
        self.assertEqual(self.meta(responsive)["outcome"], "pass")

    def test_invalid_repeat_count_is_rejected(self):
        result = self.run_runner("responsive", BENCHMARK_REPEAT="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("BENCHMARK_REPEAT", result.stderr)
        self.assertEqual(self.run_dirs(), [])


if __name__ == "__main__":
    unittest.main()
