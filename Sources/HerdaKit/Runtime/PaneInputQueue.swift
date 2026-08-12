import Foundation

/// Serializes input sends, in submission order, one at a time.
///
/// herdr's API is one request per connection — `handle_connection`
/// (`api/server.rs:139`) reads a single line and returns, and only
/// `events.subscribe` and `pane.graphics.stream` take the connection over. So
/// every send opens its own socket, and those sockets all funnel through
/// `api_tx` into the app event queue with no ordering guarantee between them.
/// Overlapping sends can therefore deliver keys out of order, and a scrambled
/// character stream gives almost nothing to trace back from, so ordering is
/// enforced here rather than hoped for.
///
/// The cost is a ceiling of one round trip per key. Measured against the
/// embedded server: `pane.send_keys` is p50 0.16ms and p95 0.38ms, so roughly
/// 6200 keys/sec serialized — three orders of magnitude above human typing. One
/// sample in 200 took 105ms, which is the request crossing the app's main loop
/// while it renders; imperceptible for a single key, but worth knowing before
/// blaming a stall on something else.
public final class PaneInputQueue: @unchecked Sendable {
    private let send: @Sendable (String) throws -> Void
    private let onFailure: (@Sendable (String, Error) -> Void)?
    /// Serial by construction: one queue with no concurrent attribute.
    private let queue = DispatchQueue(label: "app.herda.pane-input")

    public init(
        onFailure: (@Sendable (String, Error) -> Void)? = nil,
        send: @escaping @Sendable (String) throws -> Void
    ) {
        self.send = send
        self.onFailure = onFailure
    }

    /// Enqueues one payload and returns immediately. The caller is the main
    /// actor handling a key event and must never wait on a socket.
    public func submit(_ payload: String) {
        queue.async { [send, onFailure] in
            do {
                try send(payload)
            } catch {
                // Reported and skipped, never rethrown: one rejected key must
                // not wedge every later key in the session. The payload goes
                // with it, because "input failed" without the key name gives
                // nothing to act on.
                onFailure?(payload, error)
            }
        }
    }

    /// Waits for everything submitted so far. Tests only — nothing in the app
    /// blocks on input.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
