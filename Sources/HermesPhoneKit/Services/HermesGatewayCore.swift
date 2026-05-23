import Foundation
@preconcurrency import Citadel
import NIOCore

enum HermesGatewayError: LocalizedError, Equatable, Sendable {
    case notConnected
    case alreadyRunning
    case timedOut(String)
    case invalidFrame(String)
    case closed
    case remote(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The Hermes gateway is not connected."
        case .alreadyRunning:
            return "The Hermes gateway is already running."
        case .timedOut(let operation):
            return "\(operation) timed out."
        case .invalidFrame(let details):
            return "Received an invalid gateway frame: \(details)"
        case .closed:
            return "The Hermes gateway session closed."
        case .remote(_, let message):
            return message
        }
    }
}

struct HermesChatBootstrapStatus: Equatable, Sendable {
    var sshConnected = false
    var pythonAvailable = false
    var hermesCLIAvailable = false
    var hermesVersion: String?
    var tuiGatewayAvailable = false
    var canUseNativeChat = false
    var fallbackReason: String?
}

struct HermesGatewayEvent: Identifiable, Hashable, Sendable {
    let id = UUID()
    let type: String
    let sessionID: String?
    let payload: [String: JSONValue]
    let rawLine: String?
}

struct HermesGatewayRPCErrorPayload: Codable, Hashable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}

enum HermesGatewayRequestID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported request identifier"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .string(let value):
            return Int(value)
        }
    }
}

private struct HermesGatewayOutgoingRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: JSONValue]
}

private struct HermesGatewayIncomingFrame: Decodable {
    let jsonrpc: String?
    let id: HermesGatewayRequestID?
    let result: JSONValue?
    let error: HermesGatewayRPCErrorPayload?
    let method: String?
    let params: HermesGatewayIncomingEventParams?
}

private struct HermesGatewayIncomingEventParams: Decodable {
    let type: String
    let sessionID: String?
    let payload: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case payload
    }
}

