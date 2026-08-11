# herda

A native macOS client for [herdr](https://github.com/herdrdev/herdr), a terminal
runtime for coding agents.

herdr keeps a set of PTYs alive with agents — Claude Code, Codex, Cursor — running
inside them, and its own TUI is only one front end for that. herda is a second one:
spaces and agents are native AppKit/SwiftUI, and the terminal area is a cell grid
drawn directly with Core Text. The app embeds and supervises its own headless
`herdr server`, so the binary and the wire protocol are versioned together and can
never drift apart.

There is no terminal emulator here. herdr parses VT on the server and sends a
structured cell grid, so herda renders a frame rather than interpreting escape
sequences.

## Status

Working, prototype-grade. It starts a server, runs agents, draws their output,
takes keyboard and mouse input including CJK composition, and shows live agent
status in a native sidebar. It does not do crash recovery, reconnection, signing,
notarization, or updates. See [Non-goals](#non-goals).

## How it works

```
herda (single window, Swift)
    │
    ├── API socket ──────┐   NDJSON requests + events.subscribe
    └── client socket ───┤   length-prefixed bincode
                         ▼
              herdr server (embedded binary, headless)
                         │
                    PTY × N (claude / codex / shell / ...)
```

The app is the server's parent process. Two channels run independently, so a
stalled sidebar cannot affect the terminal or the reverse:

| | source | path |
|---|---|---|
| Rendering | client socket | `ClientProtocolConn` → `WireDecoder` → `GridFrame` → `TerminalGridView` |
| Input | `NSEvent` | `KeyMap` → `WireEncoder` → client socket |
| Sidebar | API socket | `ApiClient` (`events.subscribe`) → `SidebarModel` → `SidebarView` |

herdr's own sidebar and tab bar are configured off, so the whole terminal area is
one grid and herda supplies the chrome around it. Splits, focus and prefix keys
still behave exactly as they do in herdr's TUI, because the server is still doing
the layout.

The wire protocol is implemented in Swift by hand — bincode varint framing across
six small files — rather than bound to Rust, which keeps the build to a single
Xcode project. The protocol version is pinned in `HerdaKit.swift` and checked
strictly at handshake, with no compatibility shims.

## Requirements

- macOS 14 or later
- Xcode with a Swift 6 toolchain
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — the `.xcodeproj` is
  generated, not committed
- A `herdr` binary speaking protocol version 19 (verified against herdr 0.8.0).
  It is looked up in the app bundle's `Resources/`, then `PATH`, then
  `~/.local/bin/herdr`.

A font with full coverage of what agents draw with is worth having. herda prefers
Maple Mono NF CN, then JetBrains Mono, then Menlo, then the system monospace font.
The first is the one measured to cover CJK at a true double advance, Nerd Font
private-use glyphs, braille and block elements, with real bold and italic faces.

## Build and run

```bash
xcodegen generate
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/Herda.app
```

Runtime state is fully isolated from any herdr session you already have running.
The embedded server gets its own socket, config and state directories under
`~/Library/Application Support/app.herda/runtime`, and every inherited
`HERDR_*` variable is stripped before it is spawned.

## Tests

```bash
Scripts/test.sh
```

Everything that can go subtly wrong is a pure unit — varint and framing, the wire
codec, character display width, block geometry, cell metrics, glyph placement, key
mapping, composition layout, scroll accumulation — so the suite needs no PTY, no
window and no server. Rendering is covered by drawing synthetic frames offscreen
through the real draw path and asserting on pixels; input is covered by handing
synthetic `NSEvent`s to the view.

## Rendering notes

The terminal grid is drawn in ordered passes rather than cell by cell, and a few
of the details are load-bearing:

- **Batching.** Drawing each cell with its own `NSString.draw` measured 45.6 ms
  for a 140×47 grid — a 22 fps ceiling — because every call builds a fresh text
  layout and re-resolves font fallback. Grouping into one `CTFontDrawGlyphs` call
  per (font, colour) brings the same frame to 3.1 ms.
- **Block elements are geometry, not glyphs.** A font's block outlines are sized
  to its em box, not to the cell: at 13pt `█` covered 13 of the cell's 17 points,
  so stacked rows never touched and block art came out banded. Those 32 characters
  are drawn as rectangles snapped to the backing store's pixel grid, which is what
  makes adjacent cells share an edge at any font size. Shades become a flat blend,
  because a stipple pattern does not tile across a cell boundary.
- **One baseline per row.** Terminal content mixes scripts freely and a fallback
  font's advance has nothing to do with the cell — CJK came back 12.9 points wide
  for a 16-point slot, colour emoji 19. Each glyph is centred in its slot and
  scaled down when it would spill, and every font shares one baseline.
- **Cell metrics are derived, never hardcoded**, and the real values are what the
  handshake reports to the server.
- **Composition is drawn by herda**, not the pane. One layout drives both the text
  under the cursor and the candidate window's anchor, measured in display columns,
  so a long phrase wraps instead of running off the right edge.

## Layout

```
project.yml                  xcodegen input
Sources/
  HerdaKit/                  static library — all logic, no UI
    Protocol/                varint, framing, wire codec, sockets, JSON API
    Runtime/                 server supervision, isolation, session startup
    Terminal/                grid view, font metrics, glyph cache, block geometry,
                             key map, composition layout, scroll accumulation
    Theme/                   herdr's 18 built-in palettes
    Sidebar/                 workspace and agent state
  Herda/                     SwiftUI app, window, sidebar view
Tests/HerdaKitTests/         no host app required
docs/                        design of record and per-milestone plans
```

Logic lives in a static library rather than the app target for a concrete reason:
if the tests used the app as their host, running them would execute the startup
sequence and spawn a real server.

## Non-goals

Deliberately out of scope: kitty graphics rendering (the field is still decoded, or
the byte stream would misalign), remote and SSH sessions, multiple windows or tabs,
native split layout, per-pane native scrollbars and context menus, crash recovery
and reconnection, and anything to do with signing, notarization or distribution.

Pane dividers and herdr's own modals are still character-drawn by the server. That
is the known ceiling of putting native chrome around one server-laid-out grid, and
it is accepted.

## Docs

- [`DEVELOPMENT.md`](DEVELOPMENT.md) — the working guide: toolchain, the edit
  loop, driving the embedded server from a shell, and how rendering, input and
  protocol changes are verified
- [`docs/design.md`](docs/design.md) — process model, isolation scheme, protocol
  details, decision record, accepted risks
- [`docs/plan-m1.md`](docs/plan-m1.md),
  [`plan-m2.md`](docs/plan-m2.md),
  [`plan-m3.md`](docs/plan-m3.md) — per-milestone plans, each ending with its
  acceptance results and the defects acceptance found
- [`CLAUDE.md`](CLAUDE.md) — conventions and verification discipline for agents
  working in this repo

## License

MIT — see [LICENSE](LICENSE).

herda contains no herdr code; it speaks herdr's protocol as an independent client.
