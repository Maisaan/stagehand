# Performance and debugging

How to measure Stagehand, find where time goes, and check a change. Live checks need the built app's Accessibility grant and an unlocked screen; see [live acceptance](ACCEPTANCE.md) for correctness.

## Tools

| Tool | Use |
|---|---|
| `scripts/run-benchmark.sh` | Live benchmark against disposable probe windows. Quit Stagehand first. Saves every run. |
| `scripts/compare-benchmarks.py` | Compares two sets of saved benchmark results; refuses runs that are not comparable. |
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
- `busy-quiet`: busy with diagnostic logging off, to measure what logging costs. Motion and focus are measured the same way as with logging on, and the `from queued` delays, motion writes and `stalls by change step` come from each change's trace, which is filled either way; only `stalls by phase` needs the log's events.
- `busy-tiles` (or `responsive-tiles`): arranges two probe windows side by side in one tile (the ⌃⌥ S path) before the switches, then sets every tile to 0.75 of the screen width so each switch between tiles scrolls whatever the gap and screen (three 640-point probe tiles fit an 1800-point screen at a -140 gap, and nothing slid). The run fails if two neighbouring tiles would share a ribbon offset. Switches cross a multi-pane tile (one synchronous frame write per pane as it comes into view); a sequential switch between the tile's two panes doesn't slide. It adds a **Pane switches in the tile** section, saved as the `panes` phase in `raw.json`. It replaces `busy-columns` (stacked columns, phase `members`); the comparison reads old `members` results as a different phase. Not related to `-stacking`, which measures window order.
- a `-gestures` suffix (`busy-gestures`, `busy-quiet-gestures`): after the rapid switches, replays swipes through the model's gesture handler on fixed displacement schedules, four rounds of: a `flick` (56 ms, released fast: commits), a `slowDrag` (600 ms, released slowly: commits on distance) and a `reversal` (out and back over 400 ms, released moving back: restores). Stimuli are 8 ms apart, like trackpad frames. This is **model-path coverage**: the production follow and settle run, but the trackpad driver, the recognizer and delivery to main do not. Each stimulus carries an `InputArrival` stamped at its planned time, so input-to-main is the replay's own lag. Saved as the `gestures` phase (`coverage: "modelPath"`); a run whose gesture did not end as its schedule should fails.

Set `STAGEHAND_APP` to benchmark another build. To compare against an older commit, check it out in a separate worktree (`git worktree add /tmp/sh-base <commit>`), copy in the current `StagehandModel+Benchmark.swift`, `StagehandModel+Acceptance.swift`, and `AppDelegate.swift` if they changed, build it, and run both builds back to back with the current runner. Run each at least twice: single runs vary by 10 to 30 percent, and one-off stalls happen.

#### Saved results

Every run is saved, pass or fail, to `$BENCHMARK_RESULTS_DIR` (default `~/Library/Application Support/Stagehand/Benchmarks`, not under `~/Library/Logs`, which cleaners such as Mole delete) as `<UTC start>-<sha7>[-dirty]-<mode>[-r<N>]/`:

- `report.txt`: the text report, also printed.
- `raw.json`: the app's raw samples, the only input to comparison. Its `build` block is the running binary's own version, build number and executable modification time.
- `meta.json`: written by the runner: git SHA, branch and dirty flag of the checkout that holds the app (the runner's own checkout when the app lives elsewhere, such as `/Applications`; `git.holdsApp` tells which), the app's path, bundle version, build number and executable modification time, macOS version and hardware model, mode, flags, whether logging was on, 1- and 5-minute load average at start, start and end time, and the run's outcome (`pass`, `fail`, `timeout`) with its reasons.
- `diagnostic.log`: the run's own diagnostic log (`--diagnostic-log`), so probe runs stay out of `stagehand.log`.

`BENCHMARK_REPEAT=N` runs each mode N times in a row (the `-r<N>` suffix), 3 by default. Single runs vary by 10 to 30 percent, so judge a change by the median of the repeats and treat anything inside the baseline's spread as noise. Use `BENCHMARK_REPEAT=1` only for a quick smoke check, never for a before/after comparison. `BENCHMARK_TIMEOUT` caps each run (default 240 s). The runner exits non-zero when any run timed out, has a report line starting with `FAIL`, or does not end with exactly `Result: PASS`; it runs the remaining modes first.

#### Comparing

Put each batch in its own folder and compare the two folders, or two single result directories:

```sh
BENCHMARK_RESULTS_DIR=~/Library/Application\ Support/Stagehand/Benchmarks/base BENCHMARK_MODES=busy \
    STAGEHAND_APP=/tmp/sh-base/dist/Stagehand.app scripts/run-benchmark.sh
BENCHMARK_RESULTS_DIR=~/Library/Application\ Support/Stagehand/Benchmarks/change BENCHMARK_MODES=busy \
    scripts/run-benchmark.sh
python3 -I scripts/compare-benchmarks.py ~/Library/Application\ Support/Stagehand/Benchmarks/base ~/Library/Application\ Support/Stagehand/Benchmarks/change
```

Metrics added after older results were saved (the `from queued` delays, motion write counts, and each phase's resource cost and the `idle` phase) are shown only when both sides have them. Wakeups are per second (`/s`); unavailable resource samples are listed, not counted as zero. It reads only `raw.json` and `meta.json`, groups runs by mode, and prints p50, p90 and max per metric for baseline and candidate, with the spread across repeats when a side has two or more. A change that lands inside the baseline's repeat spread is marked **within noise**; with one baseline run, noise is unknown. Failed runs, missing phases, missing keys and missing samples are listed and left out of the numbers, never counted as zero; null focus times count as unconfirmed focus.

Builds are identified by the bundle (`raw.json`'s `build`, else `meta.json`'s `app`), not the runner's checkout. It refuses (exit 1) when mode, logging, the `environment` block (display, scale, frame rates, Reduce Motion) or the `settings` block (gap, widths, probe settings) differ, or when one side mixes builds. `--allow-mismatch` compares anyway and lists the differences at the top.

Results from before stage 1 of the benchmark work (no `raw.json`, report text only) are not comparable: the comparison treats them as failed runs. Build both sides with the stage-1 benchmark code, as above.

What it reports, and what each line means:

- **slid on N of M switches**: switches that started ribbon motion. A switch between windows that are all on screen doesn't slide, so the motion lines cover only N switches.
- **to motion scheduled**: action to the moment the slide is scheduled (`ribbon_animation_started`), before its first frame is written. It doesn't prove a window moved on screen.
- **from queued** (from the switch's change trace, logged or not): `wait` until the change started, the destination's **first acknowledged write** (the first motion write its app answered with success: the earliest sign the slide reached that app, not pixels on screen) and **motion ended**. Saved per switch as `queueWaitMs`, `firstAcknowledgedWriteMs`, `motionEndedMs`, with `changeOutcome`. Null when the switch did not slide or no write was acknowledged.
- **motion writes**: how the apps answered the slide's writes: acknowledged, unacknowledged (timed out; the app may still apply them) and failed. Saved as `motionWritesAcknowledged`, `motionWritesUnacknowledged`, `motionWritesFailed`.
- **to focus confirmed / settled**: when typing can go to the destination, and when everything stopped. `rejected` counts focus that Stagehand could not confirm, and `no attempt` counts switches that never tried. `timed out` counts idle waits that hit 8 s; their settled time is the timeout, not a measurement.
- **longest freeze of the destination window mid-motion**: the longest the window being watched went without moving. Over about 33 ms is visible stutter. Frame work alone does not show this.
- **frame work per tick, dropped frames**: Stagehand's own main-thread cost per display tick.
- **main thread**: a background thread posts to the main queue every 4 ms. The keyboard tap, gestures, and ribbon frames run there, so a blocked main thread delays typing in every app. `stalls by phase` names the last diagnostic event before each stall (since 2026-11-13 that can be `change_ended`); events logged only with logging on are missing from it in `busy-quiet`. `stalls by change step` names the last step of the change running then from its trace (`queued`, `started`, `motionScheduled`, `motionEnded`, `focusRequested`, `focusConfirmed`, `heldInputPosted`), the same with logging off; saved as each stall's `changeStep`, null between changes. Each stall (start and rapid too) also saves `mainThreadCPUMs` (the main thread's own CPU during the wait, read with `thread_info` as the watchdog does), `loadAverage` and `kind`, split as analyze-log.py splits logged stalls: `computing` (CPU at least half the wait), `starved` (CPU under a tenth of it at a 1-minute load of at least the CPU count: waiting for a CPU, so the run says more about the machine than the build), else `waiting` (most likely on another app's reply); null without CPU. The thresholds are saved as `stallKindThresholds`. `stalls by kind` and `stalls by call` summarize them; the comparison counts each kind per run.
- **Gestures** (`-gestures` only), per scenario: how many ended as expected and the largest stimulus lag (actual minus planned delivery); the follow's touch-to-start, touch-to-first-acknowledged-write, longest callback gap and dropped ticks (from the same summary as `gesture_follow_ended`, logged or not); and from the release, as for a switch: motion scheduled, focus confirmed (commits), settled and the destination's longest freeze. Each gesture saves `plannedStimulusMs` and `actualStimulusMs`, `outcome` (`commit`, `restore`, `interrupted` when a change that was not the swipe's own cut its follow, or `none`), `outcomeMatches`, its `changeID`, a `follow` block and a `release` block shaped like a switch. The comparison shows each scenario's lines separately and refuses to compare a gesture run with one without (`settings.gestures`; older results count as false).
- **Space switches**, **Rapid switches**, **Start**, **Window scan**, **Settings / quick controls / app bar** open times.
- **cost** (each phase): the whole process's CPU time and wakeups over the phase, read with `proc_pid_rusage` at its start and end, logged or not; saved as each phase's `resourceCost` (`durationMs`, `cpuMs`, `cpuPercent`, `idleWakeups`, `interruptWakeups` and their per-second rates). It includes the benchmark's own 4 ms latency monitor and inter-switch pauses, so compare it between builds, not as Stagehand's absolute cost. A read that failed is `available: false` with null counts, never zero.
- **Idle**: 10 s with nothing driven and the latency monitor stopped, 2 s after the interface phase so the app bar has hidden: Stagehand's own idle CPU and wakeups (with logging on, the watchdog's and resource sampler's too). Saved as the `idle` phase; compare `busy` with `busy-quiet` to see what logging costs at rest.
- **Pause and restore frames**: the restore runs inside the call, so its duration is the main-thread stall.
- **Result**: the last line is `Result: PASS`, or `Result: FAIL:` followed by every failure: a timed-out wait, rejected or missing focus, final focus not matching the ribbon, or a failed setup. A failed run's numbers aren't comparable. `--raw-output <path>` also writes every sample as JSON.

Benchmark numbers from before 2026-11-12 (stage 1 of the measurement fixes) aren't comparable with later ones. Earlier runs could count one phase's main-thread samples twice after a quick stop and start, reported a timed-out wait as settled, counted rejected focus as confirmed, and in `busy-quiet` measured no motion or focus at all.

### Analyzing real usage

```sh
python3 -I scripts/analyze-log.py --since 2026-10-15T12:00
python3 -I scripts/analyze-log.py --split <install time, UTC>   # before/after an install
```

It reads `stagehand.1.log` and `stagehand.log` and skips acceptance and benchmark runs (`diagnostic_run_began` to `diagnostic_run_ended`, per session). The benchmark runner gives each run its own log, but acceptance and older builds without `--diagnostic-log` write into `stagehand.log` and can rotate it, so note install and run times.

It pairs every change by (session, changeID) over the whole log first, then applies `--since`, `--until` or `--split`, so a range boundary never mispairs a change: one that straddles it is counted as cut, not timed. Durations use `uptimeMs`. Besides the latencies it reports:

- **change traces**: orphan events (a change ID with no `change_queued` in its session), duplicate terminal events, changes cut by the time range, and changes with no terminal event (the log ended, or the session went on, which is a bug).
- **changes by origin and operation**: queue wait (queued to started), processing (started to terminal) and outcome counts, for `command`, `gesture` and `system` changes.
- **stalls by kind**: `computing`, `waiting`, and `starved`: main-thread CPU under a tenth of the wait at a 1-minute load of at least `--high-load` (default: the CPU count), so the thread was waiting for a CPU, not for another app.

Logs written before 2026-11-13 have no session: the analyzer splits them at each `session_started`, where change IDs restart, or at a 30-minute gap, and labels the navigation section approximate. Logs before 2026-11-12 also lack change IDs and pair by queue order.

### Events worth knowing

- Every event has `session` (8 hex characters, one per launch; change and gesture IDs restart in each) and `uptimeMs` (system uptime: monotonic, paused while the Mac sleeps). Time durations with `uptimeMs`; `timestamp` is wall time and can step. `session_started` carries `buildVersion`, `buildNumber`, `executableModified`, `pid` and `bootTime`.
- A change's life: `change_queued` (`changeID`, `operation`, `origin`: `command`, `gesture` with its `gestureID`, or `system`), `change_started`, then exactly one terminal: `change_completed`, or `change_ended` with `outcome` and `reason`:
  - `noEffect` (the state did not change), `merged` (a navigation step without typing folded into the next; `successorChangeID`), `superseded` (its slide was cut short by the next change; `successorChangeID`, and the cost fields of `change_completed`), `refused` (a tile that did not fit), `skipped` (the focus a preferences layout depends on moved);
  - `failed` (logged before the pause it causes; `focus_target_unavailable` when the destination vanished, which may not pause), `interrupted` (it was running when a pause, sleep or Desktop change cancelled the queue; the reason names which), `cancelled` (still queued then).
  `navigation_motion_planned`, `ribbon_animation_started`/`_completed` and `navigation_focus_confirmed` carry the `changeID` of the change they belong to. Gesture events and the `gesture.preview.restore` animation carry the gesture's `gestureID`.
- The terminal event of every change carries its felt-delay trace: stamps in ms on the `uptimeMs` clock, filled with logging on or off (the benchmark reads the same trace). A missing stamp means the step did not happen.
  - Input: `inputSource` is `keyboardTap`, `trackpad` or `hotKeyCallback` (a Carbon shortcut: its handler time stands in, as it has no event time). `inputEventUptimeMs` is the event's own time (a key event's timestamp through `eventUptime`, or the trackpad frame's; absent when it does not read as uptime), `inputReceivedUptimeMs` when Stagehand's callback saw it (tap or trackpad thread), `inputDeliveredUptimeMs` when main ran the handler, and `touchesLandedUptimeMs` when the swipe's fingers first touched. Clicks, menus and Stagehand's own changes have no input stamps.
  - Change: `queuedUptimeMs`, `startedUptimeMs`, `motionScheduledUptimeMs`, `firstAcknowledgedWriteUptimeMs` (the destination window's first motion write its app answered with success: an acknowledgement, not pixels on screen), `motionEndedUptimeMs`, with `motionWritesAcknowledged`, `motionWritesUnacknowledged` (timed out: the app may still apply them) and `motionWritesFailed`; `focusRequestedUptimeMs`, `focusConfirmedUptimeMs`.
  - Typing held for the switch: `heldInputEvents`, `heldInputTransferAgeMs`, `oldestHeldInputAgeMs`, and `heldInputPostedUptimeMs` (replay posted to the process, not received). Never key contents.

- `main_thread_stall`: the main thread was blocked for 50 ms or more. `lastEvent` names the phase. `activity` names the call that was running, sampled every 10 ms during the wait: the outermost `MainThreadActivity` label and the innermost two, e.g. `layout frame write > frame write readback > read AXPosition,AXSize pid=644`. Labels cover main-thread Accessibility calls (`read …`, `write …`), the AX callback (`axCallback <notification>`, with `identify window`, `title change consumer` and `frame change consumer` inside it), the window list, the start scan, the resume refresh, `navigation overlay show`, the log's `log write`, `log rotate` and `log prune swap`, frame writes (`frame read before write`, `frame write readback`) and the layout's own reads and writes (`layout current frame read`, `layout frame write`, `layout refused write readback`, `layout readback after focus`, `layout readback after motion`, `layout slide start read`, `layout preferred height read`, `layout border frame read`). `unlabeled` is anything else, such as AppKit or a loaded machine. Labels are built only while activity tracking is on. `mainThreadCPUMilliseconds` is the main thread's own CPU during the wait: close to `waitedMilliseconds` means Stagehand was computing, near zero means it was waiting on another app or, with a high `loadAverage`, for a CPU. analyze-log.py splits stalls into computing and waiting. Logged only while diagnostic logging is on.
- `resource_sample`: once a minute while logging is on: `footprintMegabytes`, `cpuPercent`, `idleWakeupsPerSecond`, `interruptWakeupsPerSecond`, `threads` since the previous sample. Compare builds with `--split` for lightness.
- `restore_deferred` (a pause or quit could not put windows back: `windowsReachable` false means the user was on another Space or the lock screen), `recovery_retry` (`trigger`, `pendingBefore`, `pendingAfter`) and `recovery_completed_start`: recovery waiting for the user's return.
- `launch_window_order`, 2 s after an automatic start: the three frontmost windows and `focusedIsFrontmost`, read off the main thread.
- `launch_timing` (`launchFinishedMilliseconds`, `modelInitMilliseconds`, `startMilliseconds`) and `desktop_resume_refreshed` (`milliseconds` of the refresh after returning to the Desktop).
- `ribbon_animation_completed`: `focusedMotionGapMilliseconds` and `largestMotionGapMilliseconds` (visible freezes), `slowestMotionWriteMilliseconds`, `motionPositionsRequested`, `motionWritesSent`, and how apps answered the sent writes: `motionWritesAcknowledged`, `motionWritesUnacknowledged` (timed out), `motionWritesFailed`.
- `navigation_focus_confirmed`: `focusReport.elapsedMilliseconds` and the AX operations of the focus attempt.
- `screen_locked`, `screen_unlocked`, `desktop_suspended`, `desktop_resumed`: unlock-to-resume latency. A short lock may not suspend at all.
- `gesture_follow_ended`: one summary per live swipe follow, apart from the settle that ends it (no per-frame events). `gestureID`, `durationMilliseconds`, `ticks`, `droppedTicks` (ticks the display link skipped at the cadence it reported for each tick, `unknown` when it reported none), `largestTickGapMilliseconds` (between the link's target times) and `largestCallbackGapMilliseconds` (between callback entries), `lateCallbacks` (began after their target time), `followStartedAfterTouchMilliseconds` and `firstAcknowledgedWriteAfterTouchMilliseconds` (from the fingers landing), the follow's own `motionWritesSent`/`Acknowledged`/`Unacknowledged`/`Failed` (writer statistics restart at the follow's start), and `handoff`: `change` (a change started and cut the follow; `handoffChangeID`, the swipe's own change when it navigated), `settle` (an animation replaced it; `settleOperation`, `gesture.preview.restore` for a swipe that went back) or `cancelled`.
- `ribbon_motion_yielded_to_pointer`: a slide stopped because the left button held a window (no `ribbon_animation_completed` follows). `gesture_ignored_for_pointer`: a swipe released during a window drag. Swipe and `navigation_motion_planned` events carry `pointerHeld`, `dragAndDrop`, and `dockControlEventsWithheld` (macOS Space-swipe events withheld beside a held click since gestures started). `drag_and_drop_ended` summarizes each press that carried a drag-and-drop: `pointerDragEvents`, `longestPointerGapMilliseconds` (including the gap before the drop) and `heldFingerTravelDuringGap` (thousandths of the trackpad's width); a long gap with large travel means macOS stopped moving the pointer while the held finger moved. `syntheticPointerEvents` counts the drags Stagehand posted for the held finger while macOS had the touch locked (`pointerDragEvents` and the gap count only macOS's own drags; `syntheticDragsSeen` the posted ones that came back), with `syntheticReanchors` (cursor reads), `syntheticSubPointFrames`, `syntheticLongestFrameGapMilliseconds` and `syntheticSlowestPostMicroseconds`.
- Telling a drag-and-drop from a window drag reads the drag pasteboard's change count (one round trip to the pasteboard server, sub-millisecond) on the main thread at every left mouse-down and mouse-up on the system, and on each check while a held press is not yet a drag-and-drop: during a title-bar drag, about every 100 ms from the refresh poll. Fingers landing beside a finger holding a click on the trackpad ask for one more check, once per landing, until a drop is found; the answer tells swipe recognition to take two fingers beside it.

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
