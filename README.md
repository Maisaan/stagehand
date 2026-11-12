# Stagehand

> Stagehand is built almost entirely by AI. The code gets plenty of scrutiny, but this is still experimental software.

A scrolling window manager for a MacBook's built-in display, built around the trackpad. Windows sit side by side in a horizontal ribbon; nine spaces stack vertically. Swipe or use Control + Option + arrows to move between them.

Stagehand moves real app windows, so apps keep their own menus and input. It is native Swift, AppKit, and SwiftUI with no third-party packages or network access. Inspired by [KiwiDesk](https://github.com/KiwiCanopy/KiwiDesk).

## Requirements

- macOS 14 or newer, on a MacBook using only its built-in display
- Swift 6.2 or newer (Xcode 26 or newer)
- Accessibility permission

## Install

```sh
git clone https://github.com/Maisaan/stagehand.git
cd stagehand
./scripts/build-app.sh
open dist/Stagehand.app
```

The build signs with `STAGEHAND_SIGNING_IDENTITY`, else your first Apple Development certificate, else ad hoc. A certificate keeps the Accessibility grant across rebuilds; an ad-hoc build asks again each time.

On first launch, grant Accessibility in Setup, quit other window managers, and press **Start Stagehand**. Later launches start automatically.

Press Control + Option + Escape to pause. Pausing, quitting, and relaunching after a crash restore windows to where they were at Start.

## Usage

Each space keeps its own window order, focus, and widths for the session. A window can be shared with several spaces. An app that quits and relaunches, as for an update, gets its old slots back. Drag a window by its title bar to reorder it; resize it to set its width (25% to 100% of the screen).

| Action | Shortcut |
| --- | --- |
| Previous / next window | ⌃⌥ ← / → |
| Previous / next space | ⌃⌥ ↑ / ↓ |
| Move window left / right | ⌃⌥⌘ ← / → |
| Move window up / down a space | ⌃⌥⌘ ↑ / ↓ |
| Stack or unstack window left / right | ⌃⌥⇧ ← / → |
| Window above / below in a stack | ⌃⌥⇧ ↑ / ↓ |
| Go to space 1–9 | ⌃⌥ 1–9 |
| Move window to space 1–9 | ⌃⌥⌘ 1–9 |
| Share window with space 1–9 | ⌃⌥⇧ 1–9 |
| Shrink / grow width | ⌃⌥ - / + |
| Cycle width presets | ⌃⌥ 0, ⌃⌥⇧ 0 |
| Shrink / grow height | ⌃⌥⌘ - / + |
| Pause or start | ⌃⌥ Esc |
| Settings | ⌃⌥ , |
| Show shortcuts | ⌃⌥⌘ / |

Every shortcut can be changed or turned off in Settings > Controls.

### Stacks

A ribbon slot can hold several windows, one above the other: a stack. The ribbon scrolls by slot, so a stack comes into view as one.

- ⌃⌥⇧ ← / → moves the current window sideways. Alone in its slot, it joins the stack (or window) on that side, at the bottom. In a stack, it leaves and becomes its own slot on that side. It keeps focus.
- ⌃⌥⇧ ↑ / ↓ focuses the window above or below in the same stack. It stops at the ends; hold the keys to keep going.
- ⌃⌥ ← / → enters the next slot at the window you last used there. ⌃⌥⌘ ← / → moves the whole stack.
- The windows share the screen's height and the slot's width. Drag a window's top or bottom edge to trade height with its neighbor, or a side edge to set the stack's width. Drag a window by its title bar up or down within its stack to reorder it, or out of the stack to make it its own slot.
- If the windows can't get short enough to fit (some apps have a minimum height), Stagehand leaves them as they were and says so in the app bar. It keeps running.
- New and restored windows always get their own slot. With Arrow shortcut swipes on, the same keys work with a three-finger swipe.

**Gestures** are off by default; turn them on in Settings > General > Gestures. Three-finger swipes move between windows (left/right) and spaces (up/down). You can keep swiping with two fingers while a third holds a drag-and-drop. Set macOS's own navigation gestures to four fingers to avoid overlap.

The **app bar** appears under the notch (or top center) when you navigate or hover there. It shows the active app and space; click an app or space number to jump to it. A stack's apps sit together on one shared backing, and each can still be clicked. Each space can have its own accent color.

## Limitations

- One built-in display and the macOS Desktop where you pressed Start. Minimized and native full-screen windows are ignored.
- Hidden windows are parked just past the screen edge. Apps that refuse to move off-screen can be listed under Settings > Layout > Parked edge.
- Typing during a switch is buffered and replayed into the new window. macOS can't confirm delivery, so don't rely on Stagehand where a misdirected keystroke could do damage.
- Uses private macOS APIs (Desktop tracking, `MultitouchSupport`) that may break after an update.

## Development

```sh
swift test
```

Synthetic tests don't prove real focus or Accessibility behavior. Before trusting a change, run the [live acceptance checks](docs/ACCEPTANCE.md); for performance work see [docs/PERFORMANCE.md](docs/PERFORMANCE.md). Contributor rules are in [AGENTS.md](AGENTS.md).

Turn on **Diagnostic logging** in Setup to write `~/Library/Logs/Stagehand/stagehand.log` (JSON lines, last 24 hours, no app names, window titles, or typed input).

| Path | Contents |
| --- | --- |
| `Sources/StagehandCore` | Workspace state and layout math |
| `Sources/StagehandPlatform` | Accessibility, shortcuts, gestures, input buffering |
| `Sources/Stagehand` | App lifecycle, settings UI, overlays |
| `scripts/` | Build, acceptance, benchmark, and log-analysis tools |

## License

[MIT](LICENSE). Interface icons are [Phosphor Icons](https://phosphoricons.com) (MIT, see [license](Sources/Stagehand/Resources/Phosphor/LICENSE)).
