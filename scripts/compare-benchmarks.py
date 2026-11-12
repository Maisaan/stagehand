#!/usr/bin/env python3
import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

RAW_SCHEMA = 1
ALWAYS_PRESENT_PHASES = ["start", "sequential", "rapid", "spaces", "interface"]
SWITCH_KEYS = ["slid", "motionScheduledMs", "focusMs", "focusRejected", "settledMs", "timedOut",
               "frameWorkMs", "droppedFrames", "focusedGapMs", "largestGapMs"]
PHASE_KEYS = {
    "start": ["callMs", "settledMs", "timedOut", "mainThreadWaitsMs"],
    "sequential": ["switches", "mainThreadWaitsMs", "stalls"],
    "members": ["switches", "mainThreadWaitsMs", "stalls"],
    "panes": ["switches", "mainThreadWaitsMs", "stalls"],
    "rapid": ["settledMs", "timedOut", "mainThreadWaitsMs", "finalFocusMatches"],
    "spaces": ["switches", "mainThreadWaitsMs", "finalFocusMatches"],
    "interface": ["appBarShowMs", "settingsOpenMs", "quickControlsOpenMs"],
}
SWITCH_PHASES = ["sequential", "members", "panes", "spaces"]
# T4's first comparison (median start load 8 vs 11) showed freezes 2-9 ms worse that vanished at equal load.
LOAD_TOLERANCE = 2.0


@dataclass
class Run:
    path: Path
    meta: dict
    raw: dict | None
    failures: list[str]
    gaps: list[str] = field(default_factory=list)

    @property
    def name(self):
        return self.path.name

    @property
    def mode(self):
        return self.meta.get("mode")

    @property
    def build(self):
        # The binary that ran, read by the app itself when it can be: the runner's checkout may not have built it.
        bundle = (self.raw or {}).get("build") or {}
        app = self.meta.get("app", {})
        version = bundle.get("version") or app.get("version")
        if version:
            return Build(version, bundle.get("buildNumber") or app.get("buildNumber"),
                         bundle.get("executableModified") or app.get("executableModified"))
        git = self.meta.get("git", {})
        sha = (git.get("sha") or "unknown")[:7] + ("-dirty" if git.get("dirty") else "")
        return Build(f"checkout {sha}", None, app.get("executableModified"))

    @property
    def passed(self):
        return not self.failures

    @property
    def start_load(self):
        return self.meta.get("loadAverageAtStart", {}).get("1m")


@dataclass(frozen=True)
class Build:
    version: str
    number: str | None
    modified: str | None

    def __str__(self):
        number = f" #{self.number}" if self.number else ""
        return f"{self.version}{number}"


@dataclass
class Samples:
    values: list[float] = field(default_factory=list)
    nulls: int = 0


@dataclass
class Metric:
    key: str
    label: str
    null_label: str = "null"


@dataclass
class Count:
    key: str
    label: str


class InputError(Exception):
    pass


def load_json(path):
    with open(path) as f:
        return json.load(f)


def load_run(path):
    try:
        meta = load_json(path / "meta.json")
    except (OSError, json.JSONDecodeError) as error:
        raise InputError(f"{path}: unreadable meta.json ({error})")
    failures = []
    if meta.get("outcome") == "running":
        failures.append("runner did not finish (meta.json still says running)")
    elif meta.get("exitStatus") != 0:
        reasons = "; ".join(meta.get("failureReasons") or []) or "no reason recorded"
        failures.append(f"runner marked the run {meta.get('outcome', 'failed')}: {reasons}")
    raw = None
    try:
        raw = load_json(path / "raw.json")
    except FileNotFoundError:
        failures.append("raw.json missing")
    except (OSError, json.JSONDecodeError) as error:
        failures.append(f"raw.json unreadable ({error})")
    if raw is not None:
        if raw.get("schema") != RAW_SCHEMA:
            failures.append(f"raw.json schema {raw.get('schema')!r} is not {RAW_SCHEMA}")
            raw = None
        elif raw.get("result") != "pass":
            listed = "; ".join(raw.get("failures") or []) or "no failures listed"
            failures.append(f"app reported {raw.get('result')!r}: {listed}")
    run = Run(path, meta, raw, failures)
    if raw is not None:
        run.gaps = find_gaps(raw)
    return run


