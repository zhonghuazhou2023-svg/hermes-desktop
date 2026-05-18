#if canImport(UIKit)
import Foundation
import SwiftUI

enum HermesChatMessageRole: String, Sendable {
    case user
    case assistant
    case system
    case error
}

struct HermesChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    var role: HermesChatMessageRole
    var text: String
    var timestamp: Date
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: HermesChatMessageRole,
        text: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}

struct HermesChatToolCard: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var status: String
    var detail: String?
    var isRunning: Bool
    var updatedAt: Date
}

enum HermesChatPromptKind: String, Sendable {
    case approval
    case clarify
    case sudo
    case secret
}

struct HermesChatPromptCard: Identifiable, Hashable, Sendable {
    let id: String
    let sessionID: String?
    let requestID: String
    let kind: HermesChatPromptKind
    var title: String
    var message: String
    var choices: [String]
    var placeholder: String?
}

@MainActor
final class HermesNativeChatStore: ObservableObject {
    @Published var bootstrapStatus: HermesChatBootstrapStatus?
    @Published var connectionStatus = "Idle"
    @Published var sessionStatus = "No active chat session"
    @Published var currentSessionID: String?
    @Published var messages: [HermesChatMessage] = []
    @Published var toolCards: [HermesChatToolCard] = []
    @Published var promptCards: [HermesChatPromptCard] = []
    @Published var diagnostics: [String] = []
    @Published var rawEvents: [HermesGatewayEvent] = []
    @Published var draftMessage = ""
    @Published var lastError: String?
    @Published var showDiagnostics = false
    @Published var gatewayInfo: [String: String] = [:]
    @Published var isConnecting = false
    @Published var isPerformingRequest = false
    @Published private(set) var pendingResumeRequestID: UUID?

    weak var phoneStore: HermesPhoneStore?

    private let sshTransport: SSHTransport
    private var gatewaySession: HermesGatewaySSHSession?
    private var eventTask: Task<Void, Never>?
    private var activeConnectionFingerprint: String?
    private var currentAssistantMessageID: UUID?
    private var pendingResumeSession: SessionSummary?

    init(phoneStore: HermesPhoneStore, sshTransport: SSHTransport) {
        self.phoneStore = phoneStore
        self.sshTransport = sshTransport
    }

    var canUseNativeChat: Bool {
        bootstrapStatus?.canUseNativeChat == true
    }

    var fallbackReason: String? {
        bootstrapStatus?.fallbackReason
    }

    var hasConversationContent: Bool {
        currentSessionID != nil || !messages.isEmpty || !toolCards.isEmpty || !promptCards.isEmpty
    }

    var latestToolCard: HermesChatToolCard? {
        toolCards.max(by: { $0.updatedAt < $1.updatedAt })
    }

    func prepareNewChat() {
        pendingResumeSession = nil
        pendingResumeRequestID = nil
        clearConversationState(keepDiagnostics: true)
        sessionStatus = "Ready to start a new chat"
        if gatewaySession == nil {
            connectionStatus = phoneStore?.activeConnection == nil ? "No active SSH connection" : "Idle"
        }
    }

    func syncWithActiveConnection() async {
        let fingerprint = phoneStore?.activeWorkspaceScopeFingerprint
        guard fingerprint != activeConnectionFingerprint else { return }

        await disconnectFromGateway(resetMessages: true)
        bootstrapStatus = nil
        gatewayInfo = [:]
        currentSessionID = nil
        activeConnectionFingerprint = fingerprint
        connectionStatus = fingerprint == nil ? "No active SSH connection" : "Idle"
        sessionStatus = "No active chat session"
        lastError = nil
    }

