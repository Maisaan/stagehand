# Stagehand

> Disclaimer: this is vibecoded slop. Treat it as an experimental local prototype, not a dependable window manager.

## Why I built Stagehand

Sometimes the built-in MacBook display is the whole setup. The window managers I tried felt aimed at larger external displays or multi-monitor desks. I wanted something designed for the trackpad and limited screen space.

That led to three choices:

- **Use the trackpad first.** Once enabled, three-finger swipes navigate the whole workspace. The same navigation works with Control + Option + arrow keys when the keyboard is more convenient.
- **Give each axis one job.** Windows run left and right in a ribbon. Stagehand's nine spaces stack above and below, so moving vertically changes spaces.
- **Keep the app lightweight and self-contained.** The small app bundle uses native Swift, AppKit, and SwiftUI, with no third-party packages or remote services.

Stagehand moves real app windows, so the active app keeps its menus and input. It was inspired by [KiwiDesk](https://github.com/KiwiCanopy/KiwiDesk).

## Status

This project is rough and intended for local testing. It moves real windows, handles keyboard input during focus changes, and depends on private macOS APIs. Start with disposable text and documents.

Do not rely on Stagehand where a missed or misdirected keystroke could cause damage. See [Known limitations](#known-limitations) before running it.

## Requirements

- macOS 14 or newer
- Swift 6
- A MacBook with one built-in display
- Accessibility permission for the built app

The current code was tested with Swift 6.3.3 and Xcode 26.6 on Apple silicon.

## Build and install

Clone the repository, then build the app bundle:

```sh
git clone https://github.com/Maisaan/stagehand.git
cd stagehand
./scripts/build-app.sh
open dist/Stagehand.app
```

The script creates `dist/Stagehand.app` and signs it with an ad-hoc local signature. Rebuilding may make macOS ask for Accessibility again. Set `STAGEHAND_SIGNING_IDENTITY` to a stable local signing identity if you have one.

## Quick start

Stagehand opens paused and does not move windows until you start it.

1. Grant Accessibility in the Setup tab.
2. Restart Stagehand if macOS asks you to.
3. Quit other window managers so they do not compete for shortcuts or window positions.
4. Click **Start Stagehand**.

Press Control + Option + Escape to pause and restore the window frames captured at Start. You can resume from settings or the menu bar item.

Manual pauses and automatic pauses after an error preserve your spaces, window order, shared memberships, and per-space widths for resume. Closed windows are omitted. Windows that are temporarily unavailable regain their saved memberships when Stagehand discovers them again.

## Using Stagehand

Stagehand has nine numbered spaces. Each space keeps its own window order, focused window, and widths. Space membership lasts only for the current session.

- Use a numbered shortcut to open an unused space.
- Use **Move to** to remove a window from its current space.
- Use **Share with** to show the same live window in more than one space. Each space keeps its own order and width.
- Use **Remove from this space** to remove one membership. You cannot remove the last membership.
- Drag a title bar and release to reorder a window.
- Resize a window to save its width while maximization is off.

New windows enter after the current window. Closing a real window removes it from every space. Empty spaces show a Stagehand placeholder so typing cannot reach a hidden app.

### Window layout

**Maximize windows** requests the full available display area without using native fullscreen. Turn it off to restore saved widths and heights. Apps may enforce their own size limits.

The gap accepts values from `-200` to `40` points. Negative values overlap windows and keep the active window on top. Maximize temporarily removes the gap.

The app bar appears beneath the camera housing, or at the top center on displays without a notch. Hover there or navigate to reveal it. Click an app to focus it or the space number to change spaces. Choose the active border color and app bar color under Appearance in Workspace settings. The app bar and focus border do not take keyboard focus or reserve screen space.

### Controls

| Action | Shortcut |
| --- | --- |
| Previous or next window | Control + Option + Left or Right |
| Previous or next space | Control + Option + Up or Down |
| Reorder focused window | Control + Option + Command + Left or Right |
| Go to space 1 through 9 | Control + Option + number |
| Share window with space | Control + Option + Shift + number |
| Move window and follow | Control + Option + Command + number |
| Shrink or grow width | Control + Option + - or + |
| Shrink or grow height | Control + Option + Command + - or + |
| Pause and restore | Control + Option + Escape |
| Open settings | Control + Option + comma |

Navigation stops at each end and does not wrap. Width shortcuts work only when maximization is off.
These are the defaults. The Controls settings let you turn off, record, or reset each binding, including bindings that use Caps Lock as a modifier.

### Trackpad gestures

Gesture navigation is off on first launch. When enabled, Stagehand uses three-finger swipes.

- Swipe left or right for the next or previous window.
- Swipe up or down for the next or previous space.
- A horizontal drag follows your fingers and commits on release. A short drag settles back.

Keep macOS navigation gestures set to four fingers so they do not overlap with Stagehand. Three-finger dragging can still conflict. Stagehand reads system preferences as hints and never changes them. Finger landing and lifting edge cases still need testing on real hardware.

## Known limitations

- Stagehand briefly buffers typing during a window switch and sends it to the confirmed destination. macOS does not report whether a posted key event reached a specific window, so this is not a proven zero-loss input system. Failed or expired transfers withhold input and show a warning. Secure Input or a disabled event tap can bypass the protection.
- Pause and Quit restore the window frames captured at Start. A crash or forced termination cannot run that restoration.
- Stagehand parks off-ribbon windows just beyond the left or right display edge instead of minimizing them. Apps that clamp window positions may leave part of an edge visible. If Stagehand cannot confirm parking, it restores the windows and pauses.
- Stagehand manages only the native macOS Desktop where you press Start. It suspends input and layout work on other Desktops. If Desktop identity is temporarily unavailable, Stagehand keeps checking and resumes only after confirming the starting Desktop.
- Desktop tracking uses a read-only private system API. Gesture support loads Apple's private `MultitouchSupport` framework. Either can break after a macOS update. This build is not intended for App Store distribution.
- This version intentionally supports one built-in display. It ignores minimized and native-fullscreen windows. Multiple-display and native-fullscreen workflows are not supported.

## Diagnostic logging

Turn on **Diagnostic logging** in Setup to record starts, layout operations, focus checks, navigation and gesture frame transitions, suspensions, and the exact reason for every automatic pause. **Show Log in Finder** reveals `~/Library/Logs/Stagehand/stagehand.log`.

The log uses one JSON object per line and retains the previous 24 hours. It excludes window titles and keyboard input. Buffered input stays in memory and is never logged or written to disk.

## Development

Run the automated suite:

```sh
swift test
```

The tests cover workspace state, layout, gestures, shortcuts, synthetic input buffering and replay, Desktop identity, focus contracts, diagnostic logging, and settings behavior. They do not move your windows, read the trackpad, or type into apps. They cannot prove real app focus or Accessibility behavior.

Render the native settings views without starting window management:

```sh
dist/Stagehand.app/Contents/MacOS/Stagehand --render-previews dist/previews
```

Complete [the live acceptance checklist](docs/ACCEPTANCE.md) before trusting Stagehand with everyday work. It covers restoration, real focus and typing, physical gestures, Desktop changes, parking, sizing, and overlays.

The executable also provides `--diagnose-focus`, `--diagnose-start`, `--diagnose-ribbon`, `--diagnose-permissions`, `--diagnose-parking`, `--diagnose-last-close`, and `--diagnose-discovery`. Run installed-app diagnostics through `open` so macOS uses the app's Accessibility grant. Stop or pause the normal Stagehand instance first.

## Project structure

- `Sources/StagehandCore` contains workspace state and layout calculations.
- `Sources/StagehandPlatform` contains Accessibility control, shortcuts, gestures, and keyboard buffering.
- `Sources/Stagehand` contains the AppKit lifecycle, SwiftUI settings, orchestration, and overlays.
- `Tests` mirrors the three source targets.
- `docs/ACCEPTANCE.md` contains the live test checklist.
- `scripts/build-app.sh` builds and signs the local app bundle.

## License

Stagehand is licensed under the [MIT License](LICENSE).