def load_side(path):
    path = Path(path)
    if (path / "meta.json").is_file():
        return [load_run(path)]
    if not path.is_dir():
        raise InputError(f"{path}: not a directory")
    runs = [load_run(child) for child in sorted(path.iterdir()) if (child / "meta.json").is_file()]
    if not runs:
        raise InputError(f"{path}: no benchmark results (no meta.json here or in its subdirectories)")
    return runs


def expected_phases(raw):
    phases = list(ALWAYS_PRESENT_PHASES)
    settings = raw.get("settings") or {}
    if settings.get("tiles"):
        phases.insert(2, "panes")
    elif settings.get("columnStacks"):
        phases.insert(2, "members")
    return phases


def find_gaps(raw):
    gaps = []
    for key in ["environment", "settings", "phases"]:
        if not isinstance(raw.get(key), dict):
            gaps.append(f"{key} block missing")
    phases = raw.get("phases") or {}
    for phase in expected_phases(raw):
        if phase not in phases:
            gaps.append(f"phase {phase} missing")
            continue
        missing = [key for key in PHASE_KEYS[phase] if key not in phases[phase]]
        gaps.extend(f"{phase}.{key} missing" for key in missing)
        if phase in SWITCH_PHASES and isinstance(phases[phase].get("switches"), list):
            switch_gaps = {}
            for switch in phases[phase]["switches"]:
                for key in SWITCH_KEYS:
                    if key not in switch:
                        switch_gaps[key] = switch_gaps.get(key, 0) + 1
            total = len(phases[phase]["switches"])
            gaps.extend(f"{phase}.switches[].{key} missing in {count} of {total} switches"
                        for key, count in switch_gaps.items())
    return gaps


def numbers(value, samples):
    for item in value if isinstance(value, list) else [value]:
        if item is None:
            samples.nulls += 1
        else:
            samples.values.append(float(item))


def metric_definitions(phase):
    if phase == "start":
        return [Metric("callMs", "start call"), Metric("settledMs", "to settled"),
                Metric("mainThreadWaitsMs", "main-thread waits")]
    if phase == "rapid":
        return [Metric("settledMs", "to settled"), Metric("mainThreadWaitsMs", "main-thread waits")]
    if phase == "interface":
        return [Metric("appBarShowMs", "app bar show"), Metric("settingsOpenMs", "settings open"),
                Metric("quickControlsOpenMs", "quick controls open")]
    metrics = [
        Metric("switches.motionScheduledMs", "to motion scheduled", "not slid"),
        Metric("switches.focusMs", "to focus confirmed", "focus unconfirmed"),
        Metric("switches.settledMs", "to settled"),
        Metric("switches.frameWorkMs", "frame work per tick"),
        Metric("switches.focusedGapMs", "longest freeze of the destination"),
        Metric("switches.largestGapMs", "longest freeze of any moving window"),
        Metric("mainThreadWaitsMs", "main-thread waits"),
    ]
    if phase != "spaces":
        metrics.append(Metric("stalls.waitedMs", "stalls"))
    return metrics


def count_definitions(phase):
    if phase == "start":
        return [Count("timedOut", "timed out")]
    if phase == "rapid":
        return [Count("timedOut", "timed out"), Count("finalFocusMatches=false", "final focus wrong")]
    if phase == "interface":
        return []
    counts = [Count("switches.timedOut", "switches timed out"),
              Count("switches.focusRejected", "focus rejected"),
              Count("switches.droppedFrames", "dropped frames")]
    if phase == "spaces":
        counts.append(Count("finalFocusMatches=false", "final focus wrong"))
    else:
        counts.append(Count("stalls", "stalls"))
    return counts