    func refreshBootstrapStatus(force: Bool = false) async {
        guard force || bootstrapStatus == nil else { return }
        guard let connection = phoneStore?.activeConnection else {
            bootstrapStatus = HermesChatBootstrapStatus(
                sshConnected: false,
                pythonAvailable: false,
                hermesCLIAvailable: false,
                hermesVersion: nil,
                tuiGatewayAvailable: false,
                canUseNativeChat: false,
                fallbackReason: "Choose a saved connection before opening Chat."
            )
            connectionStatus = "No active SSH connection"
            return
        }

        connectionStatus = "Checking remote Hermes environment..."
        let status = await sshTransport.probeNativeChatAvailability(on: connection)
        bootstrapStatus = status

        if status.canUseNativeChat {
            connectionStatus = "Ready for native chat"
            if let version = status.hermesVersion, !version.isEmpty {
                gatewayInfo["Hermes"] = version
            }
        } else {
            connectionStatus = "Native chat unavailable"
        }
    }

    func startChat() async {
        await ensureGatewaySession()
        guard gatewaySession != nil else { return }
        guard currentSessionID == nil else { return }
        await createSession()
    }

    func createSession() async {
        guard let session = gatewaySession else {
            await ensureGatewaySession()
            guard let session = gatewaySession else { return }
            await createSession(using: session)
            return
        }

        await createSession(using: session)
    }

    func continueSession(_ summary: SessionSummary) async {
        await ensureGatewaySession()
        guard let session = gatewaySession else { return }

        clearConversationState(keepDiagnostics: true)
        sessionStatus = "Resuming \(summary.resolvedTitle)..."

        do {
            let result = try await session.request(
                method: "session.resume",
                params: [
                    "session_id": .string(summary.id),
                    "id": .string(summary.id)
                ],
                timeout: 60
            )
            applySessionResult(result, preferredSessionID: summary.id)

            if messages.isEmpty, let gatewaySessionID = currentSessionID {
                let history = try await session.request(
                    method: "session.history",
                    params: [
                        "session_id": .string(gatewaySessionID),
                        "id": .string(gatewaySessionID)
                    ],
                    timeout: 60
                )
                applyHistoryResult(history)
            }

            sessionStatus = "Chat resumed"
        } catch {
            present(error)
        }
    }

    func queueResumeSession(_ summary: SessionSummary) {
        pendingResumeSession = summary
        pendingResumeRequestID = UUID()
    }

    func performPendingResumeIfNeeded() async {
        guard let summary = pendingResumeSession else { return }
        pendingResumeSession = nil
        await continueSession(summary)
    }

    func sendCurrentDraft() async {
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draftMessage = ""

        await ensureGatewaySession()
        if currentSessionID == nil {
            await createSession()
        }
        guard let session = gatewaySession, let currentSessionID else { return }

        messages.append(HermesChatMessage(role: .user, text: message))
        sessionStatus = "Sending prompt..."

        do {
            isPerformingRequest = true
            defer { isPerformingRequest = false }

            _ = try await session.request(
                method: "prompt.submit",
                params: [
                    "session_id": .string(currentSessionID),
                    "text": .string(message)
                ],
                timeout: 120
            )
        } catch {
            present(error)
        }
    }

