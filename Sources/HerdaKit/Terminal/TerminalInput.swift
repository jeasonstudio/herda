import Foundation

/// What the terminal view wants sent, before anything decides where it goes or
/// how it is encoded.
///
/// The view used to hand out finished `InputEvents` bytes. Those cannot be sent
/// on a per-pane connection: `ClientInputEvents` has no early return for
/// `TerminalAttach` (`headless.rs:2893`), so it reaches
/// `promote_client_to_foreground`, which has no guard (`:1460`). The server then
/// sets `effective_size` to that one pane's size and relays out every pane
/// inside it. The symptom is global — all panes deform at once — and gives no
/// way back to the keypress that caused it.
///
/// Reporting intent keeps the routing decision with the session, which is the
/// only place that knows which pane is focused and which channel a given key
/// can travel on. See `HerdrKeyName` and `TerminalKeyBytes` for that split.
public enum TerminalInput: Equatable, Sendable {
    public enum TextKind: Equatable, Sendable {
        /// Committed by the input method.
        case commit
        /// Pasted from the host pasteboard.
        case paste
    }

    case key(WireEncoder.Key, WireEncoder.Modifiers)
    case text(String, kind: TextKind)
    case mouse(WireEncoder.MouseKind, column: UInt16, row: UInt16, WireEncoder.Modifiers)
    case focus(gained: Bool)

    /// The `InputEvents` payload this intent used to be emitted as.
    ///
    /// Valid only on a full app connection. Kept so the outlet refactor changes
    /// no bytes; the switchover to per-pane connections replaces the call sites
    /// rather than this method.
    public func appInputEventsPayload() -> [UInt8] {
        switch self {
        case .key(let key, let modifiers):
            return WireEncoder.key(key, modifiers: modifiers)
        case .text(let value, .commit):
            return WireEncoder.textCommit(value)
        case .text(let value, .paste):
            return WireEncoder.paste(value)
        case .mouse(let kind, let column, let row, let modifiers):
            return WireEncoder.mouse(kind, column: column, row: row, modifiers: modifiers)
        case .focus(let gained):
            return WireEncoder.focus(gained: gained)
        }
    }
}