def extract_metric(phase_data, key):
    container, _, field_name = key.rpartition(".")
    samples = Samples()
    if not container:
        if field_name not in phase_data:
            return None
        numbers(phase_data[field_name], samples)
        return samples
    items = phase_data.get(container)
    if not isinstance(items, list):
        return None
    present = [item for item in items if field_name in item]
    if items and not present:
        return None
    for item in present:
        numbers(item[field_name], samples)
    return samples


def extract_count(phase_data, key):
    if key.endswith("=false"):
        name = key.removesuffix("=false")
        return None if name not in phase_data else int(phase_data[name] is False)
    container, _, field_name = key.rpartition(".")
    if not container:
        value = phase_data.get(field_name)
        if value is None:
            return None
        return len(value) if isinstance(value, list) else int(bool(value))
    items = phase_data.get(container)
    if not isinstance(items, list) or any(field_name not in item for item in items):
        return None
    return sum(int(item[field_name] or 0) for item in items)


def percentile(sorted_values, fraction):
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * fraction))]


def summarize(values):
    ordered = sorted(values)
    return {"p50": percentile(ordered, 0.5), "p90": percentile(ordered, 0.9), "max": ordered[-1]}


def describe_dict_differences(prefix, left, right, left_name, right_name):
    differences = []
    for key in sorted(set(left) | set(right)):
        if left.get(key, "absent") != right.get(key, "absent"):
            differences.append(f"{prefix}.{key}: {left_name} {json.dumps(left.get(key, 'absent'))}, "
                               f"{right_name} {json.dumps(right.get(key, 'absent'))}")
    return differences


def comparable_profile(run):
    return {
        "mode": run.mode,
        "logging": run.meta.get("loggingEnabled"),
        "environment": None if run.raw is None else run.raw.get("environment") or {},
        "settings": None if run.raw is None else run.raw.get("settings") or {},
    }


def profile_differences(left, right, left_name, right_name):
    differences = []
    for key in ["mode", "logging"]:
        if left[key] != right[key]:
            differences.append(f"{key}: {left_name} {json.dumps(left[key])}, {right_name} {json.dumps(right[key])}")
    for block in ["environment", "settings"]:
        if left[block] is None or right[block] is None:
            continue
        differences += describe_dict_differences(block, left[block], right[block], left_name, right_name)
    return differences


def side_differences(side_name, runs):
    differences = []
    builds = {run.build for run in runs}
    if len(builds) > 1:
        listed = ", ".join(f"{build} built {build.modified}" for build in sorted(builds, key=repr))
        differences.append(f"{side_name} mixes builds: {listed}")
    by_mode = group_by_mode(runs)
    for mode, mode_runs in by_mode.items():
        with_raw = [run for run in mode_runs if run.raw is not None]
        for run in with_raw[1:]:
            for difference in profile_differences(comparable_profile(with_raw[0]), comparable_profile(run),
                                                  with_raw[0].name, run.name):
                differences.append(f"{side_name} {mode}: {difference}")
    return differences


def group_by_mode(runs):
    groups = {}
    for run in runs:
        groups.setdefault(run.mode, []).append(run)
    return groups


def representative(runs):
    with_raw = [run for run in runs if run.raw is not None]
    return comparable_profile(with_raw[0] if with_raw else runs[0])


def mode_pairs(baseline_modes, candidate_modes):
    if len(baseline_modes) == 1 and len(candidate_modes) == 1:
        return [(next(iter(baseline_modes)), next(iter(candidate_modes)))]
    return [(mode, mode) for mode in sorted(set(baseline_modes) & set(candidate_modes), key=str)]


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def describe_loads(loads):
    return f"median {median(loads):.1f} (range {min(loads):.1f}-{max(loads):.1f})"


def load_difference(baseline_runs, candidate_runs):
    baseline_loads = [run.start_load for run in baseline_runs if run.start_load is not None]
    candidate_loads = [run.start_load for run in candidate_runs if run.start_load is not None]
    if not baseline_loads or not candidate_loads:
        return []
    if abs(median(baseline_loads) - median(candidate_loads)) <= LOAD_TOLERANCE:
        return []
    return [f"1-minute load at start differs by more than {LOAD_TOLERANCE:.0f}: baseline "
            f"{describe_loads(baseline_loads)}, candidate {describe_loads(candidate_loads)}"]


