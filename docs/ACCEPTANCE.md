# Live acceptance

Use disposable documents or text fields for typing checks, not a shell or a production form. These checks require the built app's Accessibility/Input Monitoring grants and the physical trackpad. They are not marked as passed by the automated suite.

## Start and stop

- Launch paused; confirm no windows move before Start.
- Grant Accessibility and Input Monitoring to the built Stagehand.app.
- Start with several ordinary windows on one native macOS Desktop.
- Pause and Quit independently. Verify every managed window returns to its pre-Start frame. Stagehand must never minimize a window to the Dock.
- Repeatedly pause/start during navigation. No stale operation should move windows after pause.
- Change native macOS Desktop. Stagehand should stay enabled but suspend input and layout work, without pulling windows into the new Desktop. Return and verify automatic resume with order and widths preserved.
- Repeat Desktop switching during window navigation. No buffered typing should be replayed on the away Desktop.

## Ribbon sizing and overlap

- Scrolling: active window fits; adjacent sliver remains visible with 95% width.
- Shrink and grow several windows independently; respect app minimum-size constraints.
- Inactive windows use 95% of available height and stay centered. Focus requests 100%. Apps with fixed/minimum/maximum heights stay centered at their actual accepted size.
- Navigate across both ends; there is no wrap.
- Reorder a window and verify focus stays with it.
- Enable Maximize windows: the active window requests the full available width without native fullscreen.
- Disable it: individual widths and ribbon order return unchanged.
- System Settings: the displayed percentage reflects its constrained width; focusing the last window leaves no unused slot to its right.
- Apply a negative gap. Windows overlap horizontally with the active one above its neighbors. A full-width active window covers the available area.
- Drag a title bar, hold it still, then release. Reorder only on release; the window rejoins the ribbon instead of remaining detached.
- Drag-resize a scrolling window, including immediately after navigation. Its new width should be remembered within the allowed range.

## Spaces and shared windows

- Move a window to an empty space without following. The outgoing space remains active.
- Move and follow. The moved window receives focus.
- Add the same T3 window to two spaces; reorder and resize independently. Content is shared.
- Close a shared window. It disappears from both spaces.
- Remove one shared membership without closing the real window.
- Switch to an empty space. Typing must not reach a parked app; a blank Stagehand placeholder is expected.
- Create a new window. It is inserted after the current window and receives focus.

## Input and gestures

- Focus different apps with shortcuts, then immediately type unique text into disposable fields. Verify every character's destination.
- Repeat with two windows of the same app. Include rapid consecutive switches, held keys, key repeats, and modifiers held across a switch.
- Navigate away until Cursor is parked, then back repeatedly. No Dock animation, minimized state, or false focus failure should occur. Repeat with an app whose position is clamped by macOS.
- Repeat with the navigation overlay visible. App menus and input remain with the active real app.
- Exercise a blocked/slow app or modal dialog. Failed focus must pause/restore and visibly report withheld input.
- Check Setup when Secure Input is active. Do not assume interception remains available.
- Enable four-finger gestures after resolving native conflicts. Test every direction, fast/slow swipes, diagonal starts, and staggered finger landing/lifting.
- Three-finger macOS navigation and ordinary two-finger scrolling must remain intact.
- Four-finger navigation must not also trigger Mission Control, native Desktop changes, content scrolling, clicks, or dragging.
- Repeat on battery and after sleep/wake; check idle CPU and gesture availability.

## Interface

- The temporary app bar appears beneath the notch and disappears after navigation stops.
- Navigate repeatedly while the bar is entering, visible, and exiting. It stays present during successive changes, moves its active indicator, and dismisses only after the latest change. An old dismissal must never hide a refreshed bar.
- Enable Reduce Motion. The bar uses a fade without drop/scale movement; indicator changes do not travel between icons.
- Resize the active window continuously. The border follows its actual frame without easing behind it, and its corners match the target window.
- Adjust the gap with the slider, typed values, Up/Down, and Shift+Up/Down while running. Input focus remains in the number field; no keys reach another app. Invalid values restore the previous value and out-of-range values clamp.
- Click outside the gap field onto empty settings background. The edit commits, the field loses focus, and the original click still reaches its target.
- Neither bar nor border shifts or resizes any window.
- The current application owns the macOS menu bar, except while Stagehand settings or an empty-space placeholder is active.
- Settings stay usable at the built-in display's current scaling.
- Stagehand settings joins the ribbon, can be reordered, and regains focus through the same navigation controls.
- Swipe to a native fullscreen Space. The focus border must not follow or flash over the destination; it returns on the home Desktop.
- Resize settings to its minimum size and enlarge it. Content should adapt and scroll without clipping controls.
- Only occupied spaces and the current space appear in settings and the menu. Numbered shortcuts can still reach unused spaces.