actor HermesGatewayRPCClient {
    typealias Sender = @Sendable (String) async throws -> Void

    nonisolated let events: AsyncStream<HermesGatewayEvent>

    private let eventContinuation: AsyncStream<HermesGatewayEvent>.Continuation
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var sender: Sender?
    private var nextRequestID = 0
    private var readyPayload: [String: JSONValue]?
    private var readyWaiters: [UUID: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private var readyTimeouts: [UUID: Task<Void, Never>] = [:]
    private var pendingRequests: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]
    private var isClosed = false

    init() {
        let stream = AsyncStream<HermesGatewayEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func attachSender(_ sender: @escaping Sender) {
        self.sender = sender
    }

    func awaitReady(timeout: TimeInterval = 12) async throws -> [String: JSONValue] {
        if let readyPayload {
            return readyPayload
        }

        let waiterID = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: JSONValue], Error>) in
            readyWaiters[waiterID] = continuation
            readyTimeouts[waiterID] = Task {
                try? await Task.sleep(nanoseconds: timeout.nanosecondsFromSeconds)
                self.failReadyWaiter(waiterID, error: HermesGatewayError.timedOut("Waiting for gateway.ready"))
            }
        }
    }

    func request(
        method: String,
        params: [String: JSONValue] = [:],
        timeout: TimeInterval = 45
    ) async throws -> JSONValue? {
        guard let sender else {
            throw HermesGatewayError.notConnected
        }
        guard !isClosed else {
            throw HermesGatewayError.closed
        }

        nextRequestID += 1
        let requestID = nextRequestID
        let payload = HermesGatewayOutgoingRequest(id: requestID, method: method, params: params)
        let data = try encoder.encode(payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw HermesGatewayError.invalidFrame("Failed to UTF-8 encode request")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue?, Error>) in
            pendingRequests[requestID] = continuation
            pendingTimeouts[requestID] = Task {
                try? await Task.sleep(nanoseconds: timeout.nanosecondsFromSeconds)
                self.failPendingRequest(
                    requestID,
                    error: HermesGatewayError.timedOut("Gateway request \(method)")
                )
            }

            Task {
                do {
                    try await sender(line)
                } catch {
                    self.failPendingRequest(requestID, error: error)
                }
            }
        }
    }

    func handleStdoutLine(_ line: String) async {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        do {
            let frame = try decoder.decode(HermesGatewayIncomingFrame.self, from: Data(line.utf8))
            if let requestID = frame.id?.intValue {
                pendingTimeouts[requestID]?.cancel()
                pendingTimeouts[requestID] = nil

                guard let continuation = pendingRequests.removeValue(forKey: requestID) else {
                    return
                }

                if let error = frame.error {
                    continuation.resume(throwing: HermesGatewayError.remote(error.code, error.message))
                } else {
                    continuation.resume(returning: frame.result)
                }
                return
            }

            if let method = frame.method, method == "event", let params = frame.params {
                let event = HermesGatewayEvent(
                    type: params.type,
                    sessionID: params.sessionID,
                    payload: params.payload ?? [:],
                    rawLine: line
                )
                if params.type == "gateway.ready" {
                    readyPayload = params.payload ?? [:]
                    completeReadyWaiters(with: readyPayload ?? [:])
                }
                eventContinuation.yield(event)
                return
            }

            eventContinuation.yield(
                HermesGatewayEvent(
                    type: "gateway.unknown_frame",
                    sessionID: nil,
                    payload: ["line": .string(line)],
                    rawLine: line
                )
            )
        } catch {
            eventContinuation.yield(
                HermesGatewayEvent(
                    type: "gateway.parse_error",
                    sessionID: nil,
                    payload: [
                        "line": .string(line),
                        "error": .string(error.localizedDescription)
                    ],
                    rawLine: line
                )
            )
        }
    }

    func handleStderrText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        eventContinuation.yield(
            HermesGatewayEvent(
                type: "gateway.stderr",
                sessionID: nil,
                payload: ["text": .string(trimmed)],
                rawLine: trimmed
            )
        )
    }

    func finish(throwing error: Error? = nil) {
        guard !isClosed else { return }
        isClosed = true

        for (_, timeoutTask) in pendingTimeouts {
            timeoutTask.cancel()
        }
        pendingTimeouts.removeAll()
        for (_, timeoutTask) in readyTimeouts {
            timeoutTask.cancel()
        }
        readyTimeouts.removeAll()

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error ?? HermesGatewayError.closed)
        }
        pendingRequests.removeAll()

        for (_, continuation) in readyWaiters {
            continuation.resume(throwing: error ?? HermesGatewayError.closed)
        }
        readyWaiters.removeAll()

        if let error {
            eventContinuation.yield(
                HermesGatewayEvent(
                    type: "gateway.closed",
                    sessionID: nil,
                    payload: ["error": .string(error.localizedDescription)],
                    rawLine: nil
                )
            )
        } else {
            eventContinuation.yield(
                HermesGatewayEvent(
                    type: "gateway.closed",
                    sessionID: nil,
                    payload: [:],
                    rawLine: nil
                )
            )
        }

        eventContinuation.finish()
    }

    private func completeReadyWaiters(with payload: [String: JSONValue]) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for (key, continuation) in waiters {
            continuation.resume(returning: payload)
            readyTimeouts[key]?.cancel()
            readyTimeouts.removeValue(forKey: key)
        }
    }

    private func failPendingRequest(_ requestID: Int, error: Error) {
        pendingTimeouts[requestID]?.cancel()
        pendingTimeouts[requestID] = nil
        guard let continuation = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failReadyWaiter(_ waiterID: UUID, error: Error) {
        readyTimeouts[waiterID]?.cancel()
        readyTimeouts.removeValue(forKey: waiterID)
        guard let continuation = readyWaiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: error)
    }
}

