import Foundation

/// Owns the embedded herdr server process.
///
/// `@unchecked Sendable`: the startup sequence runs on a detached task and
/// captures this object. Mutable state is only the captured stderr, guarded by
/// a lock; `Process` itself is safe to query across threads.
public final class HerdrRuntime: @unchecked Sendable {
    public enum Failure: Error {
        case binaryNotFound(searched: [String])
        case socketTimeout(missing: [String], seconds: TimeInterval)
        case launchFailed(underlying: String)
        case serverExited(status: Int32, stderr: String)
    }

    public let paths: RuntimePaths
    public let binary: URL

    private let process = Process()
    private let errorPipe = Pipe()
    private let errorLock = NSLock()
    private var errorText = ""

    public init(paths: RuntimePaths, binary: URL) {
        self.paths = paths
        self.binary = binary
    }

    /// Search order: bundled copy, then `PATH`, then the conventional
    /// user-local install location.
    public static func defaultCandidates() -> [URL] {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "herdr", withExtension: nil) {
            candidates.append(bundled)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("herdr"))
        }
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/bin/herdr")
        )
        return candidates
    }

    public static func locateBinary(candidates: [URL] = defaultCandidates()) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var capturedStderr: String {
        errorLock.lock()
        defer { errorLock.unlock() }
        return errorText
    }

    public var isRunning: Bool { process.isRunning }

    public func start(themeName: String) throws {
        try paths.writeConfig(themeName: themeName)

        process.executableURL = binary
        process.arguments = ["server"]
        process.environment = paths.environment(basedOn: ProcessInfo.processInfo.environment)
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.errorLock.lock()
            self?.errorText += text
            self?.errorLock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(underlying: String(describing: error))
        }
    }

    /// Polls until both sockets exist. A dead server is reported immediately
    /// with its stderr rather than after the full timeout.
    public func waitForSockets(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let missing = [paths.apiSocket, paths.clientSocket]
                .filter { !FileManager.default.fileExists(atPath: $0.path) }
            if missing.isEmpty { return }

            if process.isRunning == false, process.processIdentifier != 0 {
                throw Failure.serverExited(
                    status: process.terminationStatus,
                    stderr: capturedStderr
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let missing = [paths.apiSocket, paths.clientSocket]
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        throw Failure.socketTimeout(missing: missing, seconds: timeout)
    }

    /// M1 stops the server with SIGTERM. Once M3 adds `ApiClient`, prefer the
    /// `server.stop` API and fall back to this.
    public func stop() {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
