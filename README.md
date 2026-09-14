# Stagehand

A small native macOS window manager for a MacBook display. One horizontal ribbon, keyboard navigation, optional four-finger gestures, and an app bar that appears only while navigating.

Stagehand arranges real application windows. The active application keeps its menus and input. The navigation bar and focus border do not activate Stagehand or reserve screen space.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain. Built and tested here with Swift 6.3.3 / Xcode 26.6 on Apple silicon. No third-party packages or remote services.

```sh
swift test
./scripts/build-app.sh
open dist/Stagehand.app
```

The app opens paused. In Setup, grant Accessibility. Grant Input Monitoring for keyboard handoff protection, then restart Stagehand if macOS requests it. Press **Start Stagehand** when ready to arrange windows. Quit KiwiDesk or other managers first to avoid competing shortcuts and window changes.

The build script makes a local, ad-hoc-signed app. Rebuilding can require removing and re-adding its privacy permissions. If you have a stable signing identity, set `STAGEHAND_SIGNING_IDENTITY` when building. No certificate is created and no remote is used by the build.

## Ribbon

- With **Maximize windows** off, windows have individual widths from 25% to 95% of the available display width and use the available height.
- With it on, windows request the full available width. Turning it off restores the individual widths. This is window resizing, not native fullscreen.
- Apps can constrain their size. Settings shows their actual width, and the ribbon packs to the accepted size instead of leaving an unused slot.
- Gap is measured in points. Positive values separate windows; negative values overlap them horizontally. The active window stays on top. Maximized windows do not reserve neighboring strips.
- Adjust the gap with the slider or number field, from −200 to 40 points. Return or leaving the field applies a typed value. Up/Down changes it by 1 point; Shift changes it by 10. The slider applies on release.

The maximize toggle and gap apply to all nine spaces. Settings and the menu show only occupied spaces and the current space. Use a numbered shortcut to enter an unused space. Navigation stops at the ends, without wrapping. Drag a window by its title bar and release it to reorder within the ribbon; it does not become free-floating. Resize a window with maximization off to change its individual width.

Each space remembers its order, scrolling widths, and focused window. Move removes a window from its current space. Add to Another Space keeps the same live window in both spaces, independently ordered and sized. Remove from This Space removes only that membership; the last membership cannot be removed. Closing the real window removes every membership.

New windows enter after the current window. Stagehand's own settings window joins the ribbon too. Empty spaces display a Stagehand placeholder so typing cannot reach a hidden application. Stagehand's menus appear only while its settings or empty-space window is active. Switching to another window restores that application's menus.

The settings window is resizable. Settings save maximization, gap, and the gesture preference. Space membership is session-only in this MVP.

The navigation bar stays visible through successive changes and moves its selection indicator in place. It enters and exits toward the top using short scale and opacity transitions. Reduce Motion removes movement. Border focus feedback uses opacity only; window movement and resizing are tracked immediately, without geometry animation. These overlays never wait on or take ownership of keyboard focus.

## Controls

| Action | Shortcut |
| --- | --- |
| Previous / next window | Control + Option + Left / Right |
| Previous / next space | Control + Option + Up / Down |
| Reorder focused window | Control + Option + Command + Left / Right |
| Go to space 1–9 | Control + Option + number |
| Move window to space | Control + Option + Shift + number |
| Move window and follow | Control + Option + Command + number |
| Shrink / grow width | Option + Command + 1 / 2 |
| Pause and restore | Control + Option + Escape |
| Settings | Control + Option + comma |

Resume through the menu-bar item or settings. Pausing releases the global shortcuts. Width shortcuts apply only with maximization off. Shortcuts are fixed for this version. Add to Another Space is available from the current window's menu in the Workspace tab.

Four-finger gestures are optional and off on first launch:

- Swipe left / right: next / previous window.
- Swipe up / down: next / previous space.
- One contact sequence produces at most one action. Three fingers, five fingers, ambiguous diagonals, and unstable contacts are rejected.

In System Settings → Trackpad → More Gestures, move native actions assigned to four fingers to three fingers, or disable them. Detection reads preferences as hints; the System Settings UI is authoritative. Stagehand never rewrites system gesture settings. Three-finger dragging can also conflict. A scoped scroll-event filter prevents scroll leakage once a four-finger swipe is recognized; edge cases during finger landing/lifting still require device testing.

