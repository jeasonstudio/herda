# Native Split, Plan 2: The End State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** herda owns pane layout. Each visible pane is a native card backed by its own `ControlTerminal` connection sized to that card, with native commands to split, close, focus and zoom.

**Architecture:** The app render connection is gone. One API socket for the sidebar, events, pane lifecycle and most input; one bincode socket per visible pane for frames and that pane's PTY size. `PaneTree` holds the split topology in points; herdr holds pane lifecycle. Nothing reads herdr's rects.

**Tech Stack:** Swift 6 strict concurrency, AppKit + SwiftUI, XCTest. Spec: `docs/superpowers/specs/2026-08-12-native-split-layout-design.md`.

**Scope note:** This merges what the spec staged as plans 2, 3 and 4. They cannot ship separately: removing the app connection removes herdr's keyboard handling, so without native commands in the same change there is no way to create a split at all. Divider drag, text selection and mouse forwarding stay out — see "Deliberately out of scope".

**Definition of done:** `Scripts/test.sh` passes; the app shows one native card per pane with real point gaps; Cmd+D / Cmd+Shift+D split; Cmd+W closes; clicking a card focuses it; typing, paste and scroll all reach the right pane; Home/End verified against real applications.

---

### Task 1: Wire encodings for a per-pane connection

`bincode::config::standard()` is varint for integers, which matches the existing
encoder. Layouts, from the variant tags in `wire.rs:1060` and the field order in
`wire.rs:392`–`:430`:

| Message | Bytes |
|---|---|
| `Hello` attach | existing fields, final `launch_mode` = varint(1) |
| `Input { data }` | varint(1) + varint(count) + bytes |
| `AttachScroll` | varint(6) + source + direction + varint(lines) + Option(column) + Option(row) + modifiers byte |
| `ControlTerminal` | varint(9) + varint(len) + utf8 target + takeover byte |

`AttachScrollSource::Wheel` = varint(0); `PageKey { input }` = varint(1) +
varint(len) + bytes. `AttachScrollDirection` is Up=0, Down=1. `Option` is a 0/1
tag byte then the payload, matching the `generated_text: None` byte the existing
`key()` encoder already writes.

**Files:** modify `Sources/HerdaKit/Protocol/WireEncoder.swift`; test
`Tests/HerdaKitTests/WireEncoderTests.swift`.

- [ ] Add `LaunchMode.terminalAttach = 1` and a `launchMode:` parameter on `hello`, defaulting to `.app`.
- [ ] Add `controlTerminal(target:takeover:)`, `input(_ bytes:)`, `attachScroll(...)`.
- [ ] Tests assert exact byte arrays for each, including a multi-byte-UTF8 target and `takeover: false`.
- [ ] Run `Scripts/test.sh`; commit.

The encodings are confirmed by the server accepting them in Task 7 — a malformed
`ControlTerminal` ends the connection with `ServerShutdown`, so this is not a
silent failure mode.

---

### Task 2: `PaneTree` — the split topology herda owns

A binary tree. Splits are addressed by **path** (a list of `.first`/`.second`)
rather than by id: paths need no bookkeeping when panes come and go, and a
divider drag already knows its path from the layout pass.

```swift
public struct PaneTree: Equatable, Sendable {
    public indirect enum Node: Equatable, Sendable {
        case pane(String)
        case split(Split)
    }
    public struct Split: Equatable, Sendable {
        public var orientation: Orientation   // .horizontal splits left|right
        public var ratio: Double              // first child's share, 0.1...0.9
        public var first: Node
        public var second: Node
    }
    public enum Orientation: Equatable, Sendable { case horizontal, vertical }

    public private(set) var root: Node?
    public private(set) var focusedPaneId: String?
    public private(set) var zoomedPaneId: String?
}
```

**Files:** create `Sources/HerdaKit/Layout/PaneTree.swift`; test
`Tests/HerdaKitTests/PaneTreeTests.swift`.