    func runChatTest() async -> String {
        if draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftMessage = "Hello Hermes, this is the HermesPhone native chat test."
        }
        await sendCurrentDraft()
        return lastError ?? "Chat test sent. Follow the live response below."
    }

    func interrupt() async {
        guard let session = gatewaySession, let currentSessionID else { return }
        do {
            sessionStatus = "Interrupting..."
            _ = try await session.request(
                method: "session.interrupt",
                params: ["session_id": .string(currentSessionID)],
                timeout: 20
            )
            sessionStatus = "Interrupt requested"
        } catch {
            present(error)
        }
    }

    func closeChat() async {
        if let session = gatewaySession, let currentSessionID {
            do {
                _ = try await session.request(
                    method: "session.close",
                    params: ["session_id": .string(currentSessionID)],
                    timeout: 20
                )
            } catch {
                appendDiagnostic("session.close failed: \(error.localizedDescription)")
            }
        }

        await disconnectFromGateway(resetMessages: false)
        currentSessionID = nil
        currentAssistantMessageID = nil
        sessionStatus = "Chat closed"
    }

    func openTerminal() {
        phoneStore?.ensureTerminalConnected()
    }

    func respondToPrompt(
        _ card: HermesChatPromptCard,
        approved: Bool? = nil,
        responseText: String? = nil
    ) async {
        guard let session = gatewaySession else { return }

        let method: String
        var params: [String: JSONValue] = [
            "request_id": .string(card.requestID)
        ]
        if let sessionID = card.sessionID ?? currentSessionID {
            params["session_id"] = .string(sessionID)
        }

        switch card.kind {
        case .approval:
            method = "approval.respond"
            let allowed = approved ?? false
            params["choice"] = .string(allowed ? "approve" : "deny")
        case .clarify:
            method = "clarify.respond"
            let value = responseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            params["answer"] = .string(value)
        case .sudo:
            method = "sudo.respond"
            let value = responseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            params["password"] = .string(value)
        case .secret:
            method = "secret.respond"
            let value = responseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            params["value"] = .string(value)
        }

        do {
            _ = try await session.request(method: method, params: params, timeout: 45)
            promptCards.removeAll { $0.id == card.id }
            sessionStatus = "Reply sent"
        } catch {
            present(error)
        }
    }

    private func createSession(using session: HermesGatewaySSHSession) async {
        clearConversationState(keepDiagnostics: true)
        sessionStatus = "Creating chat session..."

        do {
            let result = try await session.request(
                method: "session.create",
                params: [
                    "client": .string("HermesPhone"),
                    "source": .string("ios"),
                    "ui": .string("native")
                ],
                timeout: 60
            )
            applySessionResult(result, preferredSessionID: nil)
            sessionStatus = "Chat session ready"
        } catch {
            present(error)
        }
    }

    private func ensureGatewaySession() async {
        guard !isConnecting else { return }
        await syncWithActiveConnection()
        await refreshBootstrapStatus()

        guard canUseNativeChat else {
            connectionStatus = "Native chat unavailable"
            return
        }
        guard gatewaySession == nil else { return }
        guard let connection = phoneStore?.activeConnection else { return }

        isConnecting = true
        defer { isConnecting = false }

        connectionStatus = "Connecting to Hermes gateway..."
        let session = HermesGatewaySSHSession(connection: connection, sshTransport: sshTransport)
        gatewaySession = session
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in session.events {
                await self.apply(event)
            }
        }

        do {
            try await session.start()
            connectionStatus = "Gateway connected"
            appendDiagnostic("Gateway started successfully.")
        } catch {
            present(error)
            await disconnectFromGateway(resetMessages: false)
        }
    }

    private func disconnectFromGateway(resetMessages: Bool) async {
        eventTask?.cancel()
        eventTask = nil

        if let gatewaySession {
            await gatewaySession.close()
        }
        gatewaySession = nil

        if resetMessages {
            clearConversationState(keepDiagnostics: false)
        }

        connectionStatus = "Idle"
    }

    private func clearConversationState(keepDiagnostics: Bool) {
        currentSessionID = nil
        currentAssistantMessageID = nil
        messages = []
        toolCards = []
        promptCards = []
        rawEvents = []
        lastError = nil
        if !keepDiagnostics {
            diagnostics = []
        }
    }

    private func apply(_ event: HermesGatewayEvent) async {
        rawEvents.append(event)
        if rawEvents.count > 120 {
            rawEvents.removeFirst(rawEvents.count - 120)
        }

        switch event.type {
        case "gateway.ready":
            connectionStatus = "Gateway ready"
            if let skin = value(in: event.payload, keys: ["skin", "name"]) {
                gatewayInfo["Skin"] = skin
            }
        case "session.info":
            if let sessionID = event.sessionID ?? value(in: event.payload, keys: ["session_id", "id"]) {
                currentSessionID = sessionID
            }
            if let model = value(in: event.payload, keys: ["model"]) {
                gatewayInfo["Model"] = model
            }
            if let version = value(in: event.payload, keys: ["version", "gateway_version"]) {
                gatewayInfo["Gateway"] = version
            }
        case "message.start":
            startAssistantMessage(with: event.payload)
        case "message.delta":
            appendAssistantDelta(from: event.payload)
        case "message.complete":
            completeAssistantMessage(from: event.payload)
        case "tool.start":
            updateToolCard(for: event.payload, defaultRunning: true)
        case "tool.progress":
            updateToolCard(for: event.payload, defaultRunning: true)
        case "tool.complete":
            updateToolCard(for: event.payload, defaultRunning: false)
        case "approval.request":
            upsertPromptCard(kind: .approval, payload: event.payload, fallbackSessionID: event.sessionID)
        case "clarify.request":
            upsertPromptCard(kind: .clarify, payload: event.payload, fallbackSessionID: event.sessionID)
        case "sudo.request":
            upsertPromptCard(kind: .sudo, payload: event.payload, fallbackSessionID: event.sessionID)
        case "secret.request":
            upsertPromptCard(kind: .secret, payload: event.payload, fallbackSessionID: event.sessionID)
        case "status.update":
            sessionStatus = value(in: event.payload, keys: ["text", "status", "message"]) ?? sessionStatus
        case "error":
            let message = value(in: event.payload, keys: ["message", "error"]) ?? "Unknown gateway error"
            lastError = message
            messages.append(HermesChatMessage(role: .error, text: message))
        case "gateway.stderr":
            if let line = value(in: event.payload, keys: ["text"]) {
                appendDiagnostic(line)
            }
        case "gateway.closed":
            connectionStatus = "Gateway closed"
        default:
            break
        }
    }

    private func startAssistantMessage(with payload: [String: JSONValue]) {
        let initialText = value(in: payload, keys: ["text", "delta", "content"]) ?? ""
        let messageID = UUID()
        currentAssistantMessageID = messageID
        messages.append(
            HermesChatMessage(
                id: messageID,
                role: .assistant,
                text: initialText,
                isStreaming: true
            )
        )
        sessionStatus = "Hermes is responding..."
    }

    private func appendAssistantDelta(from payload: [String: JSONValue]) {
        let delta = value(in: payload, keys: ["text", "delta", "content"]) ?? ""
        guard !delta.isEmpty else { return }

        if currentAssistantMessageID == nil {
            startAssistantMessage(with: payload)
            return
        }

        guard let messageID = currentAssistantMessageID,
              let index = messages.lastIndex(where: { $0.id == messageID }) else {
            return
        }

        messages[index].text.append(delta)
        messages[index].isStreaming = true
    }

    private func completeAssistantMessage(from payload: [String: JSONValue]) {
        if currentAssistantMessageID == nil {
            startAssistantMessage(with: payload)
        }

        if let messageID = currentAssistantMessageID,
           let index = messages.lastIndex(where: { $0.id == messageID }) {
            let trailingText = value(in: payload, keys: ["text", "content"])
            if let trailingText, messages[index].text.isEmpty {
                messages[index].text = trailingText
            }
            messages[index].isStreaming = false
        }

        currentAssistantMessageID = nil
        sessionStatus = "Response completed"
    }

    private func updateToolCard(for payload: [String: JSONValue], defaultRunning: Bool) {
        let toolID = value(in: payload, keys: ["tool_call_id", "id", "tool_id", "name"]) ?? UUID().uuidString
        let title = value(in: payload, keys: ["title", "name", "tool"]) ?? "Tool activity"
        let status = value(in: payload, keys: ["status", "message", "state"]) ?? (defaultRunning ? "Running" : "Complete")
        let detail = value(in: payload, keys: ["detail", "summary", "output"])
        let isRunning = payload["running"]?.boolValue ?? defaultRunning
        let updatedAt = Date()

        if let index = toolCards.firstIndex(where: { $0.id == toolID }) {
            toolCards[index].title = title
            toolCards[index].status = status
            toolCards[index].detail = detail
            toolCards[index].isRunning = isRunning
            toolCards[index].updatedAt = updatedAt
        } else {
            toolCards.append(
                HermesChatToolCard(
                    id: toolID,
                    title: title,
                    status: status,
                    detail: detail,
                    isRunning: isRunning,
                    updatedAt: updatedAt
                )
            )
        }

        if toolCards.count > 12 {
            toolCards.removeFirst(toolCards.count - 12)
        }
    }

    private func upsertPromptCard(
        kind: HermesChatPromptKind,
        payload: [String: JSONValue],
        fallbackSessionID: String?
    ) {
        let requestID = value(in: payload, keys: ["request_id", "id", "approval_id"]) ?? UUID().uuidString
        let title = value(in: payload, keys: ["title", "prompt", "kind"]) ?? kind.rawValue.capitalized
        let message = value(in: payload, keys: ["message", "text", "body"]) ?? ""
        let sessionID = value(in: payload, keys: ["session_id"]) ?? fallbackSessionID
        let choices = payload["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let placeholder = value(in: payload, keys: ["placeholder", "hint"])

        let card = HermesChatPromptCard(
            id: "\(kind.rawValue)-\(requestID)",
            sessionID: sessionID,
            requestID: requestID,
            kind: kind,
            title: title,
            message: message,
            choices: choices,
            placeholder: placeholder
        )

        if let index = promptCards.firstIndex(where: { $0.id == card.id }) {
            promptCards[index] = card
        } else {
            promptCards.append(card)
        }
    }

    private func applySessionResult(_ result: JSONValue?, preferredSessionID: String?) {
        guard let object = result?.objectValue else {
            if let preferredSessionID {
                currentSessionID = preferredSessionID
            }
            return
        }

        currentSessionID = value(in: object, keys: ["session_id", "id"]) ?? preferredSessionID ?? currentSessionID

        if let messagesValue = object["messages"] ?? object["history"] {
            applyHistoryResult(messagesValue)
        }

        if let model = value(in: object, keys: ["model"]) {
            gatewayInfo["Model"] = model
        }
    }

    private func applyHistoryResult(_ result: JSONValue?) {
        guard let items = result?.arrayValue else {
            if let object = result?.objectValue,
               let nestedItems = object["messages"]?.arrayValue ?? object["items"]?.arrayValue {
                applyHistoryArray(nestedItems)
            }
            return
        }

        applyHistoryArray(items)
    }

    private func applyHistoryArray(_ items: [JSONValue]) {
        let restored = items.compactMap { item -> HermesChatMessage? in
            guard let object = item.objectValue else { return nil }
            let roleText = value(in: object, keys: ["role"]) ?? "system"
            let content = value(in: object, keys: ["content", "text", "message"]) ?? ""
            guard !content.isEmpty else { return nil }

            let role: HermesChatMessageRole
            switch roleText.lowercased() {
            case "user":
                role = .user
            case "assistant":
                role = .assistant
            case "error":
                role = .error
            default:
                role = .system
            }

            return HermesChatMessage(role: role, text: content)
        }

        if !restored.isEmpty {
            messages = restored
        }
    }

    private func appendDiagnostic(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 200 {
            diagnostics.removeFirst(diagnostics.count - 200)
        }
    }

    private func present(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        sessionStatus = message
        connectionStatus = "Chat error"
        appendDiagnostic(message)
    }

    private func value(in payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct NativeChatScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @ObservedObject var chatStore: HermesNativeChatStore
    @StateObject private var keyboard = KeyboardObserver()
    @State private var dismissedLatestToolActivityID: String?
    @State private var scrollAnchorID = UUID()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    ChatStatusHeader(chatStore: chatStore, connection: store.activeConnection)

                    if !chatStore.canUseNativeChat {
                        NativeChatUnavailableView(chatStore: chatStore)
                    } else {
                        if !chatStore.hasConversationContent {
                            ConversationEmptyState(chatStore: chatStore, connection: store.activeConnection)
                        }

                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(chatStore.messages) { message in
                                ChatBubble(message: message)
                            }

                            if !chatStore.promptCards.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Action Required")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    ForEach(chatStore.promptCards) { card in
                                        PromptCardView(card: card, chatStore: chatStore)
                                    }
                                }
                            }

                            if chatStore.showDiagnostics && !chatStore.diagnostics.isEmpty {
                                DiagnosticsCard(lines: chatStore.diagnostics)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(scrollAnchorID)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: chatStore.messages.count) { _, _ in
                scrollToBottom(using: proxy)
            }
            .onChange(of: chatStore.promptCards.count) { _, _ in
                scrollToBottom(using: proxy)
            }
            .safeAreaInset(edge: .bottom) {
                if chatStore.canUseNativeChat {
                    VStack(spacing: 8) {
                        if let visibleToolCard {
                            ToolActivityTickerView(card: visibleToolCard) {
                                dismissedLatestToolActivityID = "\(visibleToolCard.id)-\(visibleToolCard.updatedAt.timeIntervalSinceReferenceDate)"
                            }
                                .id("\(visibleToolCard.id)-\(visibleToolCard.updatedAt.timeIntervalSinceReferenceDate)")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        ChatComposerView(chatStore: chatStore)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(Color.clear)
                }
            }
        }
        .navigationTitle(chatStore.currentSessionID == nil ? "New Chat" : "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: visibleToolActivityID)
        .onChange(of: chatStore.currentSessionID) { _, _ in
            dismissedLatestToolActivityID = nil
        }
        .onChange(of: latestToolActivityID) { _, newValue in
            if newValue.isEmpty {
                dismissedLatestToolActivityID = nil
            }
        }
        .toolbar {
            if keyboard.isVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismissKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        chatStore.prepareNewChat()
                    }
                    Button("Open Terminal", systemImage: "terminal") {
                        chatStore.openTerminal()
                    }
                    Button(chatStore.showDiagnostics ? "Hide Diagnostics" : "Show Diagnostics", systemImage: "waveform.path.ecg") {
                        chatStore.showDiagnostics.toggle()
                    }
                    Button("Close Chat", systemImage: "xmark.circle") {
                        Task { await chatStore.closeChat() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await chatStore.syncWithActiveConnection()
            await chatStore.refreshBootstrapStatus(force: true)
        }
        .task(id: chatStore.pendingResumeRequestID) {
            await chatStore.performPendingResumeIfNeeded()
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        scrollAnchorID = UUID()
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(scrollAnchorID, anchor: .bottom)
        }
    }

    private var visibleToolCard: HermesChatToolCard? {
        guard let latestToolCard = chatStore.latestToolCard else { return nil }
        let token = "\(latestToolCard.id)-\(latestToolCard.updatedAt.timeIntervalSinceReferenceDate)"
        guard dismissedLatestToolActivityID != token else { return nil }
        return latestToolCard
    }

    private var latestToolActivityID: String {
        guard let latestToolCard = chatStore.latestToolCard else { return "" }
        return "\(latestToolCard.id)-\(latestToolCard.updatedAt.timeIntervalSinceReferenceDate)"
    }

    private var visibleToolActivityID: String {
        guard let visibleToolCard else { return "" }
        return "\(visibleToolCard.id)-\(visibleToolCard.updatedAt.timeIntervalSinceReferenceDate)"
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct GatewayLabView: View {
    @ObservedObject var chatStore: HermesNativeChatStore
    @State private var chatTestResult: String?

    var body: some View {
        List {
            Section("Gateway Controls") {
                Button("Connect Gateway") {
                    Task { await chatStore.startChat() }
                }

                Button("Create Session") {
                    Task { await chatStore.createSession() }
                }

                Button("Chat Test") {
                    Task {
                        chatTestResult = await chatStore.runChatTest()
                    }
                }

                Button("Stop") {
                    Task { await chatStore.interrupt() }
                }

                Button("Close") {
                    Task { await chatStore.closeChat() }
                }

                if let chatTestResult {
                    Text(chatTestResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let bootstrap = chatStore.bootstrapStatus {
                Section("Bootstrap") {
                    DetailLine(label: "SSH", value: bootstrap.sshConnected ? "Connected" : "Unavailable")
                    DetailLine(label: "Python", value: bootstrap.pythonAvailable ? "Available" : "Unavailable")
                    DetailLine(label: "Hermes CLI", value: bootstrap.hermesCLIAvailable ? "Available" : "Unavailable")
                    DetailLine(label: "TUI Gateway", value: bootstrap.tuiGatewayAvailable ? "Available" : "Unavailable")
                    if let version = bootstrap.hermesVersion {
                        DetailLine(label: "Hermes Version", value: version)
                    }
                    if let fallbackReason = bootstrap.fallbackReason {
                        DetailLine(label: "Fallback", value: fallbackReason)
                    }
                }
            }

            if !chatStore.rawEvents.isEmpty {
                Section("Raw Events") {
                    ForEach(chatStore.rawEvents.reversed()) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.type)
                                .font(.caption.weight(.semibold))
                            if let rawLine = event.rawLine, !rawLine.isEmpty {
                                Text(rawLine)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            } else if !event.payload.isEmpty {
                                Text(JSONValue.object(event.payload).displayString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Gateway Lab")
    }
}

private struct ChatStatusHeader: View {
    @ObservedObject var chatStore: HermesNativeChatStore
    let connection: ConnectionProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection?.resolvedHermesProfileName ?? "Hermes")
                        .font(.headline)
                    if let connection {
                        Text("\(connection.label) · \(connection.displayDestination)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Select a saved host to start chatting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                StatusPill(
                    title: chatStore.canUseNativeChat ? "Native" : "Fallback",
                    color: chatStore.canUseNativeChat ? .green : .orange
                )
            }

            Text(chatStore.lastError ?? chatStore.sessionStatus)
                .font(.subheadline)
                .foregroundStyle(chatStore.lastError == nil ? Color.primary : Color.red)

            HStack(alignment: .top, spacing: 12) {
                StatusPill(title: chatStore.connectionStatus, color: .blue)

                if let currentSessionID = chatStore.currentSessionID, !currentSessionID.isEmpty {
                    StatusPill(title: "Session \(currentSessionID.prefix(8))", color: .secondary)
                }
            }

            if !chatStore.gatewayInfo.isEmpty {
                FlowInfoRow(items: chatStore.gatewayInfo)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct NativeChatUnavailableView: View {
    @ObservedObject var chatStore: HermesNativeChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Native chat is not available on this host yet.")
                .font(.headline)
            Text(chatStore.fallbackReason ?? "HermesPhone will keep the terminal available as fallback.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button("Retry") {
                    Task { await chatStore.refreshBootstrapStatus(force: true) }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Terminal") {
                    chatStore.openTerminal()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ConversationEmptyState: View {
    @ObservedObject var chatStore: HermesNativeChatStore
    let connection: ConnectionProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a new Hermes chat")
                .font(.headline)

            Text(promptText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let connection {
                HStack(spacing: 8) {
                    StatusPill(title: connection.label, color: .secondary)
                    StatusPill(title: connection.resolvedHermesProfileName, color: .blue)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var promptText: String {
        if let lastError = chatStore.lastError, !lastError.isEmpty {
            return lastError
        }
        return "Write a message below to create a fresh conversation with the selected Hermes profile. You can always jump back to Terminal for power-user work."
    }
}

private struct ChatComposerView: View {
    @ObservedObject var chatStore: HermesNativeChatStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Hermes", text: $chatStore.draftMessage, axis: .vertical)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .lineLimit(1 ... 6)

                if chatStore.isPerformingRequest {
                    Button {
                        Task { await chatStore.interrupt() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                } else {
                    Button {
                        Task { await chatStore.sendCurrentDraft() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        chatStore.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color(red: 0.18, green: 0.72, blue: 0.62)
                    )
                    .disabled(chatStore.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12))
            )

            if chatStore.isConnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct ChatBubble: View {
    let message: HermesChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 36)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.text + (message.isStreaming ? "▍" : ""))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if message.role != .user {
                Spacer(minLength: 36)
            }
        }
    }

    private var label: String {
        switch message.role {
        case .user:
            return "You"
        case .assistant:
            return "Hermes"
        case .system:
            return "System"
        case .error:
            return "Error"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return Color(red: 0.16, green: 0.62, blue: 0.54).opacity(0.18)
        case .assistant:
            return Color(.secondarySystemBackground)
        case .system:
            return Color.blue.opacity(0.12)
        case .error:
            return Color.red.opacity(0.12)
        }
    }
}

private struct ToolCardView: View {
    let card: HermesChatToolCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title)
                    .font(.headline)
                Spacer()
                Text(card.isRunning ? "Running" : "Done")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(card.isRunning ? Color.orange : Color.green)
            }

            Text(card.status)
                .font(.subheadline)

            if let detail = card.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ToolActivityTickerView: View {
    let card: HermesChatToolCard
    let onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(card.detail ?? card.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.16))
        )
        .offset(x: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragOffset = max(0, value.translation.width)
                }
                .onEnded { value in
                    if value.translation.width > 90 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            dragOffset = 220
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onDismiss()
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .overlay(alignment: .trailing) {
            if dragOffset > 18 {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
            }
        }
    }

    private var normalizedStatus: String {
        card.status.lowercased()
    }

    private var tint: Color {
        if card.isRunning {
            return .orange
        }
        if normalizedStatus.contains("error") || normalizedStatus.contains("fail") {
            return .red
        }
        return .green
    }

    private var iconName: String {
        if card.isRunning {
            return "gearshape.2.fill"
        }
        if normalizedStatus.contains("error") || normalizedStatus.contains("fail") {
            return "xmark.octagon.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusLabel: String {
        if card.isRunning {
            return "Running"
        }
        if normalizedStatus.contains("error") || normalizedStatus.contains("fail") {
            return "Failed"
        }
        return "Done"
    }
}

private struct PromptCardView: View {
    let card: HermesChatPromptCard
    @ObservedObject var chatStore: HermesNativeChatStore
    @State private var responseText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.title)
                .font(.headline)
            if !card.message.isEmpty {
                Text(card.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if card.kind == .approval {
                HStack {
                    Button("Approve") {
                        Task { await chatStore.respondToPrompt(card, approved: true) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Deny") {
                        Task { await chatStore.respondToPrompt(card, approved: false) }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                TextField(card.placeholder ?? "Response", text: $responseText)
                    .textFieldStyle(.roundedBorder)

                if !card.choices.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(card.choices, id: \.self) { choice in
                                Button(choice) {
                                    responseText = choice
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Button("Send Reply") {
                    Task { await chatStore.respondToPrompt(card, responseText: responseText) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DiagnosticsCard: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics")
                .font(.headline)

            ForEach(Array(lines.suffix(25).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct FlowInfoRow: View {
    let items: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.keys.sorted(), id: \.self) { key in
                if let value = items[key] {
                    DetailLine(label: key, value: value)
                }
            }
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
