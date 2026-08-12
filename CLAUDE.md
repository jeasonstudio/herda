# herda

A native macOS client for [herdr](https://github.com/herdrdev/herdr), a terminal
runtime for coding agents. Native window chrome and sidebar in AppKit/SwiftUI; the
terminal area is a cell grid drawn with Core Text. The app embeds and supervises
its own headless `herdr server`, so the binary and the wire protocol are versioned
together.

herda contains no herdr code. It speaks herdr's protocol through a hand-written
bincode implementation, which is why several rules below are about verifying bytes
rather than trusting a struct definition.

## Build and test

The Xcode project is generated, not committed. Regenerate it after adding or
removing any file:

```bash
xcodegen generate
Scripts/test.sh                     # xcodebuild test, filtered
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
```

Run `Scripts/test.sh` before committing. It is fast and covers every pure unit.

Running the app needs a `herdr` binary — bundled `Resources/herdr`, then `PATH`,
then `~/.local/bin/herdr`, in that order.

## Structure

- **All logic lives in the `HerdaKit` target**, a static library. The app target is
  the UI entry point and nothing else. This is not stylistic: if the tests used the
  app as their host, running them would execute the startup sequence and spawn a
  real `herdr server`. A framework instead of a static library fails codesigning
  when embedded in an xctest bundle (`bundle format unrecognized`).
- `Sources/HerdaKit/Protocol/` — varint, framing, wire encode/decode, the client
  socket connection, the JSON API client.
- `Sources/HerdaKit/Runtime/` — locating, spawning and isolating the server;
  `TerminalSession` drives the whole startup sequence.
- `Sources/HerdaKit/Terminal/` — the grid view and everything it needs: font
  metrics, glyph resolution, block geometry, key mapping, composition layout.
- `Sources/HerdaKit/Theme/`, `Sidebar/` — palettes and sidebar state.
- `Sources/Herda/` — SwiftUI app, window, sidebar view.

## Principles

**The error-prone logic is pure, and that is where the tests are.** `Varint`,
`ByteReader`, `Framing`, `WireEncoder`, `WireDecoder`, `CharWidth`, `CellGeometry`,
`MarkedText`, `ScrollAccumulator`, `TerminalFont` and `KeyMap` are all testable
without a PTY, a window or a server. When something in the view turns out to be
worth testing, extract it into one of these rather than reaching for UI automation.

**Rendering happens in ordered passes and `draw` never mutates state.**
`TerminalGridView` walks the frame once, sorts every cell into a pass, and then
draws each pass as a group: backgrounds, block geometry, batched glyphs,
decorations, cursor. Adding a fifth kind of mark means adding a pass, not a
per-cell draw call.

**Cell metrics come from the font's own tables. Never hardcode them.** Cell size
and baseline are derived in `TerminalFont`; the handshake and every resize report
that same value to the server, which scales kitty graphics and pixel mouse
reporting by it. A hardcoded `8x16` was wrong by a point for a year.

**Block elements are geometry; box-drawing lines are glyphs.** A font's block
outlines are sized to its em box, not the cell — measured at 13pt, `█` covered 13
of the cell's 17 points, so stacked rows left a visible band. `CellGeometry` draws
those 32 characters as rectangles snapped to the backing store's pixel grid, which
is what makes adjacent cells share an edge at any font size. Box-drawing glyphs
already overhang the cell on purpose so neighbours connect; measured across a run,
they cover every device pixel column. Do not "fix" them.

**Every glyph in a row sits on one baseline.** Terminal content mixes scripts, and
a fallback font's advance and line height have nothing to do with the cell.
`GlyphCache` centres each glyph in its slot, scales it down when it would spill,
and hands the renderer one shared baseline. Letting each resolved font place its
own is what put Latin, CJK and emoji on three different lines.

**The render channel and the API channel are independent.** A stalled sidebar must
not affect the terminal and vice versa. They are separate sockets, separate tasks.

## Protocol

`HerdaKit.protocolVersion` is pinned in `HerdaKit.swift` and checked strictly at
handshake — no compatibility shims. When it changes, change it here and re-verify
the affected variants against real bytes.

**Unknown `ServerMessage` variants are skipped whole; a known variant that fails
to decode is a hard error.** Framing gives the length, so skipping is safe, and
the server does send variants this client does not handle. Silent tolerance of a
malformed *known* variant would produce corrupted frames that are very hard to
trace back.

**`FrameData::graphics` must be decoded even though nothing renders it.** Skipping
the field misaligns the rest of the stream.

**`char` is UTF-8 bytes with no length prefix; `String` is varint length plus
UTF-8.** They coincide for ASCII and diverge completely above it, so an
ASCII-only test will pass over a bug here. Ordinary text goes through
`TextCommit(String)`, not `Char`.

**Golden fixtures come from bytes observed on the wire, never from reading the
Rust struct and inferring a layout.** The existing fixtures were captured that
way; keep it that way.

## Runtime isolation

The server is spawned with `HERDR_SOCKET_PATH`, `XDG_CONFIG_HOME` and
`XDG_STATE_HOME` pointed inside
`~/Library/Application Support/app.herda/runtime`, and **every inherited
`HERDR_*` variable is removed first** — this app is frequently launched from
inside a real herdr session, and an inherited socket path would aim the child at
the developer's own server. `RuntimePaths.environment(basedOn:)` owns this.

Note that it strips only `HERDR_*`. Anything else in the launching process's
environment reaches the panes, so an agent started inside a pane can see markers
from whatever launched the app. This has surprised people; check the environment
before assuming a pane is misbehaving.

To drive the running prototype's own server from a shell:

```bash
R="$HOME/Library/Application Support/app.herda/runtime"
export HERDR_SOCKET_PATH="$R/herdr.sock" XDG_CONFIG_HOME="$R/config" XDG_STATE_HOME="$R/state"
env -u HERDR_CLIENT_SOCKET_PATH herdr pane read <pane> --format text
```

## Verifying rendering and input

This is the part that most often goes wrong by assumption, so it has its own rules.

**Measure font and glyph facts; do not reason about them.** Advances, glyph
coverage, bounding boxes and fallback resolution are all a few lines of
`CoreText`. Every geometric claim in this codebase's comments came from a probe.

**Render offscreen through the real `draw`, not through screenshots.** Build a
`TerminalGridView`, give it a synthetic `GridFrame`, and render it into an
`NSBitmapImageRep` at a magnification. Pixel assertions on that are exact;
screenshots are downscaled, which invents artefacts that are not there.

**Do not use GUI keyboard automation.** Raising the right window is unreliable and
the keystrokes land in whatever is frontmost. Construct an `NSEvent` and call
`keyDown(with:)` on the view instead — `TerminalGridInputTests` does this, and it
caught a real key-swallowing bug that manual testing would not have isolated.

**Build synthetic frames the way the wire does.** A wide character is followed by
an unmarked filler cell, which is an ordinary space. A test that omits it silently
shifts every following column.

**Read pane content from the server for ground truth.** `herdr pane read` tells you
exactly which characters are on screen, which is how you find out that a logo is
quadrant blocks and a progress meter is `U+2591`.

## Swift conventions

- Swift 6 with strict concurrency. Views are main-actor isolated; keep the
  isolation rather than working around it.
- No force unwraps or `try!` in production code.
- Every `@unchecked Sendable` carries a comment saying why it is safe.
- A `deinit` on a main-actor class cannot touch its own stored properties. Move
  the cleanup into a small owned object whose own `deinit` does it.
- Comments say why, not what. A comment that restates the code is noise; one that
  records a measurement, a constraint or a rejected alternative is why this
  codebase is navigable.

## Commits

Lowercase conventional commits, no emoji, **no AI co-author lines**. The body
explains why the change is what it is, including the numbers or the failure that
motivated it — the existing history is the reference for the expected depth.

Propose the commit message and get alignment before committing.

## Docs

`docs/design.md` is the design of record: the process model, the isolation scheme,
the protocol details and the accepted non-goals. `docs/plan-m*.md` are per
milestone and end with the acceptance results, including defects found during
acceptance and their root cause.

`design.md` records what a decision replaced and why, not just the current
answer — the one-shot keypress that could not hold the sidebar collapsed, and the
per-cell drawing that measurement disproved, are both still written down next to
what took over. Keep that when editing it: the rejected alternative is usually
the part worth knowing.
