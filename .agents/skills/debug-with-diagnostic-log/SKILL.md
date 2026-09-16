---
name: debug-with-diagnostic-log
description: Debug Stagehand runtime failures, regressions, hangs, and incorrect focus, window, layout, navigation, or gesture behavior using its diagnostic log. Use whenever investigating broken or unexpected Stagehand behavior.
---

# Debug with the diagnostic log

Inspect `~/Library/Logs/Stagehand/stagehand.log` early in runtime debugging. It is JSONL, retains 24 hours, and records only while the user has enabled **Diagnostic logging** in Setup. Ask for a focused reproduction when the relevant events are missing.

Correlate the event sequence with the reported behavior and the code that emits each event. Prefer evidence in the log over guesses, while accounting for actions that happened before logging was enabled or outside the retention window.

It is fine to improve permanent diagnostic logging when the current events cannot distinguish plausible causes. Keep those changes narrow:

- Check nearby events first and do not repeat data already available in the same sequence.
- Record decision points, state transitions, failures, and outcomes that change the diagnosis. Do not log every frame, poll, retry, or successful low-level operation.
- Add only fields needed to distinguish the remaining causes. Keep values structured and stable so the JSONL remains searchable.
- Preserve the existing enabled checks and lazy detail construction. Diagnostic logging must not add work when disabled or materially affect timing when enabled.
- Never log window titles, keyboard input, secrets, or unrelated user data.

After changing diagnostics, run the focused tests and confirm the new evidence answers a concrete debugging question. Do not leave speculative or duplicate logging behind.
