# Stagehand

> Stagehand is built almost entirely by AI. The code gets plenty of scrutiny, but this is still experimental software.

A scrolling window manager for a Mac's displays, built around the trackpad. Windows sit side by side in a horizontal ribbon; nine spaces stack vertically. Swipe or use Control + Option + arrows to move between them.

Stagehand moves real app windows, so apps keep their own menus and input. It is native Swift, AppKit, and SwiftUI with no third-party packages or network access. Inspired by [KiwiDesk](https://github.com/KiwiCanopy/KiwiDesk).

## Requirements

- macOS 14 or newer, on a Mac; external displays are supported
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

Each space keeps its own window order, focus, and widths for the session. A window can be shared with several spaces. An app that quits and relaunches, as for an update, gets its old places in the ribbon back. Drag a window by its title bar to reorder it; resize it to set its width (25% to 100% of the screen).

| Action | Shortcut |
| --- | --- |
| Previous / next window | ⌃⌥ ← / → |
| Previous / next space | ⌃⌥ ↑ / ↓ |
| Move window left / right | ⌃⌥⌘ ← / → |
| Move window up / down a space | ⌃⌥⌘ ↑ / ↓ |
| Move window left / right in its tile | ⌃⌥⇧ ← / → |
| Move window up / down in its tile | ⌃⌥⌘⇧ ↑ / ↓ |
| Pane above / below in a tile | ⌃⌥⇧ ↑ / ↓ |
| Tile layout: one window per tile, side by side, stacked, 2×2, one wide over two | ⌃⌥ U, S, T, G, W |
| Go to space 1–9 | ⌃⌥ 1–9 |
| Move window to space 1–9 | ⌃⌥⌘ 1–9 |
| Share window with space 1–9 | ⌃⌥⇧ 1–9 |
| Move space to the display on the left / right | ⌃⌥⌘⇧ ← / → |
| Shrink / grow width | ⌃⌥ - / + |
| Cycle width presets | ⌃⌥ 0, ⌃⌥⇧ 0 |
| Shrink / grow height | ⌃⌥⌘ - / + |
| Pause or start | ⌃⌥ Esc |
| Settings | ⌃⌥ , |
| Show shortcuts | ⌃⌥⌘ / |

Every shortcut can be changed or turned off in Settings > Controls.

### Tiles

A tile is one place in the ribbon. It can hold several windows, each in a pane: side by side, stacked, a 2×2 grid, or one wide window over two. The ribbon scrolls by tile, so a tile comes into view as one. A lone window is a tile with one pane and behaves as it always did.

- ⌃⌥ S, T, G and W lay out the current window's tile side by side, stacked, as a 2×2 grid, or as one wide window over two. A tile that needs more windows takes the next ones in the ribbon, then the ones before it; extra windows become tiles of their own just after it. Side by side, the grid and wide over two take the whole screen width. ⌃⌥ U breaks the tile back into one tile per window.
- ⌃⌥ ← / → moves focus by position: to the pane on that side in the tile, then into the neighboring tile at its facing edge. Going right and back left returns to the pane you left. ⌃⌥⇧ ↑ / ↓ moves to the pane above or below and never leaves the tile. Hold either to keep going.
- ⌃⌥⇧ ← / → moves the current window: it swaps with the pane on that side; at the tile's edge it leaves as its own tile on that side; alone, it joins the neighboring tile at its facing edge, and the tile widens by its width (up to the whole screen). ⌃⌥⌘⇧ ↑ / ↓ swaps it with the pane above or below. It keeps focus. ⌃⌥⌘ ← / → moves the whole tile.
- Panes fill the screen's height and the tile's width, with the Pane gap (Settings > Layout, 0 to 40 pt) between them. The Tile gap sets the space between tiles; a negative Tile gap overlaps tiles but never panes. Panes in a row share their top and bottom edges.
- Drag the edge between two panes to trade space, or a side edge to set the tile's width; the tile's top and bottom edges stay at the screen's edges. Drag a window by its title bar onto another pane of its tile to swap them, or out of the tile to make it its own tile.
- When a window closes, the panes next to it grow into its space. A window that comes back, or an app that relaunches, returns to its pane; the tile keeps its current width and widens only by the returning window's share.
- If the windows can't get small enough to fit (some apps have a minimum size), or the space has too few windows for a layout, Stagehand leaves them as they were and says so in the app bar. It keeps running.
- New and restored windows always get their own tile. With Arrow shortcut swipes on, the same keys work with a three-finger swipe.

**Gestures** are off by default; turn them on in Settings > General > Gestures. Three-finger swipes move between windows (left/right) and spaces (up/down). You can keep swiping with two fingers while a third holds a drag-and-drop. Set macOS's own navigation gestures to four fingers to avoid overlap.

The **app bar** appears under the notch (or top center) when you navigate or hover there. It shows the active app and space; click an app or space number to jump to it. A tile's apps sit together on one shared backing, and each can still be clicked. Each space can have its own accent color.

### Displays

Each of the nine spaces belongs to one display, and each display shows one of its spaces. A display that connects with no space of its own takes the lowest-numbered empty space. Unplugging a display moves its spaces to the built-in display (or, with the lid closed, the main display); they return when it is plugged in again.

- Swipes and shortcuts act on the focused display: the one showing the space with keyboard focus. ⌃⌥ ↑ / ↓ cycles only that display's spaces. ⌃⌥ 1–9 to a space on another display focuses that display.
- ⌃⌥ ← / → at the end of a ribbon crosses to the display on that side, entering its space at the facing edge. Three-finger swipes never leave the focused display.
- ⌃⌥⌘⇧ ← / → moves the current space to the display on that side; focus goes with it.
- A window shared into spaces shown on two displays is on the display under the pointer, unless it has keyboard focus; the other display shows a placeholder in its place. Click the placeholder to bring the window there.
- The app bar appears on the focused display when you navigate, and on any display when you hover under its notch or top center.
- Stagehand reads each display's macOS Desktop when "Displays have separate Spaces" is on (System Settings > Desktop & Dock). Switching the Desktop on any display pauses Stagehand on every display until you return.

## Limitations

- The macOS Desktop each display showed when you pressed Start. Minimized and native full-screen windows are ignored.
- Each display needs a free left or right edge to hide windows at. When a display has displays on both sides, Stagehand manages the built-in display alone, and pauses if the built-in display is the one in the middle.
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