def mismatches(baseline, candidate):
    differences = side_differences("baseline", baseline) + side_differences("candidate", candidate)
    baseline_modes = group_by_mode(baseline)
    candidate_modes = group_by_mode(candidate)
    pairs = mode_pairs(baseline_modes, candidate_modes)
    paired_baseline = {pair[0] for pair in pairs}
    paired_candidate = {pair[1] for pair in pairs}
    differences += [f"mode {mode}: only in baseline" for mode in sorted(set(baseline_modes) - paired_baseline, key=str)]
    differences += [f"mode {mode}: only in candidate" for mode in sorted(set(candidate_modes) - paired_candidate, key=str)]
    for baseline_mode, candidate_mode in pairs:
        differences += [f"{baseline_mode}: {difference}" for difference in profile_differences(
            representative(baseline_modes[baseline_mode]), representative(candidate_modes[candidate_mode]),
            "baseline", "candidate")]
        differences += [f"{baseline_mode}: {difference}" for difference in load_difference(
            baseline_modes[baseline_mode], candidate_modes[candidate_mode])]
    return differences, pairs


def format_number(value):
    return f"{value:.1f}" if abs(value) < 10 else f"{value:.0f}"


def format_stats(stats):
    return " ".join(f"{name} {format_number(stats[name])}" for name in ["p50", "p90", "max"])


def format_spread(per_run):
    if len(per_run) < 2:
        return ""
    parts = []
    for name in ["p50", "p90", "max"]:
        low = min(stats[name] for stats in per_run)
        high = max(stats[name] for stats in per_run)
        parts.append(f"{name} {format_number(low)}-{format_number(high)}")
    return "spread " + " ".join(parts)


def format_change(baseline_stats, candidate_stats, baseline_per_run):
    parts = []
    within, outside = [], []
    for name in ["p50", "p90", "max"]:
        before, after = baseline_stats[name], candidate_stats[name]
        change = f"{name} {after - before:+.1f} ms"
        if before:
            change += f" ({(after - before) / before:+.0%})"
        parts.append(change)
        if len(baseline_per_run) >= 2:
            low = min(stats[name] for stats in baseline_per_run)
            high = max(stats[name] for stats in baseline_per_run)
            (within if low <= after <= high else outside).append(name)
    if len(baseline_per_run) < 2:
        verdict = "noise unknown: baseline has fewer than 2 runs"
    elif not outside:
        verdict = "within noise"
    elif not within:
        verdict = "outside baseline spread"
    else:
        verdict = f"outside baseline spread: {', '.join(outside)}; within noise: {', '.join(within)}"
    return ", ".join(parts) + "; " + verdict


def collect_metric(runs, phase, metric):
    pooled = Samples()
    per_run = []
    missing = []
    for run in runs:
        phase_data = (run.raw.get("phases") or {}).get(phase)
        samples = None if phase_data is None else extract_metric(phase_data, metric.key)
        if samples is None:
            missing.append(run.name)
            continue
        pooled.values += samples.values
        pooled.nulls += samples.nulls
        if samples.values:
            per_run.append(summarize(samples.values))
    return pooled, per_run, missing


def side_line(label, pooled, per_run, missing, run_count, metric):
    if len(missing) == run_count:
        return f"    {label:<10} missing in every run"
    text = f"    {label:<10} "
    if pooled.values:
        text += f"n={len(pooled.values)} {format_stats(summarize(pooled.values))}"
        spread = format_spread(per_run)
        if spread:
            text += f"  {spread}"
    else:
        text += "no samples"
    if pooled.nulls:
        text += f"  ({pooled.nulls} {metric.null_label})"
    if missing:
        text += f"  (missing in {', '.join(missing)})"
    return text


