# Stagehand

> Disclaimer: this is vibecoded slop. Treat it as an experimental local prototype, not a dependable window manager.

Stagehand is a native macOS window manager for a MacBook display. It arranges real app windows in one horizontal ribbon, with keyboard and optional trackpad navigation. The active app keeps its menus and input.

## Read this before using it

- Stagehand moves and focuses real windows through Accessibility. Test it with disposable text and documents first.
- It buffers typing briefly while switching windows, then sends it to the confirmed destination. macOS does not report whether a posted key event reached a specific window, so this is not a proven zero-loss input system. Failed or expired transfers withhold input and show a warning. Secure Input or a disabled event tap can bypass this protection.
- Pause and Quit restore the window frames captured at Start. A crash or forced termination cannot run that restoration.
- Off-ribbon windows are parked in a screen corner. macOS may leave a small corner visible. If parking fails, Stagehand restores the window and pauses. It does not minimize windows to the Dock.
- Desktop tracking uses a read-only private system API. Gesture support loads Apple's private `MultitouchSupport` framework. Either can break after a macOS update. This build is for local use, not the App Store.
- This version supports one built-in display. It ignores minimized and native-fullscreen windows. Multiple-display and native-fullscreen workflows are not supported.

Stagehand binds itself to the native macOS Desktop where you press Start. It suspends input and layout work when you leave that Desktop, then resumes when you return. If it cannot identify the Desktop, it stays suspended.

## Build and run

You need macOS 14 or newer and Swift 6. The current build was tested with Swift 6.3.3 and Xcode 26.6 on Apple silicon. It has no third-party packages or remote services.

```sh
swift test
./scripts/build-app.sh
open dist/Stagehand.app
```

The app opens paused. Grant Accessibility in Setup, restart Stagehand if macOS asks, then click **Start Stagehand**. Quit other window managers first so they do not fight over shortcuts or window positions.

The script creates a local ad-hoc-signed app. Rebuilding may make macOS ask for Accessibility again. Set `STAGEHAND_SIGNING_IDENTITY` to a stable local identity if you have one.

## How it works

Each of the nine spaces keeps its own window order, focused window, and widths. Space membership lasts only for the current session.

- Navigate to an unused space with its numbered shortcut.
- Use **Move to** to remove a window from the current space.
- Use **Share with** to keep the same live window in more than one space. Each space keeps its own order and width.
- Use **Remove from this space** to remove one membership. You cannot remove the final membership.
- Drag a title bar and release to reorder a window. Resize a window to save its width when maximization is off.

New windows enter after the current window. Closing a real window removes it from every space. Empty spaces show a Stagehand placeholder so typing cannot reach a hidden app.

**Maximize windows** requests the full available display area without using native fullscreen. Turn it off to restore saved widths and heights. Apps may enforce their own size limits.

The gap accepts values from `-200` to `40` points. Negative values overlap windows and keep the active one on top. Maximize temporarily uses no gap.

The app bar appears beneath the camera housing, or at the top center on displays without a notch. Hover there or navigate to reveal it. Click an app to focus it or the space number to change spaces. The app bar and focus border do not take keyboard focus or reserve screen space.

## Controls

| Action | Shortcut |
| --- | --- |
| Previous or next window | Control + Option + Left or Right |
| Previous or next space | Control + Option + Up or Down |
| Reorder focused window | Control + Option + Command + Left or Right |
| Go to space 1 through 9 | Control + Option + number |
| Share window with space | Control + Option + Shift + number |
| Move window and follow | Control + Option + Command + number |
| Shrink or grow width | Option + Command + 1 or 2 |
| Pause and restore | Control + Option + Escape |
| Open settings | Control + Option + comma |

Navigation stops at each end. It does not wrap. Width shortcuts work only when maximization is off. Resume from settings or the menu bar item.

## Gestures

Gesture navigation is off on first launch. Choose three or four fingers. Four is the default.

- Swipe left or right for the next or previous window.
- Swipe up or down for the next or previous space.
- A horizontal drag follows your fingers and commits on release. A short drag settles back.

In System Settings > Trackpad > More Gestures, change or disable macOS gestures that use the same finger count. Three-finger dragging can also conflict. Stagehand reads system preferences only as hints and never changes them. Finger landing and lifting edge cases still need testing on real hardware.

## Diagnostic logging

Turn on **Diagnostic logging** in Setup to record starts, layout operations, focus checks, suspensions, and the exact reason for every automatic pause. **Show Log in Finder** reveals `~/Library/Logs/Stagehand/stagehand.log`.

The log uses one JSON object per line. It excludes window titles and keyboard input. Buffered input stays in memory and is never logged or written to disk.

## Verification

Run the automated suite:

```sh
swift test
```

The tests cover workspace state, layout, gestures, shortcuts, synthetic input buffering and replay, Desktop identity, focus contracts, and settings resizing. They do not move your windows, read the trackpad, or type into apps. They cannot prove real app focus or Accessibility behavior.

Render the native settings views without starting window management:

```sh
dist/Stagehand.app/Contents/MacOS/Stagehand --render-previews dist/previews
```

Complete [the live acceptance checklist](docs/ACCEPTANCE.md) before trusting Stagehand with everyday work. It covers restoration, real focus and typing, physical gestures, Desktop changes, parking, sizing, and overlays.

The executable also has focused checks named `--diagnose-focus`, `--diagnose-start`, `--diagnose-ribbon`, `--diagnose-permissions`, `--diagnose-parking`, `--diagnose-last-close`, and `--diagnose-discovery`. Run installed-app checks through `open` so macOS uses that app's Accessibility grant. Stop or pause the normal Stagehand instance first.

## Source map

- `Sources/StagehandCore` contains workspace state and layout calculations.
- `Sources/StagehandPlatform` contains Accessibility control, shortcuts, gestures, and keyboard buffering.
- `Sources/Stagehand` contains the AppKit lifecycle, SwiftUI settings, orchestration, and overlays.
