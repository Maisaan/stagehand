# Cleanup verification

For cleanup or refactoring that touches focus, window ordering, parking, gestures, input, overlays, or app lifecycle:

1. Before editing, name the observable behavior that must stay the same. Pick the relevant checks from [live acceptance](docs/ACCEPTANCE.md), and run them on the current build as a baseline. Keep Diagnostic logging enabled and record the start time.
2. Keep mechanical cleanup separate from changes to timing, callbacks, ordering, retries, or failure handling. Give behavior changes their own commit and verification.
3. After editing, run `swift test`, build the app, and repeat the same live checks with the same apps and settings. Inspect the diagnostic log for unexpected pauses, layout failures, rejected focus, and slower focus confirmation. Use the relevant `--diagnose-*` command when it covers the path.
4. Record the baseline, after-change result, and commands in the commit message or handoff. A synthetic test alone does not verify macOS Accessibility behavior. If the live check cannot be run, say so and leave the cleanup uncommitted until it is checked, unless the user explicitly directs otherwise.

The short focus and navigation procedure is at the top of [live acceptance](docs/ACCEPTANCE.md).