def compare_mode(lines, baseline_runs, candidate_runs, title):
    baseline_ok = [run for run in baseline_runs if run.passed]
    candidate_ok = [run for run in candidate_runs if run.passed]
    lines.append(f"== {title}: baseline {len(baseline_ok)} of {len(baseline_runs)} runs passed, "
                 f"candidate {len(candidate_ok)} of {len(candidate_runs)} runs passed ==")
    for side, runs in [("baseline", baseline_runs), ("candidate", candidate_runs)]:
        for run in runs:
            for failure in run.failures:
                lines.append(f"  FAILED {side} {run.name}: {failure} (left out of the numbers)")
            for gap in run.gaps:
                lines.append(f"  GAP {side} {run.name}: {gap}")
    if not baseline_ok or not candidate_ok:
        lines.append("  Nothing to compare: a side has no passing runs.")
        lines.append("")
        return
    phases = []
    for run in baseline_ok + candidate_ok:
        for phase in expected_phases(run.raw) + list(run.raw.get("phases") or {}):
            if phase in PHASE_KEYS and phase not in phases:
                phases.append(phase)
    for phase in phases:
        lines.append(f"  {phase}")
        for metric in metric_definitions(phase):
            baseline = collect_metric(baseline_ok, phase, metric)
            candidate = collect_metric(candidate_ok, phase, metric)
            lines.append(f"   {metric.label} ({metric.key}, ms)")
            lines.append(side_line("baseline", *baseline, len(baseline_ok), metric))
            lines.append(side_line("candidate", *candidate, len(candidate_ok), metric))
            if baseline[0].values and candidate[0].values:
                lines.append("    change     " + format_change(summarize(baseline[0].values),
                                                               summarize(candidate[0].values), baseline[1]))
        for count in count_definitions(phase):
            cells = []
            for runs in [baseline_ok, candidate_ok]:
                values = []
                for run in runs:
                    phase_data = (run.raw.get("phases") or {}).get(phase)
                    value = None if phase_data is None else extract_count(phase_data, count.key)
                    values.append("missing" if value is None else str(value))
                cells.append(", ".join(values))
            lines.append(f"   {count.label} per run: baseline {cells[0]}; candidate {cells[1]}")
    lines.append("")


def side_header(name, runs):
    described = ", ".join(sorted({str(run.build) for run in runs}))
    modes = ", ".join(sorted({str(run.mode) for run in runs}))
    loads = [run.start_load for run in runs if run.start_load is not None]
    load = f"; start load {describe_loads(loads)}" if loads else ""
    return f"{name}: {len(runs)} run(s) of {described}; modes {modes}{load}"


def compare(baseline_path, candidate_path, allow_mismatch):
    baseline = load_side(baseline_path)
    candidate = load_side(candidate_path)
    differences, pairs = mismatches(baseline, candidate)
    lines = []
    if differences:
        heading = ("Compared despite differences (--allow-mismatch):" if allow_mismatch
                   else "Refusing to compare: the runs are not comparable.")
        lines.append(heading)
        lines += [f"  {difference}" for difference in differences]
        if not allow_mismatch:
            lines.append("Pass --allow-mismatch to compare anyway.")
            return 1, lines
        lines.append("")
    lines.append(side_header("Baseline", baseline))
    lines.append(side_header("Candidate", candidate))
    lines.append("")
    baseline_modes = group_by_mode(baseline)
    candidate_modes = group_by_mode(candidate)
    for baseline_mode, candidate_mode in pairs:
        title = baseline_mode if baseline_mode == candidate_mode else f"{baseline_mode} vs {candidate_mode}"
        compare_mode(lines, baseline_modes[baseline_mode], candidate_modes[candidate_mode], title)
    return 0, lines


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare two sets of Stagehand benchmark results from scripts/run-benchmark.sh. "
                    "Each argument is one result directory or a directory holding several (repeats).")
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--allow-mismatch", action="store_true",
                        help="compare even when mode, logging, environment or settings differ")
    arguments = parser.parse_args(argv)
    try:
        status, lines = compare(arguments.baseline, arguments.candidate, arguments.allow_mismatch)
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("\n".join(lines), file=sys.stderr if status else sys.stdout)
    return status


if __name__ == "__main__":
    sys.exit(main())
