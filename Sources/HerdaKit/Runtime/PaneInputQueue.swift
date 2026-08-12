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
/// Every kind of input goes through here, not just the API calls. Keys travel
/// over the API and the four unnameable ones over the pane socket, and those are
/// two independent streams — typing "abc", pressing Home, then typing "d" would
/// let Home overtake "abc" if each used its own path. One queue is what makes the
/// order the user typed the order the pane receives.
public final class PaneInputQueue: @unchecked Sendable {
    private let onFailure: (@Sendable (String, Error) -> Void)?
    /// Serial by construction: one queue with no concurrent attribute.
    private let queue = DispatchQueue(label: "app.herda.pane-input")

    public init(onFailure: (@Sendable (String, Error) -> Void)? = nil) {
        self.onFailure = onFailure
    }

    /// Enqueues one send and returns immediately. The caller is the main actor
    /// handling a key event and must never wait on a socket.
    ///
    /// - Parameter label: what is being sent, for the failure report. "input
    ///   failed" without it gives nothing to act on.
    public func submit(_ label: String, _ work: @escaping @Sendable () throws -> Void) {
        queue.async { [onFailure] in
            do {
                try work()
            } catch {
                // Reported and skipped, never rethrown: one rejected key must
                // not wedge every later key in the session.
                onFailure?(label, error)
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
