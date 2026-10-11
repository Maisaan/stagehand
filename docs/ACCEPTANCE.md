# Live acceptance

Use disposable documents or text fields for typing checks, not a shell or a production form. These checks require the built app's Accessibility grant and the physical trackpad. They are not marked as passed by the automated suite.

## Short cleanup check for focus and navigation

`./scripts/run-acceptance.sh` automates steps 2 to 4 against disposable probe windows. Quit Stagehand first, and keep hands off the keyboard and trackpad until it prints PASS or FAIL. It exits 0 only on PASS; an empty report, a FAIL verdict, or a run longer than `STAGEHAND_ACCEPTANCE_TIMEOUT` seconds (default 180, after which it stops Stagehand) exits 1. It tests `STAGEHAND_APP` when set, otherwise `dist/Stagehand.app` from the last `scripts/build-app.sh`, otherwise `/Applications/Stagehand.app`; the chosen build needs its own Accessibility grant. It manages only the probe's windows, makes rapid switches in both directions with reversals, checks where typing lands during and after transitions, pauses, verifies restored frames, and summarizes focus times and any pauses from the log. It does not cover trackpad gestures, Desktop changes, or other apps; run the relevant manual checks below for those.

Run this on the build before and after a cleanup that touches focus, input, gestures, window ordering, parking, overlays, or lifecycle. Use the same apps, display, shortcuts, and signing identity for both runs. Confirm the rebuilt app still has Accessibility permission. Keep Diagnostic logging enabled.

1. Record the UTC start time for each run: `start_utc=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')`.
2. With two apps and two windows from one of them, make 30 rapid switches in both directions. Reverse direction during a transition. Include the navigation methods affected by the change. Type distinct short strings into disposable fields after several switches and check their destinations.
3. Click the focused window, switch to another app and back, and check that the focus border follows the real focused window. Pause Stagehand and check that the original window frames return.
4. Inspect only events since `start_utc` for unexpected pauses, layout failures, and rejected focus:

   ```sh
   jq -r --arg start "$start_utc" '
     select(.timestamp >= $start)
     | select(.event == "automatic_pause" or .event == "layout_failed" or
              (.event == "navigation_focus_confirmed" and .details.focusConfirmed == "false"))
     | [.timestamp, .event, (.details.reason // .details.operation // "")] | @tsv
   ' ~/Library/Logs/Stagehand/stagehand.log
   ```

   Compare focus times from the same run with the baseline. Investigate any new long delay, even if the app did not pause:

   ```sh
   jq -r --arg start "$start_utc" '
     select(.timestamp >= $start and .event == "navigation_focus_confirmed" and .details.focusReport)
     | [.timestamp, .details.operation, (.details.focusReport | fromjson | .elapsedMilliseconds)] | @tsv
   ' ~/Library/Logs/Stagehand/stagehand.log
   ```

Record the app pairs, pass/fail result, and any relevant log timestamps in the commit message or handoff. A blocked app or modal dialog should still cause a safe pause; this check uses ordinary responsive windows.

## Start and stop

- Grant Accessibility to the built Stagehand.app. Leave Input Monitoring disabled.
- Launch after setup with several ordinary windows on one native macOS Desktop; confirm Stagehand starts and arranges them without pressing Start.
- Launch without Accessibility granted; confirm Stagehand stays paused and leaves windows unchanged.
- Pause and Quit independently. Verify every managed window returns to its pre-Start frame. Stagehand must never minimize a window to the Dock.
- Repeatedly pause/start during navigation. No stale operation should move windows after pause.
- Arrange and share windows across several numbered spaces, with different orders and widths. Pause, close one shared window, and resume. Preserve the surviving memberships, orders, and widths; omit the closed window from every space.
- Repeat after an automatic pause caused by failed focus or parking. Resume should use the layout before an interrupted transition. If an app is still busy at resume, verify its windows regain their saved memberships when discovery recovers, including after another pause/resume.
- Cause one automatic pause with a temporarily blocked app. After 100 ms, Stagehand should try to resume once. If the same failure persists, it must stay paused, restore the original frames, and offer Start for a manual retry. Manual Pause and Quit must cancel a pending retry. Switch native Desktops before the retry and verify it does not bind to the new Desktop.
- With disposable windows, force-quit Stagehand while a window is parked and another is in the ribbon. Relaunch it. Both windows should return to their pre-Start frames, and Stagehand should remain paused until Start. Close one window or quit its app before relaunch; recovery must leave unrelated and replacement windows alone. Repeat with Accessibility revoked; no recovery move should occur until permission returns.
- Quit an unrelated app during ribbon motion. Stagehand should cancel the stale motion and reconcile without pausing or sending buffered input to the terminated process.
- Open two same-size windows from one app, close one, and immediately create a replacement at the same frame. The survivor and replacement must keep distinct identities and memberships.
- Change native macOS Desktop. Stagehand should stay enabled but suspend input and layout work, without pulling windows into the new Desktop. Return and verify automatic resume with order and widths preserved.
- Repeat Desktop switching during window navigation. No buffered typing should be replayed on the away Desktop.

