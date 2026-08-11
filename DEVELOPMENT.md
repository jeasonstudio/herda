# Development

[`README.md`](README.md) explains what herda is and why the rendering code is
shaped the way it is. [`CLAUDE.md`](CLAUDE.md) states the constraints the code
establishes, each with the reason that makes it stick. This file is the working
guide: how to build it, how to verify a change, and which parts will cost you an
afternoon if you assume instead of measure.

## Toolchain

| | version | how it is used |
|---|---|---|
| macOS | 14 or later | deployment target, set in `project.yml` |
| Xcode | 26.6 (17F113) | what the project is developed and gated against |
| Swift | 6 | strict concurrency, `SWIFT_VERSION` in `project.yml` |
| [`xcodegen`](https://github.com/yonaskolb/XcodeGen) | recent | `brew install xcodegen` — the `.xcodeproj` is generated, not committed |
| `herdr` | 0.8.0 | must speak protocol 19 |
| `xcbeautify` | — | only CI needs it |

Swift 6 strict-concurrency diagnostics differ between Xcode releases, which is
why CI pins 26.6 rather than taking the runner image's default. A newer Xcode
will usually work; if it reports isolation errors that CI does not, that is why.

You do not need to run a herdr server yourself. The app spawns and supervises
its own, found in the app bundle's `Resources/`, then `PATH`, then
`~/.local/bin/herdr` — `HerdrRuntime.defaultCandidates()` owns that order.

A font with full coverage of what agents draw with is worth installing.
`TerminalFont.preferredFamilies` tries Maple Mono NF CN, then JetBrains Mono,
then Menlo, then the system monospace font, and falls back silently. The test
suite does not depend on any of them: it asserts relational properties — that
advances are integral, that the family is monospaced, that bold and italic
resolve within the same family — rather than family-specific constants.

## First build

```bash
xcodegen generate
xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/HerdrPrototype.app
```

Or `open macos-client.xcodeproj` and ⌘R. The scheme builds `HerdrKitTests` only
for the test action, not for running, so ⌘R will not tell you the test target
stopped compiling — ⌘U will.

The scheme, product and bundle identifier still carry the prototype's original
name (`HerdrPrototype`, `dev.herdr.macos-client-prototype`). Renaming them is
pending; until then, that identifier is what the runtime directory is keyed on.

## The edit loop

### Regenerate the project after adding or removing a file

This is the mistake everyone makes once. `project.yml` lists directories, not
files, so a new `.swift` file is picked up — but only the next time the project
is generated:

```bash
xcodegen generate
```

Symptoms of skipping it: your new type is "cannot find in scope" from a file
that visibly sits next to it, or a file you deleted is still a build input and
cannot be found.

### Run the tests

```bash
Scripts/test.sh
```

311 tests across 25 files, 0.6 s of execution and about 12 s wall clock
including the build. No PTY, no window, no server — see [Testing](#testing).

The script forwards extra arguments to `xcodebuild`, so you can narrow it:

```bash
Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
Scripts/test.sh -only-testing:HerdrKitTests/KeyMapTests/testMapsSpecialKeyCodes
```

The script filters `xcodebuild`'s noise through `grep`, but `grep` exits 1 when
nothing matches, so the pipeline's own status cannot stand in for the build's.
It reads `xcodebuild`'s status out of `PIPESTATUS[0]` and exits with that
instead — 0 for a green suite, 65 for a failing one — so it is safe to gate on.
If you extend it, nothing may run between the pipeline and the `PIPESTATUS`
assignment; bash resets the array on the next command.

## Where code goes

**All logic belongs in the `HerdrKit` target.** The app target is the UI entry
point and nothing else. This is not a style preference:

- If the tests used the app as their host, running them would execute the
  startup sequence and spawn a real `herdr server`.
- `HerdrKit` is a static library rather than a framework because embedding a
  framework inside an xctest bundle fails codesigning with
  `bundle format unrecognized`.

So when something in the view turns out to be worth testing, extract it into
`HerdrKit` rather than reaching for UI automation. `MarkedText`,
`ScrollAccumulator` and `CellGeometry` all exist because of that move.

```
Sources/HerdrKit/Protocol/    varint, framing, wire codec, sockets, JSON API
Sources/HerdrKit/Runtime/     locating, spawning and isolating the server;
                              TerminalSession drives the startup sequence
Sources/HerdrKit/Terminal/    grid view, font metrics, glyph cache, block
                              geometry, key map, composition layout
Sources/HerdrKit/Theme/       herdr's 18 built-in palettes
Sources/HerdrKit/Sidebar/     workspace and agent state
Sources/HerdrPrototype/       SwiftUI app, window, sidebar view
```

Swift conventions: no force unwraps or `try!` in production code; views stay
main-actor isolated rather than being worked around; every
`@unchecked Sendable` carries a comment saying why it is safe; a `deinit` on a
main-actor class cannot touch its own stored properties, so move that cleanup
into a small owned object. Comments record measurements, constraints and
rejected alternatives — a comment that restates the code is noise.

## Driving the running app's own server

The embedded server is fully isolated from any herdr session you have open. Its
socket, config and state live under one root, and every inherited `HERDR_*`
variable is stripped before it is spawned — the app is frequently launched from
inside a real herdr session, and an inherited socket path would aim the child at
your own server. `RuntimePaths.environment(basedOn:)` owns this.

To talk to that server from a shell while the app is running:

```bash
R="$HOME/Library/Application Support/dev.herdr.macos-client-prototype/runtime"
export HERDR_SOCKET_PATH="$R/herdr.sock" XDG_CONFIG_HOME="$R/config" XDG_STATE_HOME="$R/state"
env -u HERDR_CLIENT_SOCKET_PATH herdr pane read <pane> --format text
```

`herdr pane read` is the ground truth for what is on screen. It is how you find
out that a logo is quadrant blocks and a progress meter is `U+2591`, rather than
guessing from a rendering bug.

Two things about that directory:

- `config/herdr/config.toml` is **rewritten on every launch** — edit
  `RuntimePaths.configContents(themeName:)` instead. It sets
  `onboarding = false` (otherwise the server sits in `Mode::Onboarding` behind a
  first-run overlay this client cannot dismiss), collapses herdr's own sidebar
  from the first frame, and hides the tab bar.
- `rm -rf "$R"` resets to a clean first launch, including the persisted theme.
  Worth doing before reproducing a startup bug.

Note that only `HERDR_*` is stripped. Everything else in the launching process's
environment reaches the panes, so an agent started inside a pane can see markers
from whatever launched the app. This has surprised people — check the
environment before concluding a pane is misbehaving.

## Verifying rendering and input

This is the part that most often goes wrong by assumption, so it has rules.

**Measure font and glyph facts; do not reason about them.** Advances, glyph
coverage, bounding boxes and fallback resolution are all a few lines of
CoreText. Every geometric claim in this codebase's comments came from a probe,
and several of them contradict what the API names suggest.

**Render offscreen through the real `draw`, not through screenshots.** Build a
`TerminalGridView`, hand it a synthetic `GridFrame`, and render it into an
`NSBitmapImageRep` at a magnification — `TerminalGridViewTests.render(_:)` is
the helper, including the flip a bitmap context needs that a flipped view does
not. Pixel assertions on that are exact. Screenshots are downscaled, which
invents artefacts that are not in the output.

**Do not use GUI keyboard automation.** Raising the right window is unreliable
and the keystrokes land in whatever is frontmost. Construct an `NSEvent` and
call `keyDown(with:)` on the view, as `TerminalGridInputTests` does; that
isolated a real key-swallowing bug in the input-method path that manual testing
did not. Give the event its `characters` — the input context inspects them, so
an event built without them is not answered the way a real one is.

**Build synthetic frames the way the wire does.** A wide character is followed
by an unmarked filler cell, which is an ordinary space. A test that omits the
filler silently shifts every following column and will "pass" against the wrong
layout.

Two invariants worth knowing before you touch the drawing code, both of which
look like bugs and are not:

- **Block elements are geometry; box-drawing lines are glyphs.** The 32 block
  characters are drawn as rectangles snapped to the backing store's pixel grid,
  because a font's block outlines are sized to its em box, not the cell. Box
  glyphs overhang the cell on purpose so neighbours connect. Do not "fix" them.
- **`draw` never mutates state, and passes are ordered.** The frame is walked
  once, cells are sorted into passes, then each pass is drawn as a group:
  backgrounds, block geometry, batched glyphs, decorations, cursor. Adding a
  fifth kind of mark means adding a pass, not a per-cell draw call — per-cell
  drawing measured 45.6 ms for a 140×47 grid against 3.1 ms batched.

## Working on the protocol

`HerdrKit.protocolVersion` is pinned in `Sources/HerdrKit/HerdrKit.swift` and
checked strictly at handshake, with no compatibility shims. When it changes,
change it there and re-verify the affected variants against real bytes.

**Golden fixtures come from bytes observed on the wire, never from reading the
Rust struct and inferring a layout.** The existing fixtures were captured that
way — `WireDecoderTests.twoByOneFramePayload` is assembled byte by byte with a
comment per field — and keeping it that way is what makes a decode failure mean
something.

Three rules that have each already cost a debugging session:

- **`char` is UTF-8 bytes with no length prefix; `String` is a varint length
  plus UTF-8.** They coincide for ASCII and diverge completely above it, so an
  ASCII-only test passes straight over a bug here. Ordinary text goes through
  `TextCommit(String)`, not `Char`.
- **Unknown `ServerMessage` variants are skipped whole; a known variant that
  fails to decode is a hard error.** Framing gives the length, so skipping is
  safe, and the server does send variants this client does not handle. Silently
  tolerating a malformed *known* variant would produce corrupted frames that are
  very hard to trace back.
- **`FrameData::graphics` must be decoded even though nothing renders it.**
  Skipping the field misaligns the rest of the stream.

## When startup fails

`TerminalSession` drives the whole sequence: locate the binary, write the
config, spawn the server, wait for both sockets, connect, handshake, hide
herdr's sidebar, then stream frames. Failures surface as
`TerminalSession.State.failed` with a message, and `HerdrRuntime.Failure` says
which step it was:

| case | what to check |
|---|---|
| `binaryNotFound(searched:)` | the three lookup locations; the message lists them |
| `socketTimeout(missing:seconds:)` | the server started but never bound — read `capturedStderr` |
| `launchFailed(underlying:)` | the binary is not executable, or the wrong architecture |
| `serverExited(status:stderr:)` | usually a config or version problem; the stderr is captured verbatim |

`HerdrRuntime.capturedStderr` accumulates the child's stderr for exactly this
purpose. A handshake rejection means the binary's protocol version is not 19.

## Testing

Everything that can go subtly wrong is a pure unit, which is why the suite needs
no PTY, window or server: `Varint`, `ByteReader`, `Framing`, `WireEncoder`,
`WireDecoder`, `CharWidth`, `CellGeometry`, `MarkedText`, `ScrollAccumulator`,
`TerminalFont` and `KeyMap`. Rendering is covered by drawing synthetic frames
offscreen through the real draw path and asserting on pixels; input by handing
synthetic `NSEvent`s to the view.

Test files are named after the type they cover — `WireDecoderTests`,
`CellGeometryTests` — and all live flat in `Tests/HerdrKitTests/`. Tests that
touch an `NSView` are `@MainActor`, since the view is main-actor isolated and
they need to hand it non-`Sendable` values like fonts.

## Continuous integration

`.github/workflows/build.yml` runs on pushes to `main` and on
`workflow_dispatch` — the latter is there so the workflow itself can be
iterated on without landing commits on `main`. It selects Xcode 26.6, installs
`xcodegen`, generates the project, runs the tests, builds Release, and uploads
the app.

Two details that are easy to undo by accident:

- The test step is the raw `xcodebuild test` with `set -o pipefail` rather than
  `Scripts/test.sh`: it pipes the full output through `xcbeautify`'s
  `github-actions` renderer, so a failure is annotated onto the diff instead of
  being filtered down to the lines the local script keeps.
- The app is archived with `ditto -c -k --sequesterRsrc --keepParent` before
  being uploaded. `actions/upload-artifact` zips its input itself, but loses the
  executable bit and the symlinks inside a `.app`, producing a bundle that will
  not launch.

There is no signing, notarization or release automation, by design — see
Non-goals in the README.

## Commits and docs

Lowercase conventional commits, no emoji, no AI co-author lines. The body
explains why the change is what it is, including the numbers or the failure that
motivated it; `git log` is the reference for the expected depth. Run the tests
before committing.

- [`docs/design.md`](docs/design.md) is the design of record: process model,
  isolation scheme, protocol details, decision record, accepted risks. Two parts
  of it are known stale — the sidebar is now hidden with
  `sidebar_start_collapsed` rather than a one-shot keypress, and the §11 claim
  that per-cell drawing is fast enough was disproved by measurement. Fix them
  when you next touch that file.
- `docs/plan-m*.md` are per milestone and each ends with its acceptance results,
  including the defects acceptance found and their root cause. A new milestone
  gets a new file in that shape.
- `CLAUDE.md` is for agents working in this repo. If you establish a new
  constraint, record it there with the reason, not just in the commit message.