## Focus and restoration

Navigation activates and raises the destination's real AX window, and confirms both the frontmost application and focused window. If the system-wide Accessibility focus query has no value, confirmation still requires the target app to be active and frontmost and its direct Accessibility query to identify the exact target window. Animation never delays the focus request. If a focus change fails, Stagehand pauses and restores original window frames.

With Input Monitoring, the keyboard event tap begins a short in-memory transfer buffer at a navigation shortcut, before subsequent typing events. After focus is confirmed, buffered events are posted to the destination process. Failed or expired transfers withhold buffered events and show a warning rather than inject them into an unverified app. Input is never logged or written to disk.

**This is a prototype, not a proven zero-loss input guarantee.** macOS provides no acknowledgement that a posted key event was consumed by a specific window. Rapid transitions between two windows of the same process and key releases spanning switches need live validation. Secure Input or a disabled event tap can bypass protection; Setup reports its current availability. A short event-loop allowance after replay reduces queue races but is not a delivery guarantee.

Inactive/offscreen windows are parked individually. When an app refuses an offscreen position, Stagehand falls back to minimizing that window, which can inherit macOS's Dock animation. Pause and Quit restore original frames and unminimize windows that Stagehand minimized. User-minimized windows and native-fullscreen windows are excluded. Crashes or forced termination cannot run restoration; a window minimized by Stagehand can be reopened from the Dock.

New windows must match on-screen CoreGraphics metadata before admission. Ambiguous same-app windows with identical frames can be skipped until distinguishable. Stagehand stays enabled on the native Desktop where you press Start. Leaving that Desktop suspends its input and layout work without discarding its spaces. Returning resumes automatically. Desktop identity uses a read-only private system API; when identity is unavailable, Stagehand stays suspended rather than managing an unknown Desktop. Pause and Start again to bind to a different Desktop. This MVP targets one built-in display; native fullscreen and multiple-display workflows are deferred.

Four-finger recognition loads Apple's private `MultitouchSupport` framework at runtime and fails gracefully when unavailable. Its ABI can change with macOS updates. This build is intended for local use, not App Store submission.

## Verification

`swift test` exercises shared membership, independent ordering/widths, reconciliation, bounded navigation, layout geometry, gesture recognition, shortcut uniqueness, input-buffer/replay behavior with synthetic events, Desktop identity, focus-attempt contracts, and native settings resizing. Tests never move your application windows, monitor the trackpad, or post real typing. Focus contract tests do not prove real-app activation works.

To render the three actual native settings views at default, compact, and expanded sizes without starting window management:

```sh
dist/Stagehand.app/Contents/MacOS/Stagehand --render-previews dist/previews
```

See [the live acceptance checklist](docs/ACCEPTANCE.md) before relying on Stagehand for everyday work. Accessibility permissions and physical four-finger swipes cannot be certified by the unit tests.

For explicit focus diagnostics, launch the installed app through `open` so macOS uses its app privacy grant. `--diagnose-focus <bundle-id>` attempts focus without resizing or typing, then restores the previous focus. `--diagnose-start` runs Start once and restores the managed frames afterward. `--diagnose-ribbon` also registers a temporary Stagehand settings window and checks focus across the ribbon. These commands print focus status, process IDs, timing, and window geometry, never titles or input. Keep the normal Stagehand instance paused during these checks. For example:

```sh
open -n -W -g --stdout /tmp/stagehand-focus.log /Applications/Stagehand.app --args --diagnose-focus com.linear
```

`--diagnose-permissions` only reports the installed app's Accessibility and Input Monitoring grants. It does not request access, start management, or activate another window.

## Source map

- `Sources/StagehandCore`: pure workspace state and layout calculations.
- `Sources/StagehandPlatform`: Accessibility window control, global hotkeys, gesture input, and temporary keyboard buffering.
- `Sources/Stagehand`: AppKit lifecycle, SwiftUI settings, orchestration, and overlays.

Technical references: [Apple Accessibility APIs](https://developer.apple.com/documentation/applicationservices/axuielement), [nonactivating panels](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel), [Touch-Tab](https://github.com/ris58h/touch-tab), and [Trident's gesture implementation notes](https://github.com/cyanyux/trident).