## Ribbon sizing and overlap

- Scrolling: active window fits; adjacent sliver remains visible with 95% width.
- Shrink and grow several windows independently; respect app minimum-size constraints.
- Inactive windows use 95% of available height and stay centered. Focus requests 100%. Apps with fixed/minimum/maximum heights stay centered at their actual accepted size.
- Navigate across both ends; there is no wrap.
- Reorder a window and verify focus stays with it.
- Grow a window from the 95% default to 100%, then shrink it and verify its individual width is retained.
- System Settings: the displayed percentage reflects its constrained width; focusing the last window leaves no unused slot to its right.
- Apply a negative gap. Windows overlap horizontally with the active one above its neighbors. A full-width active window covers the available area.
- Drag a title bar, hold it still, then release. Reorder only on release; the window rejoins the ribbon instead of remaining detached.
- Drag-resize a scrolling window, including immediately after navigation. Its new width should be remembered within the allowed range.
- Drag the top edge of a centered half-height window to the top of the available screen. On release, it should fill the available height in one drag.
- Open a new window while Stagehand is running. Its first layout should keep its original width within the allowed range.

## Spaces and shared windows

- Move a window to an empty space without following. The outgoing space remains active.
- Move and follow. The moved window receives focus.
- With two windows from one app in a space, use Command + Control + Option + Up/Down. Only the focused window moves one space and remains focused. Up on space 1 does nothing. Down with only one window in the source space does nothing; repeat after moving from space 1 to 2 and confirm space 1 stays occupied.
- Close every window in space 2 while space 3 remains occupied. Space 3's windows move to space 2 with their order and widths. Minimize the only window in space 2 instead, then restore it; its original membership and space numbers return. Repeat with a temporarily unavailable window in space 3 while space 2 closes.
- Add the same window to two spaces; reorder and resize independently. Content is shared.
- Navigate away from a window that clamps fully offscreen moves, then return to it. Its parking and ribbon motion stay horizontal. An already visible shared window with unchanged geometry stays in place.
- Close a shared window. It disappears from both spaces.
- Remove one shared membership without closing the real window.
- Switch to an empty space. Typing must not reach a parked app; a blank Stagehand placeholder is expected.
- Create a new window. It is inserted after the current window and receives focus.

## Input and gestures

