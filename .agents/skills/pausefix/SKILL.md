---
name: pausefix
description: Investigate a Stagehand automatic pause, reproduce its cause, fix it, verify, and commit. Use when invoked as $pausefix or when the user explicitly asks to debug, fix, and commit a pause. Add "launch" to install and open the fixed app. A request only to check logs stays read-only.
---

# Fix a Stagehand pause

Work from the Stagehand repository. Follow `AGENTS.md`, [the diagnostic log skill](../debug-with-diagnostic-log/SKILL.md), and the relevant checks in `docs/ACCEPTANCE.md`. `$pausefix` requests a supported fix and commit. `$pausefix launch` also authorizes building, replacing `/Applications/Stagehand.app`, and launching the fixed app. Without `launch`, leave installation separate. Neither form authorizes changing Accessibility permission on the user's behalf.

## Identify the failure

- Inspect `~/Library/Logs/Stagehand/stagehand.log` early. Find the latest relevant `automatic_pause`, its preceding operation and failure event, and any resume or repeat. Record UTC timestamps, reason, window ID, app bundle ID, and what the system actually observed. Distinguish a new cause from earlier pauses.
- Confirm which executable is running and whether it contains the proposed fix. The built bundle in `dist/` is not the installed app in `/Applications/`. Check paths and build identity before treating later logs as verification of a commit.
- Inspect the relevant Git history and existing tests for the failing path. Identify why earlier focus, parking, availability, or timing rules were added before changing them.
- Extract only relevant JSONL fields. Do not dump window titles, keyboard input, secrets, or full process command lines into tool output or the handoff.

## Reproduce before changing behavior

- Name the observable failure and the invariant it violates. Establish a feedback loop that can go red on that failure, using the same affected app, action, display, and settings when possible. State what evidence supports the proposed cause and what observation would disprove it. A test that merely simulates a plausible cause does not establish that it caused the logged pause.
- Before a `--diagnose-*` command that moves or focuses real windows, pause the normal Stagehand instance and confirm it stopped managing windows. Do not run a second controller concurrently. Record the baseline start time and use the applicable live acceptance checks.
- Trace the event to the code that emitted it. Test competing explanations against observed state, including Accessibility refusal, delayed reads, clamping, unavailable or minimized windows, and Desktop changes as relevant. Distinguish the intended workspace state, Accessibility observations, and WindowServer presentation when they disagree. Preserve safe pause and restoration when focus or parking truly fails.
- If the log and available reproduction cannot distinguish the cause, ask for a focused reproduction or add only diagnostic evidence at the decision boundary that resolves the ambiguity. Do not commit a speculative behavior fix and call the incident resolved.

## Fix and verify

- Fix the violated invariant at the layer that owns it. Make the smallest complete change, even when that crosses modules; do not add a caller-level retry or longer timeout without evidence that delayed convergence is the cause. Keep behavior changes separate from mechanical cleanup.
- Add a regression test only when it exercises the actual failure pattern at a meaningful boundary. Show that the original failure goes red before the fix and green after it. Also protect the dangerous opposite outcome: a real focus or parking failure must still pause, restore windows, and withhold input. Choose relevant neighboring cases such as cancellation, minimized or closed windows, Desktop changes, reverse navigation, and shared windows; see [purposeful testing](../purposeful-testing/SKILL.md).
- Run the focused test, `swift test`, and `./scripts/build-app.sh`. When the rebuilt app has Accessibility permission, repeat the relevant live check with the same apps and settings. Inspect events since its UTC start for pauses, layout failures, rejected focus, and slower focus confirmation.
- If the rebuilt bundle lacks Accessibility permission, state that live behavior remains unverified. Follow the stricter live verification rule in `AGENTS.md` for cleanup or refactoring.
- Preserve unrelated worktree changes. Stage only files from this fix. The commit message should state the logged failure, supported cause, red and green evidence, commands, and live verification status. If the cause remains unresolved, report the missing evidence instead of making a fix commit.

## When `launch` is requested

- After a supported fix passes tests and builds, quit the running Stagehand through its normal Quit path so `applicationWillTerminate` can restore managed windows. Confirm it exited and the windows returned before replacing the bundle. Do not force-kill it or run two managing instances.
- Install the newly built `dist/Stagehand.app` at `/Applications/Stagehand.app`, verify the installed signature and executable match the build, then launch that installed app. If replacement fails, preserve or restore the prior installed app and report the error.
- Check the launched app's Accessibility status. A changed ad-hoc signature may require the user to grant permission again; guide that step and continue live verification after the grant. Do not claim the fix is live until the installed process is running the new build and the affected check passes.

Finish with the cause, change, test result, commit hash, and whether the installed app is running that commit. Label the outcome **verified on the installed app**, **candidate fix awaiting live verification**, or **cause unresolved**. Mention distinct later pauses separately.