@available(iOS 17.0, macOS 15.0, *)
actor HermesGatewaySSHSession {
    nonisolated let events: AsyncStream<HermesGatewayEvent>

    private let connection: ConnectionProfile
    private let sshTransport: SSHTransport
    private let gatewayCommand: String
    private let rpcClient: HermesGatewayRPCClient

    private var sshClient: SSHClient?
    private var writer: TTYStdinWriter?
    private var runnerTask: Task<Void, Never>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var stdoutBuffer = ""
    private var isClosed = false

    init(
        connection: ConnectionProfile,
        sshTransport: SSHTransport,
        gatewayCommand: String = "python3 -m tui_gateway.entry"
    ) {
        self.connection = connection
        self.sshTransport = sshTransport
        self.gatewayCommand = gatewayCommand
        let rpcClient = HermesGatewayRPCClient()
        self.rpcClient = rpcClient
        events = rpcClient.events
    }

    func start(timeout: TimeInterval = 12) async throws {
        if runnerTask == nil {
            runnerTask = Task {
                await self.runGatewayLoop()
            }
        }

        await rpcClient.attachSender { line in
            try await self.writeLine(line)
        }

        _ = try await rpcClient.awaitReady(timeout: timeout)
    }

    func request(
        method: String,
        params: [String: JSONValue] = [:],
        timeout: TimeInterval = 45
    ) async throws -> JSONValue? {
        try await rpcClient.request(method: method, params: params, timeout: timeout)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        closeContinuation?.resume()
        closeContinuation = nil

        if let sshClient {
            try? await sshClient.close()
        }
        sshClient = nil
        writer = nil
        runnerTask?.cancel()
        runnerTask = nil
        await rpcClient.finish()
    }

    private func runGatewayLoop() async {
        do {
            let credentialStore = ConnectionSecretsStore()
            guard let credential = try credentialStore.load(for: connection.id) else {
                throw HermesPhoneStoreError.missingCredential
            }

            let client = try await sshTransport.makeClient(connection: connection, credential: credential)
            sshClient = client
            let wrappedCommand = sshTransport.gatewayWrappedCommand(
                for: connection,
                remoteCommand: gatewayCommand
            )

            let performExec: @Sendable (TTYOutput, TTYStdinWriter) async throws -> Void = { inbound, outbound in
                await self.attachWriter(outbound)
                let readerTask = Task {
                    await self.consumeInbound(inbound)
                }
                await self.waitUntilClosed()
                readerTask.cancel()
            }
            try await client.withExec(wrappedCommand, perform: performExec)

            try? await client.close()
            await rpcClient.finish()
        } catch {
            await rpcClient.finish(throwing: error)
        }
    }

    private func attachWriter(_ writer: TTYStdinWriter) {
        self.writer = writer
    }

    private func writeLine(_ line: String) async throws {
        guard let writer else {
            throw HermesGatewayError.notConnected
        }

        var buffer = ByteBuffer()
        buffer.writeString(line)
        buffer.writeString("\n")
        try await writer.write(buffer)
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closeContinuation = continuation
        }
    }

    private func consumeInbound(_ inbound: TTYOutput) async {
        do {
            for try await output in inbound {
                switch output {
                case .stdout(let buffer):
                    await handleStdout(buffer)
                case .stderr(let buffer):
                    await handleStderr(buffer)
                }
            }

            await flushStdoutRemainder()
            await rpcClient.finish()
        } catch {
            await rpcClient.finish(throwing: error)
        }
    }

    private func handleStdout(_ buffer: ByteBuffer) async {
        guard let chunk = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
              !chunk.isEmpty else {
            return
        }

        stdoutBuffer.append(chunk)

        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex ... newlineRange.lowerBound)
            await rpcClient.handleStdoutLine(line)
        }
    }

    private func flushStdoutRemainder() async {
        let remainder = stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        stdoutBuffer.removeAll(keepingCapacity: false)
        guard !remainder.isEmpty else { return }
        await rpcClient.handleStdoutLine(remainder)
    }

    private func handleStderr(_ buffer: ByteBuffer) async {
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
              !text.isEmpty else {
            return
        }
        await rpcClient.handleStderrText(text)
    }
}