- [ ] `init()` empty; `adopt(paneId:)` sets a lone root and focuses it.
- [ ] `split(paneId:with:orientation:ratio:)` replaces that leaf with a split whose `first` is the original and `second` is the new pane; focuses the new one.
- [ ] `close(paneId:)` collapses the parent split into the sibling; moves focus to the sibling's first leaf; clears zoom if it pointed at the closed pane; leaves `root` nil when the last pane goes.
- [ ] `focus(paneId:)`, `toggleZoom(paneId:)`.
- [ ] `setRatio(_:at path:)` clamped to 0.1...0.9 — a 0-width pane would ask for 0 columns.
- [ ] `paneIds` in left-to-right, top-to-bottom order; `visiblePaneIds` returns just the zoomed pane when zoom is on.
- [ ] `neighbour(of:_ direction:)` for directional focus, resolved on the tree rather than on geometry: the sibling in the matching orientation, else walk up.
- [ ] Tests: single pane, nested splits three deep, closing an inner pane, closing the focused pane, closing the last pane, ratio clamping, zoom hiding siblings, directional neighbours.
- [ ] Run; commit.

---

### Task 3: `PaneTreeLayout` — points, then cells

**Files:** create `Sources/HerdaKit/Layout/PaneTreeLayout.swift`; test
`Tests/HerdaKitTests/PaneTreeLayoutTests.swift`.

- [ ] `frames(for tree:in rect:gap:) -> [String: CGRect]` — splits the rect by ratio, removing `gap` between siblings and giving each side half the remainder. Zoom returns the focused pane filling `rect`.
- [ ] `dividers(for tree:in rect:gap:) -> [Divider]` where `Divider` carries `path`, `orientation` and a `rect` widened to a comfortable hit target (gap plus 3pt each side) while drawing only the gap.
- [ ] `gridSize(for rect:cellSize:) -> (columns: UInt16, rows: UInt16)` — `floor`, floored at 1. Reuses nothing from `TerminalFont.gridSize` because that takes a whole viewport; same arithmetic, different input.
- [ ] Tests: two panes side by side sum to `rect.width - gap`; three-deep nesting; a rect too small for the gap still yields non-empty frames; grid size floors and never returns 0; zoom fills.
- [ ] Run; commit.

---

### Task 4: `PaneConnection` — one socket, one pane

**Files:** create `Sources/HerdaKit/Runtime/PaneConnection.swift`.

- [ ] `init(paneId:socketPath:font:)`, holding its own `TerminalGridView`.
- [ ] `open(columns:rows:)`: connect, `handshake(..., launchMode: .terminalAttach)`, send `controlTerminal(target: paneId, takeover: true)`, then `startReadLoop`. `takeover: true` because herda is the only GUI and a stale owner from a killed instance must not lock the pane out.
- [ ] `resize(columns:rows:)` debounced 50ms, skipping an unchanged grid — same policy as the old whole-window resize, for the same reason.
- [ ] `send(_ bytes:)` for raw `Input`, `scroll(...)` for `AttachScroll`.
- [ ] `close()` sends `detach()` then stops.
- [ ] Frames go straight to the view. `onShutdown` reports upward so the coordinator can drop the pane.
- [ ] No unit test for the socket itself; the handshake order is verified live in Task 7.

---

### Task 5: `PaneSessionCoordinator` — reconcile, route, command

Replaces `TerminalSession`'s render duties. Owns the tree, the connections, the
API client and one `PaneInputQueue`.

**Files:** modify `Sources/HerdaKit/Runtime/TerminalSession.swift`; create
`Sources/HerdaKit/Runtime/PaneInputRouter.swift`; test
`Tests/HerdaKitTests/PaneInputRouterTests.swift`.

- [ ] `PaneInputRouter` is pure: `route(_ input: TerminalInput, focusedPane: String) -> Route`, where `Route` is `.keys([String])`, `.text(String)`, `.bytes([UInt8])`, `.scroll(up: Bool, lines: UInt16)` or `.drop`. Every branch of the spec's input table gets a test, including that `.focus` drops (no app connection to report focus to) and that a mouse button drops (forwarding is out of scope, and the spec's reason is that terminal mouse mode is unobservable from here).
- [ ] Coordinator: on `start`, spawn the server, open the API channel, `pane.list` for the current tab, `adopt` the first pane and `split` in the rest at equal ratios so a restored multi-pane session comes up whole.
- [ ] `reconcile()`: open a connection per visible pane, close ones whose pane is gone, resize the rest from `PaneTreeLayout`.
- [ ] Commands: `splitFocused(.right/.down)` → `pane.split` → adopt the returned pane id into the tree; `closeFocused()` → `pane.close`; `focus(paneId:)` → tree + `pane.focus` so herdr's sidebar agrees; `focusNeighbour(_:)`; `toggleZoomFocused()`.
- [ ] Events: `pane_exited` / `pane_closed` remove from the tree; everything else to the sidebar. `layout_updated` is ignored — herda owns geometry.
- [ ] Run; commit.

