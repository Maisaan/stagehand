# Performance and debugging

How to measure Stagehand, find where time goes, and check a change. Live checks need the built app's Accessibility grant and an unlocked screen; see [live acceptance](ACCEPTANCE.md) for correctness.

## Tools

| Tool | Use |
|---|---|
| `scripts/run-benchmark.sh` | Live benchmark against disposable probe windows. Quit Stagehand first. |
| `scripts/run-acceptance.sh` | Focus, typing, and space-switching correctness. Run before and after any change to focus, motion, input, or lifecycle. |
| `scripts/analyze-log.py` | Summarizes real usage from the diagnostic log. |
| `scripts/find-dead-code.sh` | Periphery scan for unused code (with and without tests as users); about 30 s, own build directory. |
| `sample <pid> 5`, `footprint <pid>`, `top -pid <pid> -stats pid,cpu,idlew,power,threads` | Where Stagehand's threads are and how heavy it is, read-only. |
| Diagnostic logging (Settings) | Writes `~/Library/Logs/Stagehand/stagehand.log`; keep it on. |
| `/usr/bin/log show --predicate 'subsystem == "app.stagehand.Stagehand"'` | Window-system detail (scans, parking writes, AX notifications). Local time, whole-second `--start`. Plain `log` is a zsh builtin. |

### Benchmark

`BENCHMARK_MODES` picks the runs (default `responsive busy`):

- `responsive`: probes answer Accessibility immediately.
- `busy`: probes load their main thread like Chrome or an Electron app (6 ms per frame, 150 ms on each activation). Most real slowness only shows here.
- `busy-quiet`: busy with diagnostic logging off, to measure what logging costs.

Set `STAGEHAND_APP` to benchmark another build. To compare against an older commit, check it out in a separate worktree (`git worktree add /tmp/sh-base <commit>`), copy in the current `StagehandModel+Benchmark.swift`, `StagehandModel+Acceptance.swift`, `AppDelegate.swift`, and `scripts/run-benchmark.sh` if they changed, build it, and run both builds back to back. Run each at least twice: single runs vary by 10 to 30 percent, and one-off stalls happen.

What it reports, and what each line means:

- **to first motion**: action to the first ribbon frame. What makes a switch feel immediate.
- **to focus confirmed / settled**: when typing can go to the destination, and when everything stopped.
- **longest freeze of the destination window mid-motion**: the longest the window being watched went without moving. Over about 33 ms is visible stutter. Frame work alone does not show this.
- **frame work per tick, dropped frames**: Stagehand's own main-thread cost per display tick.
- **main thread**: a background thread posts to the main queue every 4 ms. The keyboard tap, gestures, and ribbon frames run there, so a blocked main thread delays typing in every app. `stalls by phase` names the last diagnostic event before each stall.
- **Space switches**, **Rapid switches**, **Start**, **Window scan**, **Settings / quick controls / app bar** open times.

### Analyzing real usage

```sh
python3 -I scripts/analyze-log.py --since 2026-10-15T12:00
python3 -I scripts/analyze-log.py --split <install time, UTC>   # before/after an install
```

It reads `stagehand.1.log` and `stagehand.log` and skips acceptance and benchmark runs (`diagnostic_run_began` to `diagnostic_run_ended`). Benchmark runs write a lot and rotate the log, so note install and run times.

### Events worth knowing

