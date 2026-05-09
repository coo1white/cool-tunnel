// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
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
import os

/// Errors raised by `CoreClient` itself, distinct from errors received
/// over the wire (which surface as `ErrorPayload`).
///
/// **Conforms to `LocalizedError`** so the
/// `(error as? LocalizedError)?.errorDescription` cast at user-
/// facing catch sites surfaces the strings below rather than
/// Swift's default `"…CoolTunnel.CoreClientError error N."`
/// placeholder. Per-type round-3 review fix.
public enum CoreClientError: LocalizedError, Sendable, Equatable {
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
    /// The engine accepted the request but did not produce a
    /// response within the per-request deadline. Surfaced as a
    /// real error so the UI can recover instead of waiting on a
    /// silent hang.
    case requestTimeout
    /// The engine reported a wire-protocol version that this Swift
    /// build does not understand. Carries the engine's reported
    /// version so the UI can render a precise diagnostic ("expected
    /// v1, engine reports v2 — please update the app") rather than
    /// a generic decoding error. Raised from `start()` after the
    /// `hello` handshake; `start()` terminates the subprocess
    /// before throwing so a stale engine never lingers behind a
    /// failed launch.
    case protocolVersionMismatch(expected: UInt32, engine: UInt32, engineVersion: String)
    /// The engine answered the `hello` handshake with an
    /// unexpected response shape. Either the engine is broken or
    /// (much more likely) the user pointed `customRustCorePath`
    /// at a non-`cool-tunnel-core` binary and the JSON decoder
    /// happened to limp through far enough to land here. Raised
    /// from `start()`; the subprocess is torn down before the
    /// throw.
    case malformedHandshake

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The Cool Tunnel engine is already running."
        case .notRunning:
            "The Cool Tunnel engine is not running."
        case .executableUnavailable(let url):
            "Cool Tunnel could not find the engine binary '\(url.lastPathComponent)'."
        case .executableTampered(let url, let err):
            "The engine binary '\(url.lastPathComponent)' failed code-signature "
                + "verification. \(err.errorDescription ?? "Reinstall Cool Tunnel.")"
        case .decodingFailed:
            "The engine sent an unexpected response. Try restarting Cool Tunnel."
        case .engineExited:
            "The Cool Tunnel engine exited unexpectedly. Try Start again."
        case .requestTimeout:
            "The engine did not respond within the request deadline."
        case .protocolVersionMismatch(let expected, let engine, _):
            "Cool Tunnel speaks engine protocol v\(expected) but the bundled "
                + "engine reports v\(engine). Update the app."
        case .malformedHandshake:
            "The engine binary did not recognise the Cool Tunnel handshake. "
                + "If you set a custom engine path, verify it points at "
                + "`cool-tunnel-core`."
        }
    }
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
    private var stderrHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    /// Set true at the entry of `start()` and reset on failure or
    /// successful handshake. Without this, two concurrent callers
    /// could both pass the `process == nil` guard before the
    /// first one's `await CodeSignVerifier.verifyValid(...)`
    /// returns, and both would reach `process.run()`. Actor
    /// reentrancy across `await` defeats the simple null-check.
    private var starting: Bool = false
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<CoreResponse, any Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var didPublishEngineExit: Bool = false

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
        // Mark the actor as mid-start *before* the first `await`
        // so a concurrent caller landing on the actor while
        // `verifyValid` is in flight sees `starting == true` and
        // bails with `alreadyRunning`. Without this, both callers
        // would pass `process == nil`, both would await
        // verification, and both would reach `process.run()`.
        guard !starting else { throw CoreClientError.alreadyRunning }
        starting = true
        defer { starting = false }

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
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
        self.didPublishEngineExit = false

        let reader = stdout.fileHandleForReading
        readerTask = Task { [weak self] in
            await self?.readLoop(handle: reader)
        }

        // **Subproc-F#11a (v0.1.7.19):** drain stderr on its own
        // task. Without this, a chatty engine writing >64 KiB to
        // stderr fills the kernel pipe buffer, blocks on its next
        // stderr write, and the engine deadlocks mid-request. The
        // drain doesn't structure the bytes (engine errors that
        // need user surface go through the JSON-over-stdout
        // protocol, not stderr), but it prevents the deadlock and
        // forwards content to tracing for support diagnosis.
        //
        // **v2.0.22 (post-#17 round-1 review):** Task stored in
        // actor state so `terminate()` can wind it down. The
        // previous `Task.detached` was unreachable and could
        // outlive its parent across a rapid-restart sequence.
        //
        // **v2.0.22 (post-#17 round-2 review):** switched the read
        // primitive from `availableData` to `read(upToCount:)`.
        // `Pipe.fileHandleForReading` is a stored property — both
        // `self.stderrHandle` and the previously-locally-bound
        // `drainHandle` referenced the *same* `FileHandle`, so the
        // close-handle-then-cancel plan in `terminate()` would
        // close the FD out from under a parked `availableData`
        // call and the loop body's next iteration would invoke
        // `availableData` on a closed FD, raising an Objective-C
        // `NSFileHandleOperationException` that Swift `try` cannot
        // catch and that would unwind the worker thread. Throwing
        // `read(upToCount:)` returns `nil` on EOF, throws a Swift
        // error on a closed handle, and lets us bail cleanly via
        // the `do/catch` below. (`read(upToCount:)` is macOS
        // 10.15.4+; project minimum is 14.0.)
        stderrTask = Task.detached(priority: .utility) { [stderrHandle = self.stderrHandle] in
            while !Task.isCancelled {
                do {
                    guard let chunk = try stderrHandle?.read(upToCount: 4096),
                        !chunk.isEmpty
                    else {
                        break  // EOF or handle gone
                    }
                    if let line = String(data: chunk, encoding: .utf8),
                        !line.isEmpty
                    {
                        Self.engineStderrLogger.warning(
                            "engine stderr: \(line, privacy: .private)"
                        )
                    }
                } catch {
                    // Closed handle (terminate raced us) or other
                    // I/O error. Either way the engine is going
                    // away; drop out of the loop quietly.
                    break
                }
            }
        }

        // Wire-protocol handshake. Block the rest of `start()` on
        // it so a hard version mismatch tears the subprocess down
        // before any caller sends `validate_profile` or
        // `start_proxy` against an engine speaking a foreign
        // dialect — the historical failure mode there was a flurry
        // of `invalid_request` decode errors that gave the user no
        // hint about the real cause. An engine older than v2.0.20
        // (which doesn't implement `hello`) returns
        // `invalid_request` for the unknown method; we treat that
        // as legacy compatibility and continue without complaint.
        try await performHandshake()
    }

    /// Sends the `hello` handshake and validates the engine's
    /// reply. On a hard version mismatch (or a malformed reply),
    /// terminates the subprocess and throws — `start()` then
    /// surfaces the throw to the caller and the engine never
    /// outlives a failed launch.
    private func performHandshake() async throws {
        let response: CoreResponse
        do {
            response = try await sendUnchecked(.hello)
        } catch let error as ErrorPayload
            where error.code == "invalid_request"
            || error.code == "unimplemented_method"
        {
            // Engine predates the handshake. The historical
            // behaviour is what it implements; the Swift caller
            // routes around the missing version negotiation by
            // accepting whatever the engine produces. Log so a
            // support ticket can correlate "user is on a stale
            // engine" with later weirdness, but do not fail.
            Self.logger.notice(
                "engine does not implement hello handshake; treating as legacy (protocol_version=0)"
            )
            return
        } catch {
            // Anything else — transport timeout, decode failure,
            // engine crash — is fatal. Tear down before re-throwing
            // so the subprocess doesn't outlive the failed start.
            await terminate()
            throw error
        }

        guard case .helloReply(let engineVersion, let engineSemver) = response else {
            // The engine answered `hello` with something other
            // than `helloReply`. Almost certainly a non-
            // `cool-tunnel-core` binary at the resolved path.
            await terminate()
            throw CoreClientError.malformedHandshake
        }

        if engineVersion != coreProtocolVersion {
            await terminate()
            throw CoreClientError.protocolVersionMismatch(
                expected: coreProtocolVersion,
                engine: engineVersion,
                engineVersion: engineSemver
            )
        }

        Self.logger.info(
            "engine handshake ok: protocol=\(engineVersion, privacy: .public) engine=\(engineSemver, privacy: .public)"
        )
    }

    /// **Subproc-F#11a (v0.1.7.19):** dedicated logger for
    /// engine stderr output. Subsystem matches the project-wide
    /// convention so support's `log show` predicates surface
    /// engine diagnostics under one umbrella.
    private static let engineStderrLogger = Logger.cooltunnel("CoreClient.stderr")

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
    /// Per-request hard deadline. The engine typically replies in
    /// single-digit ms; nothing legitimate takes minutes. If a
    /// future engine bug, GCD starvation, or signal-blocked syscall
    /// stalls a response, the UI sees a real `requestTimeout`
    /// error and can recover instead of an infinite spinner whose
    /// only escape is Force Quit (which strands the system proxy).
    private static let requestTimeoutNanos: UInt64 = 120_000_000_000

    public func send(_ request: CoreRequest) async throws -> CoreResponse {
        guard process != nil else { throw CoreClientError.notRunning }
        return try await sendUnchecked(request)
    }

    /// Pre-flight reachability probe against the upstream server in
    /// `profile`. Resolves DNS and opens a TCP connection; does not
    /// run a TLS handshake or auth check (those continue to live in
    /// `runDiagnostics`, which requires a live proxy).
    ///
    /// `timeoutSecs` is the per-step deadline in seconds, clamped
    /// engine-side to `[1, 30]`. `nil` defaults to 5.
    ///
    /// The probe always resolves to a `ProbeReport` — including for
    /// unreachable servers — so the UI can render timing alongside
    /// failures rather than catching transport-error exceptions.
    /// Throws only when the engine itself fails to start the probe
    /// (a `probe_failed` error frame from the engine, decoded into
    /// an `ErrorPayload`).
    public func probe(
        profile: Profile,
        timeoutSecs: UInt64? = nil
    ) async throws -> ProbeReport {
        let response = try await send(.probeServer(profile: profile, timeoutSecs: timeoutSecs))
        guard case .probe(let report) = response else {
            throw CoreClientError.decodingFailed(
                "expected probe response, got \(response)"
            )
        }
        return report
    }

    private func sendUnchecked(_ request: CoreRequest) async throws -> CoreResponse {
        guard let stdin = stdinHandle else { throw CoreClientError.notRunning }
        let id = nextID
        nextID &+= 1

        let frame = CoreRequestFrame(id: id, request: request)
        var data = try encoder.encode(frame)
        data.append(0x0A)  // newline terminator

        // Schedule a per-request timeout that resumes the
        // continuation directly (and removes it from `pending` so
        // a late dispatch doesn't double-resume). The Task is
        // cancelled in `defer` if the response arrives in time.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.requestTimeoutNanos)
            guard !Task.isCancelled else { return }
            await self?.expirePending(id: id)
        }
        defer { timeoutTask.cancel() }

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

    /// Called by the per-request timeout Task when the deadline
    /// expires. If the continuation is still in `pending`, fail it
    /// with `requestTimeout`; otherwise the response already
    /// landed and we no-op.
    private func expirePending(id: UInt64) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CoreClientError.requestTimeout)
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
            var frame = Data()
            for try await byte in handle.bytes {
                if Task.isCancelled { break }
                if byte == Self.newlineByte {
                    if !frame.isEmpty {
                        handleFrame(frame)
                        frame.removeAll(keepingCapacity: true)
                    }
                } else if frame.count < Self.maxOutboundFrameBytes {
                    frame.append(byte)
                } else {
                    frame.removeAll(keepingCapacity: true)
                    Self.logger.error(
                        "dropping oversized engine frame (> \(Self.maxOutboundFrameBytes, privacy: .public) bytes)"
                    )
                }
            }
            if !frame.isEmpty {
                handleFrame(frame)
            }
        } catch {
            // Reader closed; fall through to engine-exit cleanup.
        }
        try? handle.close()
        await onEngineExit()
    }

    private static let maxOutboundFrameBytes = 1024 * 1024
    private static let newlineByte: UInt8 = 0x0A

    private func handleFrame(_ data: Data) {
        autoreleasepool {
            decodeAndDispatchFrame(data)
        }
    }

    private func decodeAndDispatchFrame(_ data: Data) {
        do {
            let frame = try decoder.decode(CoreOutbound.self, from: data)
            dispatch(frame)
        } catch {
            // Malformed frame — log and continue. We never want a
            // single bad line to bring the client down. v0.1.5.9
            // audit fix: routes through `os.Logger` (always-on,
            // structured, redacted-by-default) instead of a
            // DEBUG-gated `print()` that disappeared in Release. A
            // malformed frame is diagnostic, not noisy — surfacing
            // it in `log show --predicate 'subsystem == ...'`
            // beats hoping a developer happened to be in DEBUG.
            Self.logger.error(
                "failed to decode frame: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Subsystem-scoped logger for the JSON-over-stdio frame pump.
    /// **R-F#1 (v0.1.7.14):** routed through
    /// `Logger.cooltunnel(_:)` so the project-wide subsystem
    /// string lives in one place across CoreClient, AppUpdater,
    /// and GitHubTrust.
    private static let logger = Logger.cooltunnel("CoreClient")

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
        guard !didPublishEngineExit else { return }
        didPublishEngineExit = true
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
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        stderrTask?.cancel()
        stderrTask = nil
    }

    private func terminate() async {
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        try? stdoutHandle?.close()
        stdoutHandle = nil
        // Closing the stderr handle causes the drain loop's
        // pending `read(upToCount:)` to throw a Swift error (or
        // return nil at EOF), so the loop exits cleanly even if
        // cancellation hasn't been observed yet. Closing first,
        // then cancelling, mirrors how `readerTask` is wound down
        // via stdout EOF + cancel.
        try? stderrHandle?.close()
        stderrHandle = nil
        process = nil
        readerTask?.cancel()
        readerTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        await onEngineExit()
    }
}