---

### Task 6: `SplitContainerView` and the native commands

**Files:** create `Sources/Herda/SplitContainerView.swift`; modify
`Sources/Herda/ContentView.swift`, `Sources/Herda/HerdaApp.swift`,
`Sources/HerdaKit/Theme/ChromeMetrics.swift`.

- [ ] `ChromeMetrics.paneGap = 8` and `panePadding = 8`. Both on the 8pt grid — the first design's 2/6/4 compromise existed only because the gap had to fit inside one character cell, and nothing constrains it now.
- [ ] `SplitContainerView`: `GeometryReader` → `PaneTreeLayout.frames` → one `.cardSurface` per pane at its frame, content inset by `panePadding`, focused card at full opacity and the rest dimmed. Dividers drawn in the gap.
- [ ] Clicking a card calls `focus(paneId:)`. `TerminalGridView.mouseDown` already takes first responder; the card reports the pane id.
- [ ] `ContentView`: `terminalArea` hosts `SplitContainerView`. The window-level `.cardSurface` goes — the cards are the surfaces now, and two nested surfaces double the stroke.
- [ ] `HerdaApp`: a `CommandMenu("Pane")` with Split Right (Cmd+D), Split Down (Cmd+Shift+D), Close (Cmd+W), Zoom (Cmd+Ctrl+Return), Focus Left/Right/Up/Down (Cmd+Option+arrows). Every item has a shortcut, per the macOS guidelines rule that anything reachable by mouse needs a keyboard equivalent.
- [ ] Run; commit.

---

### Task 7: Live verification

- [x] `Scripts/run.sh --reset`, then confirm: one card, prompt renders, typing works.
- [x] Native cards with an 8pt gap and no character borders anywhere. Verified with three panes: one tall card beside a stacked pair.
- [x] Each pane's PTY is sized to its card. `tput` in a 1249pt-wide card reported `COLS=154 ROWS=40`, matching `floor((1249 - 16) / 8)` and `floor((704 - 16) / 17)`. Measuring the card frame instead of the content rect over-reported by two columns and one row; fixed.
- [ ] Clicking an unfocused card focuses it; typing then lands there.
- [ ] Scroll wheel scrolls the pane under the pointer, not the focused one.
- [ ] Cmd+W closes and the sibling expands to fill.
- [x] **Home/End against real applications** — done, and the answer changed the code.

  Through the pane connection's raw `Input` into zsh's line editor:

  | sequence | result |
  |---|---|
  | `ESC [ H` | `echo abcA` — ignored, marker at the end |
  | `ESC O H` | `Becho abc` — honoured, marker at the start |

  `TerminalKeyBytes` now emits SS3 (`ESC O H` / `ESC O F`) unmodified, CSI with
  parameters when modified. Re-verified live: `HOME_OK echo abcEND_OK`.

  vim could not be measured reliably — `-u NONE` made it treat the ESC as a
  standalone Esc and the rest as normal-mode commands, so the probe was
  confounded. Left open rather than explained away.

- [ ] Record the results in this file and commit.

---

## Deliberately out of scope

- **Divider drag.** Splits are equal or set at creation. `setRatio` exists and is tested, so wiring a drag gesture later touches only the view.
- **Native text selection.** herdr's mouse selection goes with the app connection, so copy-by-selection is lost until this is built. OSC 52 from applications still reaches the pasteboard, and Cmd+V still pastes.
- **Mouse forwarding to TUI applications.** Needs the per-pane toggle from the spec, because terminal mouse mode is unobservable from an attach connection.
- **Native replacements for herdr's modals.** Rename, worktree, settings. None are needed to use a split.