- Turn individual shortcuts off and confirm that they pass through without acting. Record replacements, including a Caps Lock chord, restart Stagehand, and confirm they persist. Reset each row and confirm the original enabled binding returns.
- Start recording a shortcut, then close Settings or switch to another app. Recording must cancel and the existing global shortcuts must resume. Starting a second recorder must cancel the first.
- Focus different apps with shortcuts, then immediately type unique text into disposable fields. Verify every character's destination.
- Repeat with two windows of the same app. Include rapid consecutive switches, held keys, key repeats, and modifiers held across a switch.
- Navigate away until Cursor is parked, then back repeatedly. No Dock animation, minimized state, or false focus failure should occur. Repeat with an app whose position is clamped by macOS.
- Repeat with the navigation overlay visible. App menus and input remain with the active real app.
- Open a confirmation dialog on a managed window. Switch away and back: the dialog stays with its owning window, does not get a ribbon slot, and keeps keyboard focus when that window is active. Repeat with two windows from the same app to check that the dialog follows the one that opened it.
- Open a dialog from an app with no other window, such as an app-modal alert or Xcode's component installer. It joins the ribbon and can be focused like a window. To reproduce one, run `open -n dist/DiscoveryProbe.app --args --standalone-dialog`.
- Exercise a blocked/slow app or modal dialog. Failed focus must pause/restore and visibly report withheld input.
- Minimize a ribbon window with Command-M, then immediately navigate onto and past its slot. Stagehand must skip it without pausing (`window_unavailable` or `window_unavailable_detected` in the log, no `automatic_pause`) and return it to its membership when restored.
- Switch to a slow-activating app such as an Electron editor while the gesture or ribbon is moving. Focus may take longer, but the ribbon, app bar, and typing must not freeze while it activates.
- Revoke Accessibility while Stagehand is running, then trigger navigation. It must stop moving windows and report the unavailable protection instead of assuming permission remains valid.
- Check Setup when Secure Input is active. Do not assume interception remains available.
- Keep macOS navigation gestures set to four fingers, then enable Stagehand's three-finger gestures. Test every direction, fast/slow swipes, diagonal starts, and staggered finger landing/lifting.
- Enable Arrow shortcut swipes with Gesture navigation off. With Reverse shortcut swipe direction on, check Control + Option swipes in all four directions, then Command + Control + Option swipes left and right to reorder the current window and up and down to move the focused window one space. Each swipe should act like the opposite arrow. Turn Reverse shortcut swipe direction off and repeat; each swipe should act like the matching arrow. Record a custom arrow binding and confirm both direction modes use it; disable it and confirm the swipe no longer triggers it. Check plain swipes, Ctrl-only swipes, pressing modifiers after three fingers land, and releasing a modifier mid-swipe. Repeat with both switches on and confirm the arrow keys still perform the same actions.
- macOS four-finger navigation and ordinary two-finger scrolling must remain intact.
- Three-finger navigation must not also trigger native Desktop changes, content scrolling, clicks, or dragging.
- Repeat on battery and after sleep/wake; check idle CPU and gesture availability.

## Interface

- The temporary app bar appears beneath the notch and disappears after navigation stops.
- Navigate repeatedly while the bar is entering, visible, and exiting. It stays present during successive changes, moves its active indicator, and dismisses only after the latest change. An old dismissal must never hide a refreshed bar.
- Enable Reduce Motion. The bar uses a fade without drop/scale movement; indicator changes do not travel between icons.
- Resize the active window continuously. The border follows its actual frame without easing behind it, and its corners match the target window.
- Place a Google Meet picture-in-picture window across the active window's edge. The focus border stays above the active window and behind the picture-in-picture window.
- Switch from a managed window to another app and back, then focus another managed window with a click and with Stagehand navigation. The border remains visible above the focused window after each switch.
- Adjust the gap with the slider, typed values, Up/Down, and Shift+Up/Down while running. Input focus remains in the number field; no keys reach another app. Invalid values restore the previous value and out-of-range values clamp.
- Click outside the gap field onto empty settings background. The edit commits, the field loses focus, and the original click still reaches its target.
- Open the menu bar quick actions. The borderless panel appears immediately without an arrow to the menu bar icon. Neither the window-gap field nor the space-color field receives focus until clicked.
- In menu bar quick actions, change the active space color with both the color picker and a typed hex value. The picker stays in front, the focus border and app bar update, and the value remains after reopening quick actions.
- With only one active or occupied space, open Settings and assign different colors to empty spaces. Close and reopen Settings and confirm the values remain. Move a window into each configured space and switch to it; the saved color appears on the focus border and app bar.
- Neither bar nor border shifts or resizes any window.
- The current application owns the macOS menu bar, except while Stagehand settings or an empty-space placeholder is active.
- Open Settings and confirm Stagehand appears in the Dock. Close Settings and confirm its Dock icon disappears while the menu bar item remains.
- Settings stay usable at the built-in display's current scaling.
- Change display scaling, Dock position, and menu-bar visibility while Stagehand is running. The ribbon and parking bounds must use the new visible frame without restarting.
- Stagehand settings joins the ribbon, can be reordered, and regains focus through the same navigation controls.
- Swipe to a native fullscreen Space. The focus border must not follow or flash over the destination; it returns on the home Desktop.
- Resize settings to its minimum size and enlarge it. Content should adapt and scroll without clipping controls.
- Turn Launch at login on, quit Stagehand, then log out and back in. Stagehand should start automatically. Turn it off and repeat; Stagehand should stay closed.
- Disable Stagehand in System Settings > General > Login Items, return to Stagehand, and confirm the toggle is off with approval guidance below it.
- All nine spaces appear in Settings so their colors can be configured. Only occupied spaces and the current space appear in the menu. Numbered shortcuts can still reach unused spaces.