- `main_thread_stall`: the main thread was blocked for 50 ms or more. `lastEvent` names the phase. `activity` names the call that was running, sampled every 10 ms during the wait (`MainThreadActivity` labels around main-thread Accessibility calls, the AX callback, and the window list; `unlabeled` is anything else, such as AppKit or a loaded machine). `mainThreadCPUMilliseconds` is the main thread's own CPU during the wait: close to `waitedMilliseconds` means Stagehand was computing, near zero means it was waiting on another app or, with a high `loadAverage`, for a CPU. analyze-log.py splits stalls into computing and waiting. Logged only while diagnostic logging is on.
- `resource_sample`: once a minute while logging is on: `footprintMegabytes`, `cpuPercent`, `idleWakeupsPerSecond`, `interruptWakeupsPerSecond`, `threads` since the previous sample. Compare builds with `--split` for lightness.
- `restore_deferred` (a pause or quit could not put windows back: `windowsReachable` false means the user was on another Space or the lock screen), `recovery_retry` (`trigger`, `pendingBefore`, `pendingAfter`) and `recovery_completed_start`: recovery waiting for the user's return.
- `launch_window_order`, 2 s after an automatic start: the three frontmost windows and `focusedIsFrontmost`, read off the main thread.
- `launch_timing` (`launchFinishedMilliseconds`, `modelInitMilliseconds`, `startMilliseconds`) and `desktop_resume_refreshed` (`milliseconds` of the refresh after returning to the Desktop).
- `ribbon_animation_completed`: `focusedMotionGapMilliseconds` and `largestMotionGapMilliseconds` (visible freezes), `slowestMotionWriteMilliseconds`, `motionPositionsRequested`, `motionWritesSent`.
- `navigation_focus_confirmed`: `focusReport.elapsedMilliseconds` and the AX operations of the focus attempt.
- `screen_locked`, `screen_unlocked`, `desktop_suspended`, `desktop_resumed`: unlock-to-resume latency. A short lock may not suspend at all.
- `ribbon_motion_yielded_to_pointer`: a slide stopped because the left button held a window (no `ribbon_animation_completed` follows). `gesture_ignored_for_pointer`: a swipe released during a window drag. Swipe and `navigation_motion_planned` events carry `pointerHeld`, `dragAndDrop`, and `dockControlEventsWithheld` (macOS Space-swipe events withheld beside a held click since gestures started). `drag_and_drop_ended` summarizes each press that carried a drag-and-drop: `pointerDragEvents`, `longestPointerGapMilliseconds` (including the gap before the drop) and `heldFingerTravelDuringGap` (thousandths of the trackpad's width); a long gap with large travel means macOS stopped moving the pointer while the held finger moved. `syntheticPointerEvents` counts the drags Stagehand posted for the held finger while macOS had the touch locked (`pointerDragEvents` and the gap count only macOS's own drags; `syntheticDragsSeen` the posted ones that came back), with `syntheticReanchors` (cursor reads), `syntheticSubPointFrames`, `syntheticLongestFrameGapMilliseconds` and `syntheticSlowestPostMicroseconds`.
- Telling a drag-and-drop from a window drag reads the drag pasteboard's change count (one round trip to the pasteboard server, sub-millisecond) on the main thread at every left mouse-down and mouse-up on the system, and on each check while a held press is not yet a drag-and-drop: during a title-bar drag, about every 100 ms from the refresh poll.

## How Stagehand spends time

- Every Accessibility call to another app is a synchronous message answered on that app's main run loop. A busy app answers late; the global AX timeout is 100 ms. Never make such a call on the main thread when it can be avoided, and never during an app's activation.
- An app that has just been activated is at its busiest. Reading from it, or moving its windows, right then is what stalls. Navigation therefore slides first and requests focus as the motion ends; starting both together made the destination window freeze mid-slide.
- Ribbon motion writes run on one serial queue per app (`MotionPositionWriter`), newest position only. Any synchronous frame write to that app first drains its queue.
- Each motion write echoes back as an `AXMoved` notification. The callback must check whether anyone wants the frame (`wantsFrameChange`) before identifying the window or reading its frame.
- Observed focus (`reportCurrentFocus`) is read off the main thread and skipped while Stagehand runs its own change (`wantsObservedFocus`).
- With diagnostic logging on, each navigation makes several synchronous focus reads for the log: about 7 ms per switch with busy apps.

## Traps

- **Probe windows did not appear**: the screen is locked. Check `ioreg -n Root -d1 -a | grep CGSSessionScreenIsLocked`.
- **`sample` works on the signed build** (checked 2026-10-26; it used to show an empty call graph). It only shows where threads are at that moment; for stalls, use `main_thread_stall` activity and the benchmark's stalls by phase.
- **`NSLog` output is missing**: an app launched through LaunchServices does not show it in `log show`. Append to a file under `/tmp` for temporary timing.
- **"Quit Stagehand first" when nothing is running**: `pgrep -f` matched your own shell command, which contained the app path. Build the pattern from pieces.
- **The agent shell has no Accessibility or Automation permission**: it cannot drive other apps. Use the probe-based scripts.
- **Window-list polling stalls the main thread**: polling `CGWindowListCopyWindowInfo` every 4 ms, even from a background thread, froze Stagehand's main thread for ~500 ms at the start of motion in most busy runs. The benchmark's stacking measurement does this, so it runs only in a `-stacking` mode; don't compare latency or stalls from those runs.
- **Known test noise**: `quickControlsPanelTakesFocusWhenPresentedWithoutPopoverChrome` needs a frontmost test host; `relaunchRestoresTheSavedLayoutOfStillRunningWindows` and occasionally `aWindowRestoredFromTheDockJoinsAfterTheFocusedWindow` are timing-flaky in a full run. Rerun alone with `--filter`.
- **Benchmark numbers improve but it feels worse**: check the per-window freeze metric and real usage with the analyzer. A change that lowers Stagehand's own cost can still make a window stutter.
