# Live acceptance

Use disposable documents or text fields for typing checks, not a shell or a production form. These checks require the built app's Accessibility/Input Monitoring grants and the physical trackpad. They are not marked as passed by the automated suite.

## Start and stop

- Launch paused; confirm no windows move before Start.
- Grant Accessibility and Input Monitoring to the built Stagehand.app.
- Start with several ordinary windows on one native macOS Desktop.
- Pause and Quit independently. Verify every managed window returns to its pre-Start frame and every Stagehand-minimized window is restored.
- Repeatedly pause/start during navigation. No stale operation should move windows after pause.
- Change native macOS Desktop. Stagehand should stay enabled but suspend input and layout work, without pulling windows into the new Desktop. Return and verify automatic resume with order and widths preserved.
- Repeat Desktop switching during window navigation. No buffered typing should be replayed on the away Desktop.

## Scrolling and monocle

- Scrolling: active window fits; adjacent sliver remains visible with 95% width.
- Shrink and grow several windows independently; respect app minimum-size constraints.
- Navigate across both ends; there is no wrap.
- Reorder a window and verify focus stays with it.
- Switch to monocle: only active window occupies the display area.
- Switch back: ribbon order and widths remain.
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
- Repeat with the navigation overlay visible. App menus and input remain with the active real app.
- Exercise a blocked/slow app or modal dialog. Failed focus must pause/restore and visibly report withheld input.
- Check Setup when Secure Input is active. Do not assume interception remains available.
- Enable four-finger gestures after resolving native conflicts. Test every direction, fast/slow swipes, diagonal starts, and staggered finger landing/lifting.
- Three-finger macOS navigation and ordinary two-finger scrolling must remain intact.
- Four-finger navigation must not also trigger Mission Control, native Desktop changes, content scrolling, clicks, or dragging.
- Repeat on battery and after sleep/wake; check idle CPU and gesture availability.

## Interface

- The temporary app bar appears beneath the notch and disappears after navigation stops.
- Neither bar nor border shifts or resizes any window.
- The current application owns the macOS menu bar, except while Stagehand settings or an empty-space placeholder is active.
- Settings stay usable at the built-in display's current scaling.
- Resize settings to its minimum size and enlarge it. Content should adapt and scroll without clipping controls.
- Only occupied spaces and the current space appear in settings and the menu. Numbered shortcuts can still reach unused spaces.
