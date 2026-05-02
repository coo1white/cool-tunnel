// Core/CoreClient.swift
//
// Actor that owns a `cool-tunnel-core` subprocess and provides a typed,
// async/await interface over the newline-delimited JSON wire protocol
// defined in `Core/Protocol.swift`.
//
// Naming follows the Swift API Design Guidelines:
// - `start()` / `stop()` for lifecycle
// - `send(_:)` for request-response calls
// - `events` for an async sequence of unsolicited engine events

import Foundation

/// Errors raised by the `CoreClient` itself (as opposed to errors received
/// over the wire, which surface as `ErrorPayload`).
public enum CoreClientError: Error, Sendable, Equatable {
    /// `start()` was called while the engine was already running.
    case alreadyRunning
    /// A request method was invoked while the engine was stopped.
    case notRunning
    /// The configured executable could not be located or was not executable.
    case executableUnavailable(URL)
    /// The configured executable is not validly code-signed. Treated as
    /// fatal because launching it would defeat the purpose of bundling a
    /// trusted engine in the first place.
    case executableTampered(URL, CodeSignError)
    /// An outbound frame was malformed and could not be decoded.
    case decodingFailed(String)
    /// The engine exited before a pending request completed.
    case engineExited
}

/// Long-lived actor that drives the `cool-tunnel-core` subprocess.
///
/// `CoreClient` is the only place in the Swift app that touches the engine
/// subprocess. UI code talks to a higher-level orchestrator which in turn
/// calls into this actor.
public actor CoreClient {
    /// Filesystem path to the engine binary inside the app bundle.
    public let executableURL: URL

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<CoreResponse, any Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(executableURL: URL) {
        self.executableURL = executableURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Lifecycle

    /// Spawns the engine subprocess and starts reading its stdout.
    ///
    /// Pre-flight checks before launch:
    /// 1. The executable exists and is executable.
    /// 2. The executable is validly code-signed. If anyone has tampered
    ///    with the bundled `cool-tunnel-core` (replaced bytes, stripped the
    ///    signature), this throws `CoreClientError.executableTampered`
    ///    rather than launching attacker-supplied code with our entitlements.
    public func start() async throws {
        guard process == nil else { throw CoreClientError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CoreClientError.executableUnavailable(executableURL)
        }
        do {
            try await CodeSignVerifier.verifyValid(at: executableURL)
        } catch let error as CodeSignError {
            throw CoreClientError.executableTampered(executableURL, error)
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = executableURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        let reader = stdout.fileHandleForReading
        readerTask = Task { [weak self] in
            await self?.readLoop(handle: reader)
        }
    }

    /// Sends a `shutdown` and tears the subprocess down.
    public func stop() async {
        if process != nil {
            _ = try? await sendUnchecked(.shutdown)
        }
        await terminate()
    }

    // MARK: - Requests

    /// Sends one request and awaits the matching reply.
    ///
    /// On the wire this assigns a fresh monotonic `id`, writes a JSON frame
    /// to the engine's stdin, and parks the caller on a continuation until
    /// the engine answers with `Outbound::Response` or `Outbound::Error` for
    /// the same `id`.
    public func send(_ request: CoreRequest) async throws -> CoreResponse {
        guard process != nil else { throw CoreClientError.notRunning }
        return try await sendUnchecked(request)
    }

    private func sendUnchecked(_ request: CoreRequest) async throws -> CoreResponse {
        guard let stdin = stdinHandle else { throw CoreClientError.notRunning }
        let id = nextID
        nextID &+= 1

        let frame = CoreRequestFrame(id: id, request: request)
        var data = try encoder.encode(frame)
        data.append(0x0A)  // newline terminator

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Events

    /// Returns a fresh async stream of unsolicited engine events.
    ///
    /// Each subscriber gets its own backing continuation, so events fan out
    /// to every active stream. Cancelling the iterating task releases the
    /// continuation automatically.
    public func events() -> AsyncStream<CoreEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CoreEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id: id) }
        }
        return stream
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    // MARK: - Reader loop

    private func readLoop(handle: FileHandle) async {
        do {
            for try await line in handle.bytes.lines {
                handleLine(line)
            }
        } catch {
            // Reader closed; fall through to engine-exit cleanup.
        }
        await onEngineExit()
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let frame = try decoder.decode(CoreOutbound.self, from: data)
            dispatch(frame)
        } catch {
            // Malformed frame — log and continue. We never want a single bad
            // line to bring the client down.
            #if DEBUG
            print("CoreClient: failed to decode frame: \(error) — \(line)")
            #endif
        }
    }

    private func dispatch(_ frame: CoreOutbound) {
        switch frame {
        case .response(let id, let result):
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: result)
            }
        case .error(let id, let payload):
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: payload)
            }
        case .event(let event):
            for cont in eventContinuations.values {
                cont.yield(event)
            }
        }
    }

    private func onEngineExit() async {
        let drain = pending
        pending.removeAll()
        for cont in drain.values {
            cont.resume(throwing: CoreClientError.engineExited)
        }
        for cont in eventContinuations.values {
            cont.finish()
        }
        eventContinuations.removeAll()
        readerTask = nil
    }

    private func terminate() async {
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        readerTask?.cancel()
        readerTask = nil
        await onEngineExit()
    }
}