extension SSHTransport {
    func probeNativeChatAvailability(on connection: ConnectionProfile) async -> HermesChatBootstrapStatus {
        var status = HermesChatBootstrapStatus()

        do {
            let versionCommand = connection.remoteHermesCommandLine(arguments: ["--version"])
            let probe = try await execute(
                on: connection,
                remoteCommand: """
                printf '__hermes_ssh_ok__=1\\n'
                if command -v python3 >/dev/null 2>&1; then
                  printf '__hermes_python__=1\\n'
                  python3 - <<'PY'
                import importlib.util
                print("__hermes_tui_gateway__=" + ("1" if importlib.util.find_spec("tui_gateway.entry") else "0"))
                PY
                else
                  printf '__hermes_python__=0\\n'
                  printf '__hermes_tui_gateway__=0\\n'
                fi
                hermes_cli_output="$(
                \(versionCommand) 2>&1
                )"
                hermes_cli_status=$?
                hermes_cli_output="$(printf '%s' "$hermes_cli_output" | head -n 1)"
                printf '__hermes_cli_exit__=%s\\n' "$hermes_cli_status"
                printf '__hermes_cli_output__=%s\\n' "$hermes_cli_output"
                """,
                allocateTTY: false
            )

            let outputLines = probe.stdout.components(separatedBy: .newlines)
            func marker(_ key: String) -> String? {
                let prefix = "\(key)="
                return outputLines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }

            status.sshConnected = marker("__hermes_ssh_ok__") == "1"
            status.pythonAvailable = marker("__hermes_python__") == "1"
            status.tuiGatewayAvailable = marker("__hermes_tui_gateway__") == "1"

            if marker("__hermes_cli_exit__") == "0" {
                status.hermesCLIAvailable = true
                let version = marker("__hermes_cli_output__")?.trimmingCharacters(in: .whitespacesAndNewlines)
                status.hermesVersion = version?.isEmpty == false ? version : nil
            }

            if !status.sshConnected, probe.exitCode != 0 {
                status.fallbackReason = describeRemoteFailure(
                    stdout: probe.stdout,
                    stderr: probe.stderr,
                    exitCode: probe.exitCode,
                    connection: connection
                )
                return status
            }
        } catch {
            status.fallbackReason = error.localizedDescription
            return status
        }

        status.canUseNativeChat =
            status.sshConnected &&
            status.pythonAvailable &&
            status.hermesCLIAvailable &&
            status.tuiGatewayAvailable

        if status.fallbackReason == nil && !status.canUseNativeChat {
            if !status.pythonAvailable {
                status.fallbackReason = "python3 is not available on the remote host."
            } else if !status.hermesCLIAvailable {
                status.fallbackReason = "Hermes CLI is not available on the remote host."
            } else if !status.tuiGatewayAvailable {
                status.fallbackReason = "The standard Hermes TUI Gateway is not importable on the remote host."
            }
        }

        return status
    }

    func gatewayWrappedCommand(
        for connection: ConnectionProfile,
        remoteCommand: String
    ) -> String {
        makeWrappedCommand(for: connection, remoteCommand: remoteCommand, standardInput: nil)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "y":
                return true
            case "false", "0", "no", "n":
                return false
            default:
                return nil
            }
        case .int(let value):
            return value != 0
        case .number(let value):
            return value != 0
        default:
            return nil
        }
    }
}

private extension TimeInterval {
    var nanosecondsFromSeconds: UInt64 {
        UInt64((self * 1_000_000_000).rounded())
    }
}
