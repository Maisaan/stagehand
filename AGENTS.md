# Fixing bugs

Fix the cause, not the symptom. Before editing, trace the failure to the mechanism from evidence (the diagnostic log, the unified log, a failing test) and state it in one sentence: what macOS or Stagehand did, and why Stagehand's assumption was wrong. Do not hide a failure with longer timeouts, extra retries, a narrower special case, or by catching and ignoring it, unless the cause is outside Stagehand and that is written down. Then check every other path that relies on the same assumption, and fix or rule out each one.

# No flip-flopping

Do not undo or reverse an earlier decision without new evidence. Before changing timing, ordering, retries, focus confirmation, parking, or motion, read `git log -p` for that code and any notes in docs/ about it. If the change brings back an approach that was tried and reverted, name that commit and say what is different now. If the only reason is that it feels better, or that a reviewer suggested it, keep the current behavior and raise the question instead. Each commit that reverses an earlier one says why in its message.

# Cleanup verification

For cleanup or refactoring that touches focus, window ordering, parking, gestures, input, overlays, or app lifecycle:

1. Before editing, name the observable behavior that must stay the same. Pick the relevant checks from [live acceptance](docs/ACCEPTANCE.md), and run them on the current build as a baseline. Keep Diagnostic logging enabled and record the start time.
2. Keep mechanical cleanup separate from changes to timing, callbacks, ordering, retries, or failure handling. Give behavior changes their own commit and verification.
3. After editing, run `swift test`, build the app, and repeat the same live checks with the same apps and settings. Inspect the diagnostic log for unexpected pauses, layout failures, rejected focus, and slower focus confirmation. Use the relevant `--diagnose-*` command when it covers the path.
4. Record the baseline, after-change result, and commands in the commit message or handoff. A synthetic test alone does not verify macOS Accessibility behavior. If the live check cannot be run, say so and leave the cleanup uncommitted until it is checked, unless the user explicitly directs otherwise.

The short focus and navigation procedure is at the top of [live acceptance](docs/ACCEPTANCE.md).

# Performance work

Measure before and after with `scripts/run-benchmark.sh` (busy probes show most real slowness) and check real usage with `scripts/analyze-log.py`. The tools, metrics, how Stagehand spends time, and known traps are in [performance and debugging](docs/PERFORMANCE.md).

