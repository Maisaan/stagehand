---
name: fix-stagehand-pause
description: Investigate a Stagehand automatic pause, reproduce its cause, fix it, verify, and commit. Use when invoked as $fix-stagehand-pause or when the user explicitly asks to debug, fix, and commit a pause. A request only to check logs stays read-only.
---

# Fix a Stagehand pause

Work from the Stagehand repository. Follow `AGENTS.md`, [the diagnostic log skill](../debug-with-diagnostic-log/SKILL.md), and the relevant checks in `docs/ACCEPTANCE.md`. Invocation requests a supported fix and commit. It does not authorize replacing the installed app or changing Accessibility permission; leave installation separate unless the user asks for it.

## Identify the failure

- Inspect `~/Library/Logs/Stagehand/stagehand.log` early. Find the latest relevant `automatic_pause`, its preceding operation and failure event, and any resume or repeat. Record UTC timestamps, reason, window ID, app bundle ID, and what the system actually observed. Distinguish a new cause from earlier pauses.
- Confirm which executable is running and whether it contains the proposed fix. The built bundle in `dist/` is not the installed app in `/Applications/`. Check paths and build identity before treating later logs as verification of a commit.
- Extract only relevant JSONL fields. Do not dump window titles, keyboard input, secrets, or full process command lines into tool output or the handoff.

## Reproduce before changing behavior

- Name the observable failure and establish a feedback loop that can go red on that failure. Use the same affected app, action, display, and settings when possible. A test that merely simulates a plausible cause does not establish that it caused the logged pause.
- Before a `--diagnose-*` command that moves or focuses real windows, pause the normal Stagehand instance and confirm it stopped managing windows. Do not run a second controller concurrently. Record the baseline start time and use the applicable live acceptance checks.
- Trace the event to the code that emitted it. Test competing explanations against observed state, including Accessibility refusal, delayed reads, clamping, unavailable or minimized windows, and Desktop changes as relevant. Preserve safe pause and restoration when focus or parking truly fails.
- If the log and available reproduction cannot distinguish the cause, ask for a focused reproduction or add only diagnostic evidence that resolves the ambiguity. Do not commit a speculative behavior fix and call the incident resolved.

## Fix and verify

- Make the smallest change at the responsible seam. Keep behavior changes separate from mechanical cleanup. Add a regression test only when it exercises the failure pattern at a meaningful boundary; see [purposeful testing](../purposeful-testing/SKILL.md).
- Run the focused test, `swift test`, and `./scripts/build-app.sh`. When the rebuilt app has Accessibility permission, repeat the relevant live check with the same apps and settings. Inspect events since its UTC start for pauses, layout failures, rejected focus, and slower focus confirmation.
- If the rebuilt bundle lacks Accessibility permission, state that live behavior remains unverified. Build and commit without replacing `/Applications/Stagehand.app`; do not describe the installed app as fixed. Follow the stricter live verification rule in `AGENTS.md` for cleanup or refactoring.
- Preserve unrelated worktree changes. Stage only files from this fix. The commit message should state the logged failure, supported cause, red and green evidence, commands, and live verification status. If the cause remains unresolved, report the missing evidence instead of making a fix commit.

Finish with the cause, change, test result, commit hash, and whether the installed app is running that commit. Mention distinct later pauses separately.
