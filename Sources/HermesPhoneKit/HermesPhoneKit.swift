#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

enum L10n {
    static func string(_ value: String, _ arguments: CVarArg...) -> String {
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale.current, arguments: arguments)
    }
}

enum SSHCredentialKind: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password:
            "Password"
        case .privateKey:
            "Private Key"
        }
    }
}

struct SSHCredentialRecord: Codable, Equatable, Sendable {
    var password: String?
    var privateKey: String?
    var passphrase: String?
}

struct SSHCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum SSHTransportError: LocalizedError, Equatable {
    case invalidConnection(String)
    case launchFailure(String)
    case remoteFailure(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidConnection(let message),
             .launchFailure(let message),
             .remoteFailure(let message),
             .invalidResponse(let message):
            return message
        }
    }
}

struct PersistenceEnvelope: Codable {
    var activeConnectionID: UUID?
    var connections: [ConnectionProfile]
    var terminalWorkspace: PersistedTerminalWorkspace?
    var workspaceFileBookmarks: [WorkspaceFileBookmark] = []

    enum CodingKeys: String, CodingKey {
        case activeConnectionID
        case connections
        case terminalWorkspace
        case workspaceFileBookmarks
    }

    init(
        activeConnectionID: UUID?,
        connections: [ConnectionProfile],
        terminalWorkspace: PersistedTerminalWorkspace?,
        workspaceFileBookmarks: [WorkspaceFileBookmark] = []
    ) {
        self.activeConnectionID = activeConnectionID
        self.connections = connections
        self.terminalWorkspace = terminalWorkspace
        self.workspaceFileBookmarks = workspaceFileBookmarks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeConnectionID = try container.decodeIfPresent(UUID.self, forKey: .activeConnectionID)
        connections = try container.decode([ConnectionProfile].self, forKey: .connections)
        terminalWorkspace = try container.decodeIfPresent(PersistedTerminalWorkspace.self, forKey: .terminalWorkspace)
        workspaceFileBookmarks = try container.decodeIfPresent([WorkspaceFileBookmark].self, forKey: .workspaceFileBookmarks) ?? []
    }
}

enum HermesPhoneRootTab: Hashable {
    case chat
    case terminal
    case sessions
    case files
    case more
}

enum HermesPhoneChatRoute: Hashable {
    case transcript(SessionSummary)
    case conversation
}

final class ConnectionSecretsStore {
    private let service = "com.hermes.phone.credentials"

    func load(for connectionID: UUID) throws -> SSHCredentialRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(SSHCredentialRecord.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw HermesPhoneStoreError.keychainFailure(status)
        }
    }

    func save(_ credential: SSHCredentialRecord, for connectionID: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw HermesPhoneStoreError.keychainFailure(addStatus)
            }
            return
        }
        throw HermesPhoneStoreError.keychainFailure(status)
    }

    func delete(for connectionID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum HermesPhoneStoreError: LocalizedError {
    case missingCredential
    case invalidPrivateKeyType(String)
    case missingTerminalConnection
    case invalidRemotePath
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Missing SSH credentials for this host."
        case .invalidPrivateKeyType(let message):
            return message
        case .missingTerminalConnection:
            return "Select a host before opening Terminal."
        case .invalidRemotePath:
            return "The remote path is empty."
        case .keychainFailure(let status):
            return "Keychain error (\(status))."
        }
    }
}

@MainActor
final class HermesPhoneStore: ObservableObject {
    @Published var selectedRootTab: HermesPhoneRootTab = .chat
    @Published var chatNavigationPath: [HermesPhoneChatRoute] = []
    @Published var connections: [ConnectionProfile] = []
    @Published var activeConnectionID: UUID?
    @Published var overview: RemoteDiscovery?
    @Published var sessions: [SessionSummary] = []
    @Published var cronJobs: [CronJob] = []
    @Published var directoryListing: RemoteDirectoryListing?
    @Published var activeDirectoryPath: String = "~/.hermes"
    @Published var isLoadingOverview = false
    @Published var isLoadingSessions = false
    @Published var isLoadingCronJobs = false
    @Published var isLoadingFiles = false
    @Published var isBusy = false
    @Published var alertMessage: String?
    @Published var hostKeyPrompt: HostKeyTrustPrompt?
    @Published var fileEditor: RemoteFileDraft?
    @Published private(set) var workspaceFileBookmarks: [WorkspaceFileBookmark] = []

    let terminalWorkspace = HermesTerminalWorkspaceStore()
    lazy var nativeChatStore = HermesNativeChatStore(phoneStore: self, sshTransport: sshTransport)

    private let secretsStore = ConnectionSecretsStore()
    private let sshTransport = SSHTransport()
    private lazy var remoteHermesService = RemoteHermesService(sshTransport: sshTransport)
    private lazy var sessionBrowserService = SessionBrowserService(sshTransport: sshTransport)
    private lazy var cronBrowserService = CronBrowserService(sshTransport: sshTransport)
    private lazy var fileEditorService = FileEditorService(sshTransport: sshTransport)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        terminalWorkspace.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistConnections()
            }
        }
        loadPersistedConnections()
    }

    var activeConnection: ConnectionProfile? {
        guard let activeConnectionID else { return nil }
        return connections.first(where: { $0.id == activeConnectionID })
    }

    var activeWorkspaceScopeFingerprint: String? {
        activeConnection?.workspaceScopeFingerprint
    }

    var terminalConnection: ConnectionProfile? {
        activeConnection?.updated()
    }

    var activeTerminalHostFingerprint: String? {
        terminalConnection?.hostConnectionFingerprint
    }

    var availableProfiles: [RemoteHermesProfile] {
        if let overview, !overview.availableProfiles.isEmpty {
            return overview.availableProfiles
        }
        if let connection = activeConnection {
            return [
                RemoteHermesProfile(
                    name: connection.resolvedHermesProfileName,
                    path: connection.remoteHermesHomePath,
                    isDefault: connection.usesDefaultHermesProfile,
                    exists: true
                )
            ]
        }
        return []
    }

    var canonicalFileReferences: [WorkspaceFileReference] {
        guard let activeConnection else { return [] }
        return RemoteTrackedFile.allCases.map { trackedFile in
            WorkspaceFileReference.canonical(
                trackedFile,
                remotePath: trackedFile.resolvedRemotePath(using: overview?.paths) ??
                    activeConnection.remotePath(for: trackedFile)
            )
        }
    }

    var bookmarkedWorkspaceFileReferences: [WorkspaceFileReference] {
        guard let activeConnection else { return [] }
        return workspaceFileBookmarks
            .filter { $0.workspaceScopeFingerprint == activeConnection.workspaceScopeFingerprint }
            .sorted { lhs, rhs in
                lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
            .map(WorkspaceFileReference.bookmark)
    }

    var bookmarkedWorkspaceFileGroups: [WorkspaceFileBookmarkGroup] {
        WorkspaceFileBookmarkGroup.groups(for: bookmarkedWorkspaceFileReferences)
    }

    func credential(for connection: ConnectionProfile) throws -> SSHCredentialRecord {
        guard let credential = try secretsStore.load(for: connection.id) else {
            throw HermesPhoneStoreError.missingCredential
        }
        return credential
    }

    func saveConnection(
        profile: ConnectionProfile,
        credential: SSHCredentialRecord,
        makeActive: Bool
    ) {
        var updatedConnections = connections
        let normalized = profile.updated()

        if let index = updatedConnections.firstIndex(where: { $0.id == normalized.id }) {
            updatedConnections[index] = normalized
        } else {
            updatedConnections.append(normalized)
        }

        updatedConnections.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        connections = updatedConnections
        if makeActive {
            activeConnectionID = normalized.id
        }

        do {
            try secretsStore.save(credential, for: normalized.id)
            persistConnections()
        } catch {
            present(error)
        }
    }

    func removeConnection(_ profile: ConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        secretsStore.delete(for: profile.id)
        terminalWorkspace.closeSessions(forConnectionID: profile.id)
        if activeConnectionID == profile.id {
            activeConnectionID = connections.first?.id
            overview = nil
            sessions = []
            cronJobs = []
            directoryListing = nil
            fileEditor = nil
            if let activeConnection {
                activeDirectoryPath = activeConnection.remoteHermesHomePath
            }
        }
        persistConnections()
    }

    func activateConnection(_ profile: ConnectionProfile) {
        activeConnectionID = profile.id
        sessions = []
        cronJobs = []
        directoryListing = nil
        fileEditor = nil
        activeDirectoryPath = profile.remoteHermesHomePath
        overview = nil
        persistConnections()
    }

    func switchHermesProfile(to profileName: String) async {
        guard let activeConnection else { return }
        guard activeConnection.resolvedHermesProfileName != profileName else { return }
        guard fileEditor == nil else {
            present(SSHTransportError.invalidConnection("Close the open file before switching Hermes profiles."))
            return
        }

        let updatedConnection = activeConnection.applyingHermesProfile(named: profileName)
        if let index = connections.firstIndex(where: { $0.id == updatedConnection.id }) {
            connections[index] = updatedConnection
        }

        overview = nil
        sessions = []
        cronJobs = []
        directoryListing = nil
        activeDirectoryPath = updatedConnection.remoteHermesHomePath
        persistConnections()
        await refreshOverview()
    }

    func testConnection(profile: ConnectionProfile, credential: SSHCredentialRecord) async -> String? {
        do {
            try validateDraft(profile: profile, credential: credential)
            try secretsStore.save(credential, for: profile.id)
            let discovery = try await remoteHermesService.discover(connection: profile.updated())
            if activeConnectionID == profile.id || activeConnectionID == nil {
                overview = discovery
                activeDirectoryPath = discovery.hermesHome
            }
            return "Connected to \(profile.displayDestination)."
        } catch {
            present(error)
            return error.localizedDescription
        }
    }

    func refreshOverview() async {
        guard let connection = activeConnection else { return }
        isLoadingOverview = true
        defer { isLoadingOverview = false }

        do {
            overview = try await remoteHermesService.discover(connection: connection)
            activeDirectoryPath = overview?.hermesHome ?? connection.remoteHermesHomePath
        } catch {
            present(error)
        }
    }

    func loadSessions(query: String = "") async {
        guard let connection = activeConnection else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let page = try await sessionBrowserService.listSessions(
                connection: connection,
                offset: 0,
                limit: 100,
                query: query
            )
            sessions = page.items
        } catch {
            present(error)
        }
    }

    func transcript(for sessionID: String) async -> [SessionMessage] {
        guard let connection = activeConnection else { return [] }
        do {
            return try await sessionBrowserService.loadTranscript(connection: connection, sessionID: sessionID)
        } catch {
            present(error)
            return []
        }
    }

    func resumeSessionInTerminal(_ session: SessionSummary) {
        guard let connection = activeConnection else {
            present(HermesPhoneStoreError.missingTerminalConnection)
            return
        }
        let invocation = HermesSessionResumeInvocation(sessionID: session.id, connection: connection)
        terminalWorkspace.addSession(
            for: connection,
            startupCommandLine: invocation.startupCommandLine,
            titleHint: session.resolvedTitle
        )
        selectedRootTab = .terminal
    }

    func continueSessionInChat(_ session: SessionSummary) {
        selectedRootTab = .chat
        nativeChatStore.queueResumeSession(session)
        chatNavigationPath = [.conversation]
    }

    func openNewChat() {
        selectedRootTab = .chat
        nativeChatStore.prepareNewChat()
        chatNavigationPath = [.conversation]
    }

    func reopenActiveConversation() {
        selectedRootTab = .chat
        chatNavigationPath = [.conversation]
    }

    func openNativeChat() {
        openNewChat()
    }

    func ensureTerminalConnected() {
        guard let connection = terminalConnection else { return }
        terminalWorkspace.ensureInitialSession(for: connection)
        selectedRootTab = .terminal
    }

    func openNewTerminalSession() {
        guard let connection = terminalConnection else { return }
        terminalWorkspace.addSession(for: connection)
        selectedRootTab = .terminal
    }

    func loadCronJobs() async {
        guard let connection = activeConnection else { return }
        isLoadingCronJobs = true
        defer { isLoadingCronJobs = false }

        do {
            cronJobs = try await cronBrowserService.listJobs(connection: connection)
        } catch {
            present(error)
        }
    }

    func operateCron(_ job: CronJob, operation: @escaping (CronBrowserService, ConnectionProfile, String) async throws -> Void) async {
        guard let connection = activeConnection else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await operation(cronBrowserService, connection, job.id)
            cronJobs = try await cronBrowserService.listJobs(connection: connection)
        } catch {
            present(error)
        }
    }

    func browseDirectory(path: String? = nil) async {
        guard let connection = activeConnection else { return }
        isLoadingFiles = true
        defer { isLoadingFiles = false }

        do {
            let resolvedPath = (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? path!
                : (overview?.hermesHome ?? connection.remoteHermesHomePath)
            let listing = try await fileEditorService.listDirectory(
                remotePath: resolvedPath,
                hermesHome: connection.remoteHermesHomePath,
                connection: connection
            )
            directoryListing = listing
            activeDirectoryPath = listing.displayPath
        } catch {
            present(error)
        }
    }

    func openCanonicalFile(_ reference: WorkspaceFileReference) async {
        await openRemoteFile(remotePath: reference.remotePath, title: reference.title)
    }

    func openWorkspaceFileReference(_ reference: WorkspaceFileReference) async {
        if reference.opensDirectory {
            await browseDirectory(path: reference.remotePath)
        } else {
            await openRemoteFile(remotePath: reference.remotePath, title: reference.title)
        }
    }

    func openDirectoryEntry(_ entry: RemoteDirectoryEntry) async {
        switch entry.kind {
        case .directory:
            await browseDirectory(path: entry.path)
        case .file, .symlink:
            await openRemoteFile(remotePath: entry.displayPath, title: entry.name)
        case .other:
            break
        }
    }

    @discardableResult
    func addWorkspaceFileBookmark(
        remotePath: String,
        title: String? = nil,
        targetKind: WorkspaceFileBookmark.TargetKind,
        selectAfterAdd: Bool = false
    ) -> WorkspaceFileBookmark? {
        guard let activeConnection else { return nil }
        let normalizedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemotePath.isEmpty else { return nil }

        if let index = workspaceFileBookmarks.firstIndex(where: {
            $0.workspaceScopeFingerprint == activeConnection.workspaceScopeFingerprint &&
                $0.remotePath == normalizedRemotePath
        }) {
            var bookmark = workspaceFileBookmarks[index]
            bookmark.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? bookmark.title
            bookmark.targetKind = targetKind
            bookmark.updatedAt = Date()
            workspaceFileBookmarks[index] = bookmark
            persistConnections()
            if selectAfterAdd {
                Task { await openWorkspaceFileReference(.bookmark(bookmark)) }
            }
            return bookmark
        }

        let bookmark = WorkspaceFileBookmark(
            workspaceScopeFingerprint: activeConnection.workspaceScopeFingerprint,
            remotePath: normalizedRemotePath,
            title: title,
            targetKind: targetKind
        )
        workspaceFileBookmarks.append(bookmark)
        persistConnections()
        if selectAfterAdd {
            Task { await openWorkspaceFileReference(.bookmark(bookmark)) }
        }
        return bookmark
    }

    func removeWorkspaceFileBookmark(id: UUID) {
        workspaceFileBookmarks.removeAll { $0.id == id }
        persistConnections()
    }

    func removeWorkspaceFileBookmark(remotePath: String) {
        guard let activeConnection else { return }
        let normalizedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceFileBookmarks.removeAll {
            $0.workspaceScopeFingerprint == activeConnection.workspaceScopeFingerprint &&
                $0.remotePath == normalizedRemotePath
        }
        persistConnections()
    }

    func isWorkspaceFileBookmarked(remotePath: String) -> Bool {
        guard let activeConnection else { return false }
        let normalizedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaceFileBookmarks.contains {
            $0.workspaceScopeFingerprint == activeConnection.workspaceScopeFingerprint &&
                $0.remotePath == normalizedRemotePath
        }
    }

    func openRemoteFile(remotePath: String, title: String? = nil) async {
        guard let connection = activeConnection else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let snapshot = try await fileEditorService.read(remotePath: remotePath, connection: connection)
            fileEditor = RemoteFileDraft(
                path: remotePath,
                title: title ?? WorkspaceFileBookmark.displayTitle(for: remotePath),
                content: snapshot.content,
                contentHash: snapshot.contentHash
            )
        } catch {
            present(error)
        }
    }

    func saveOpenFile(content: String) async -> Bool {
        guard let connection = activeConnection, let fileEditor else { return false }
        isBusy = true
        defer { isBusy = false }

        do {
            let saveResult = try await fileEditorService.write(
                remotePath: fileEditor.path,
                content: content,
                expectedContentHash: fileEditor.contentHash,
                connection: connection
            )
            self.fileEditor = RemoteFileDraft(
                path: fileEditor.path,
                title: fileEditor.title,
                content: content,
                contentHash: saveResult.contentHash
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    func dismissAlert() {
        alertMessage = nil
    }

    func dismissHostKeyPrompt() {
        hostKeyPrompt = nil
    }

    func acceptHostKeyPrompt() {
        guard let challenge = hostKeyPrompt?.challenge else { return }
        do {
            try HostKeyTrustStore().save(TrustedHostKeyRecord(challenge: challenge))
            hostKeyPrompt = nil
            alertMessage = "Trusted \(challenge.displayDestination). Retry the connection to continue."
        } catch {
            present(error)
        }
    }

    private func validateDraft(profile: ConnectionProfile, credential: SSHCredentialRecord) throws {
        guard let validationError = profile.updated().validationError else {
            switch profile.authKind {
            case .password:
                let password = credential.password ?? ""
                guard !password.isEmpty else {
                    throw HermesPhoneStoreError.missingCredential
                }
            case .privateKey:
                let key = credential.privateKey ?? ""
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HermesPhoneStoreError.missingCredential
                }
            }
            return
        }

        throw SSHTransportError.invalidConnection(validationError)
    }

    private func persistConnections() {
        do {
            let envelope = PersistenceEnvelope(
                activeConnectionID: activeConnectionID,
                connections: connections,
                terminalWorkspace: terminalWorkspace.snapshot(),
                workspaceFileBookmarks: workspaceFileBookmarks
            )
            let data = try encoder.encode(envelope)
            let url = try persistenceURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            present(error)
        }
    }

    private func loadPersistedConnections() {
        do {
            let url = try persistenceURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let envelope = try decoder.decode(PersistenceEnvelope.self, from: data)
            connections = envelope.connections
            activeConnectionID = envelope.activeConnectionID ?? connections.first?.id
            terminalWorkspace.restore(from: envelope.terminalWorkspace, availableConnections: connections)
            workspaceFileBookmarks = envelope.workspaceFileBookmarks
        } catch {
            present(error)
        }
    }

    private func persistenceURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HermesPhone", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    private func present(_ error: Error) {
        if let hostKeyError = error as? HostKeyValidationError {
            alertMessage = nil
            switch hostKeyError {
            case .unknownHost(let challenge):
                hostKeyPrompt = HostKeyTrustPrompt(challenge: challenge, expectedRecord: nil)
            case .hostKeyMismatch(let expected, let presented):
                hostKeyPrompt = HostKeyTrustPrompt(challenge: presented, expectedRecord: expected)
            case .storeFailure(let message):
                hostKeyPrompt = nil
                alertMessage = message
            }
            return
        }

        alertMessage = error.localizedDescription
    }
}

struct RemoteFileDraft: Identifiable, Equatable {
    let path: String
    let title: String
    let content: String
    let contentHash: String

    var id: String { path }
}

final class SSHTransport: @unchecked Sendable {
    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data? = nil,
        allocateTTY: Bool
    ) async throws -> SSHCommandResult {
        let credentialStore = ConnectionSecretsStore()
        guard let credential = try credentialStore.load(for: connection.id) else {
            throw HermesPhoneStoreError.missingCredential
        }

        let client = try await makeClient(connection: connection, credential: credential)
        defer {
            Task {
                try? await client.close()
            }
        }

        let wrapped = makeWrappedCommand(
            for: connection,
            remoteCommand: remoteCommand,
            standardInput: standardInput
        )

        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var exitCode: Int32 = 0

        do {
            let streams = try await client.executeCommandPair(wrapped)
            async let stdoutResult = collectBuffer(from: streams.stdout)
            async let stderrResult = collectBuffer(from: streams.stderr)
            let (collectedStdout, collectedStderr) = await (stdoutResult, stderrResult)
            stdout = collectedStdout.buffer
            stderr = collectedStderr.buffer
            exitCode = collectedStdout.exitCode ?? collectedStderr.exitCode ?? 0

            if let failure = collectedStdout.failure ?? collectedStderr.failure {
                throw failure
            }
        } catch let failure as SSHClient.CommandFailed {
            exitCode = Int32(failure.exitCode)
        } catch {
            throw mapConnectionError(error, connection: connection)
        }

        return SSHCommandResult(
            stdout: String(buffer: stdout),
            stderr: String(buffer: stderr),
            exitCode: exitCode
        )
    }

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response {
        let result = try await execute(
            on: connection,
            remoteCommand: "python3 -",
            standardInput: Data(pythonScript.utf8),
            allocateTTY: false
        )

        try validateSuccessfulExit(result, for: connection)

        guard let data = result.stdout.data(using: .utf8) else {
            throw SSHTransportError.invalidResponse("Remote output was not valid UTF-8.")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SSHTransportError.invalidResponse(
                "Failed to decode remote JSON: \(error.localizedDescription)\n\n\(result.stdout)"
            )
        }
    }

    func shellBootstrapSequence(
        for connection: ConnectionProfile,
        startupCommandLine: String? = nil
    ) -> String {
        connection.remoteShellBootstrapCommand(startupCommandLine: startupCommandLine)
    }

    func validateSuccessfulExit(_ result: SSHCommandResult, for connection: ConnectionProfile? = nil) throws {
        guard result.exitCode == 0 else {
            throw SSHTransportError.remoteFailure(
                describeRemoteFailure(
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exitCode: result.exitCode,
                    connection: connection
                )
            )
        }
    }

    func describeRemoteFailure(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        connection: ConnectionProfile?
    ) -> String {
        let rawMessage = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""

        let lowered = rawMessage.lowercased()
        if lowered.contains("permission denied") {
            return "SSH authentication failed. Verify the selected user and credentials."
        }
        if lowered.contains("host key verification failed") {
            return "SSH host key verification failed."
        }
        if lowered.contains("python3: command not found") {
            return "SSH succeeded, but python3 is not available on the remote host."
        }
        if !rawMessage.isEmpty {
            return rawMessage
        }
        return "SSH command failed with exit code \(exitCode)."
    }

    func makeClient(connection: ConnectionProfile, credential: SSHCredentialRecord) async throws -> SSHClient {
        let authMethod = try connection.authenticationMethod(using: credential)
        let settings = SSHClientSettings(
            host: connection.effectiveTarget,
            port: connection.resolvedPort ?? 22,
            authenticationMethod: { authMethod },
            hostKeyValidator: .custom(
                ConnectionHostKeyValidator(
                    connection: connection,
                    trustStore: HostKeyTrustStore()
                )
            )
        )

        do {
            return try await SSHClient.connect(to: settings)
        } catch {
            throw mapConnectionError(error, connection: connection)
        }
    }

    func makeWrappedCommand(
        for connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?
    ) -> String {
        var commandBody = remoteCommand
        if let standardInput, let inputText = String(data: standardInput, encoding: .utf8) {
            let marker = "__HERMES_STDIN__"
            commandBody = "\(remoteCommand) <<'\(marker)'\n\(inputText)\n\(marker)"
        }

        let fullBody = "\(connection.remoteServiceEnvironmentExports); \(commandBody)"
        return "/bin/sh -lc \(fullBody.shellQuotedForTerminalCommand)"
    }

    private func mapConnectionError(_ error: Error, connection: ConnectionProfile) -> Error {
        if let hostKeyError = error as? HostKeyValidationError {
            return hostKeyError
        }

        if let channelError = error as? ChannelError {
            switch channelError {
            case .inputClosed, .eof, .alreadyClosed:
                return SSHTransportError.remoteFailure(
                    "The SSH connection to \(connection.displayDestination) was closed by the remote host."
                )
            case .ioOnClosedChannel, .outputClosed:
                return SSHTransportError.remoteFailure(
                    "The SSH connection to \(connection.displayDestination) closed unexpectedly."
                )
            default:
                break
            }
        }

        if let sshError = error as? SSHClientError {
            switch sshError {
            case .allAuthenticationOptionsFailed:
                return SSHTransportError.invalidConnection(authFailureMessage(for: connection))
            case .unsupportedPasswordAuthentication:
                return SSHTransportError.invalidConnection(
                    "The SSH server does not accept password authentication for \(connection.displayDestination). Use Private Key instead."
                )
            case .unsupportedPrivateKeyAuthentication:
                return SSHTransportError.invalidConnection(
                    "The SSH server does not accept public key authentication for \(connection.displayDestination). Use Password instead."
                )
            case .unsupportedHostBasedAuthentication, .channelCreationFailed:
                break
            }
        }

        let message = error.localizedDescription
        let reflectedType = String(reflecting: type(of: error))
        if reflectedType.contains("ClientHandshakeHandler.Disconnected")
            || message.localizedCaseInsensitiveContains("disconnected")
        {
            return SSHTransportError.remoteFailure(
                "The SSH connection to \(connection.displayDestination) was closed during handshake."
            )
        }
        if message.localizedCaseInsensitiveContains("password") {
            return SSHTransportError.invalidConnection("SSH authentication failed for \(connection.displayDestination).")
        }
        if message.localizedCaseInsensitiveContains("publickey") {
            return SSHTransportError.invalidConnection("SSH private key authentication failed for \(connection.displayDestination).")
        }
        if message.localizedCaseInsensitiveContains("timed out") {
            return SSHTransportError.remoteFailure("The SSH connection to \(connection.displayDestination) timed out.")
        }
        return SSHTransportError.launchFailure(message)
    }

    private func authFailureMessage(for connection: ConnectionProfile) -> String {
        switch connection.authKind {
        case .password:
            return "SSH authentication failed for \(connection.displayDestination). The server rejected the provided username/password."
        case .privateKey:
            return "SSH authentication failed for \(connection.displayDestination). The server rejected the provided username/private key."
        }
    }

    private func collectBuffer(
        from stream: AsyncThrowingStream<ByteBuffer, Error>
    ) async -> (buffer: ByteBuffer, exitCode: Int32?, failure: Error?) {
        var buffer = ByteBuffer()
        do {
            for try await chunk in stream {
                buffer.writeImmutableBuffer(chunk)
            }
            return (buffer, nil, nil)
        } catch let failure as SSHClient.CommandFailed {
            return (buffer, Int32(failure.exitCode), nil)
        } catch {
            if isExpectedCommandStreamTermination(error) {
                return (buffer, nil, nil)
            }
            return (buffer, nil, error)
        }
    }

    private func isExpectedCommandStreamTermination(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .inputClosed, .eof, .alreadyClosed, .ioOnClosedChannel:
                return true
            default:
                return false
            }
        }

        let reflectedType = String(reflecting: type(of: error))
        return reflectedType.contains("ClientHandshakeHandler.Disconnected")
    }
}

public struct HermesPhoneRootView: View {
    @StateObject private var store = HermesPhoneStore()

    public init() {}

    public var body: some View {
        TabView(selection: $store.selectedRootTab) {
            NavigationStack(path: $store.chatNavigationPath) {
                ChatInboxScreen()
                    .navigationDestination(for: HermesPhoneChatRoute.self) { route in
                        switch route {
                        case .transcript(let session):
                            SessionTranscriptScreen(session: session)
                        case .conversation:
                            NativeChatScreen(chatStore: store.nativeChatStore)
                        }
                    }
            }
            .tag(HermesPhoneRootTab.chat)
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right")
            }

            NavigationStack {
                TerminalScreen(workspace: store.terminalWorkspace)
            }
            .tag(HermesPhoneRootTab.terminal)
            .tabItem {
                Label("Terminal", systemImage: "terminal")
            }

            NavigationStack {
                FilesScreen()
            }
            .tag(HermesPhoneRootTab.files)
            .tabItem {
                Label("Files", systemImage: "doc.text")
            }

            NavigationStack {
                MoreScreen()
            }
            .tag(HermesPhoneRootTab.more)
            .tabItem {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        .environmentObject(store)
        .tint(Color(red: 0.18, green: 0.72, blue: 0.62))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .alert("HermesPhone", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { newValue in
                if !newValue { store.dismissAlert() }
            }
        )) {
            Button("OK", role: .cancel) {
                store.dismissAlert()
            }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .alert(
            store.hostKeyPrompt?.title ?? "SSH Host Key",
            isPresented: Binding(
                get: { store.hostKeyPrompt != nil },
                set: { newValue in
                    if !newValue { store.dismissHostKeyPrompt() }
                }
            )
        ) {
            if store.hostKeyPrompt?.allowsTrust == true {
                Button("Trust") {
                    store.acceptHostKeyPrompt()
                }
                Button("Cancel", role: .cancel) {
                    store.dismissHostKeyPrompt()
                }
            } else {
                Button("OK", role: .cancel) {
                    store.dismissHostKeyPrompt()
                }
            }
        } message: {
            Text(store.hostKeyPrompt?.message ?? "")
        }
        .sheet(item: $store.fileEditor) { draft in
            FileEditorSheet(draft: draft)
                .environmentObject(store)
        }
    }
}

private struct ConnectionHeader: View {
    let connection: ConnectionProfile?

    var body: some View {
        if let connection {
            VStack(alignment: .leading, spacing: 6) {
                Text(connection.label)
                    .font(.headline)
                Text("\(connection.displayDestination) · \(connection.resolvedHermesProfileName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ConnectionsScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var draft = ConnectionDraft()
    @State private var isPresentingEditor = false
    @State private var editingConnectionID: UUID?

    var body: some View {
        List {
            Section {
                activeWorkspaceSummary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Saved Connections") {
                if store.connections.isEmpty {
                    ContentUnavailableView("No Connections", systemImage: "server.rack", description: Text("Add an SSH connection to start using Hermes on iPhone."))
                } else {
                    ForEach(store.connections) { connection in
                        connectionRow(connection)
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.removeConnection(connection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button {
                editingConnectionID = nil
                draft = ConnectionDraft()
                isPresentingEditor = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                ConnectionEditorView(draft: $draft, editingConnectionID: editingConnectionID)
                    .environmentObject(store)
            }
        }
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.refreshOverview()
        }
    }

    private var activeWorkspaceSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active Workspace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let connection = store.activeConnection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.label)
                                .font(.title3.weight(.semibold))
                            Text(connection.displayDestination)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(connection.resolvedHermesProfileName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.16), in: Capsule())
                    }

                    if let overview = store.overview {
                        VStack(alignment: .leading, spacing: 8) {
                            workspaceMetric(label: "Remote Home", value: overview.remoteHome)
                            workspaceMetric(label: "Hermes Home", value: overview.hermesHome)
                            workspaceMetric(label: "Session Store", value: overview.sessionStore?.path ?? "Not found")
                            workspaceMetric(label: "Profiles", value: overview.availableProfiles.map(\.name).joined(separator: " · "))
                        }
                    } else {
                        Text("Pull remote workspace details from here, then spend the rest of your time in Terminal, Sessions, and Files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ContentUnavailableView("No Active Connection", systemImage: "server.rack", description: Text("Pick a saved connection to make Terminal, Sessions, and Files immediately usable."))
            }
        }
    }

    private func connectionRow(_ connection: ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.label)
                        .font(.headline)
                    Text(connection.displayDestination)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(connection.resolvedHermesProfileName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if store.activeConnectionID == connection.id {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 10) {
                Button("Use") {
                    store.activateConnection(connection)
                }
                .buttonStyle(.borderedProminent)

                Button("Edit") {
                    editingConnectionID = connection.id
                    draft = ConnectionDraft(connection: connection, credential: (try? store.credential(for: connection)) ?? SSHCredentialRecord())
                    isPresentingEditor = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func workspaceMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var store: HermesPhoneStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionHeader(connection: store.activeConnection)

                if let overview = store.overview {
                    overviewSection(overview)
                } else {
                    ContentUnavailableView(
                        "No Overview",
                        systemImage: "rectangle.stack",
                        description: Text("Select a host and refresh to inspect the remote Hermes environment.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Overview")
        .task(id: store.activeConnectionID) {
            await store.refreshOverview()
        }
        .refreshable {
            await store.refreshOverview()
        }
    }

    private func overviewSection(_ overview: RemoteDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailCard(title: "Workspace") {
                DetailRow(label: "Remote Home", value: overview.remoteHome)
                DetailRow(label: "Hermes Home", value: overview.hermesHome)
                DetailRow(label: "Active Profile", value: overview.activeProfile.name)
                DetailRow(label: "Session Store", value: overview.sessionStore?.path ?? "Not found")
            }

            DetailCard(title: "Important Paths") {
                DetailRow(label: "USER.md", value: overview.paths.user)
                DetailRow(label: "MEMORY.md", value: overview.paths.memory)
                DetailRow(label: "SOUL.md", value: overview.paths.soul)
                DetailRow(label: "Cron Jobs", value: overview.paths.cronJobs)
            }
        }
    }
}

private struct TerminalScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @ObservedObject private var workspace: HermesTerminalWorkspaceStore
    @StateObject private var keyboard = KeyboardObserver()
    @AppStorage("hermesPhone.terminal.backgroundHex") private var terminalBackgroundHex = TerminalAppearance.default.backgroundHex
    @AppStorage("hermesPhone.terminal.foregroundHex") private var terminalForegroundHex = TerminalAppearance.default.foregroundHex
    @State private var isPresentingAppearanceSheet = false

    init(workspace: HermesTerminalWorkspaceStore) {
        _workspace = ObservedObject(wrappedValue: workspace)
    }

    var body: some View {
        VStack(spacing: 12) {
            terminalFloatingToolbar
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    terminalQuickKeyMenuContent
                } label: {
                    Image(systemName: "command")
                }
            }
            if keyboard.isVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        workspace.selectedSession?.dismissKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                }
            }
        }
        .task(id: store.activeTerminalHostFingerprint) {
            await store.refreshOverview()
            store.ensureTerminalConnected()
        }
        .task(id: keyboard.isVisible) {
            guard let session = workspace.selectedSession else { return }
            if keyboard.isVisible {
                session.focusInput()
                session.ensurePromptVisible()
            }
        }
        .task(id: workspace.selectedSessionID) {
            guard let session = workspace.selectedSession else { return }
            session.connectIfNeeded()
            session.focusInput()
            session.ensurePromptVisible()
        }
        .sheet(isPresented: $isPresentingAppearanceSheet) {
            TerminalAppearanceSheet(
                backgroundHex: $terminalBackgroundHex,
                foregroundHex: $terminalForegroundHex
            )
            .presentationDetents([.medium])
        }
    }

    private var terminalAppearance: TerminalAppearance {
        TerminalAppearance(
            backgroundHex: terminalBackgroundHex,
            foregroundHex: terminalForegroundHex
        )
    }

    private var terminalSurface: some View {
        Group {
            if let selectedSession = workspace.selectedSession {
                HermesTerminalRepresentable(
                    session: selectedSession,
                    appearance: terminalAppearance
                )
                    .id(selectedSession.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "No Session",
                    systemImage: "terminal",
                    description: Text("Open a host shell and keep it alive while you move around the app.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.24), radius: 18, y: 10)
    }

    private var terminalFloatingToolbar: some View {
        HStack(spacing: 10) {
            if workspace.hasSessions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.sessions) { session in
                            TerminalSessionChip(
                                session: session,
                                isSelected: workspace.selectedSessionID == session.id,
                                onSelect: {
                                    workspace.selectSession(session.id)
                                },
                                onClose: {
                                    workspace.closeSession(session)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            Button {
                store.openNewTerminalSession()
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderedProminent)

            Menu {
                if let session = workspace.selectedSession {
                    Section {
                        Label(session.connection.label, systemImage: "server.rack")
                        Label(session.connection.displayDestination, systemImage: "network")
                        Label(session.contextLabel, systemImage: "terminal")
                    }

                    Section("Session") {
                        Button("Reconnect", systemImage: "arrow.clockwise") {
                            session.requestReconnect()
                        }
                        Button("Appearance", systemImage: "paintpalette") {
                            isPresentingAppearanceSheet = true
                        }
                        if keyboard.isVisible {
                            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
                                session.dismissKeyboard()
                            }
                        }
                    }
                } else {
                    Button("Connect", systemImage: "terminal") {
                        store.ensureTerminalConnected()
                    }
                    Button("Appearance", systemImage: "paintpalette") {
                        isPresentingAppearanceSheet = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06))
            )
    }

    @ViewBuilder
    private var terminalQuickKeyMenuContent: some View {
        Section("Control") {
            ForEach([TerminalQuickKey.escape, .tab, .ctrlC, .ctrlD]) { key in
                Button(key.title) {
                    workspace.selectedSession?.sendQuickKey(key)
                }
            }
        }

        Section("Navigation") {
            ForEach([TerminalQuickKey.up, .down, .left, .right]) { key in
                Button(key.title) {
                    workspace.selectedSession?.sendQuickKey(key)
                }
            }
        }

        Section("Symbols") {
            ForEach([TerminalQuickKey.pipe, .slash, .dash]) { key in
                Button(key.title) {
                    workspace.selectedSession?.sendQuickKey(key)
                }
            }
        }
    }

}

private struct TerminalAppearanceSheet: View {
    @Binding var backgroundHex: String
    @Binding var foregroundHex: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    ColorPicker("Background", selection: backgroundBinding, supportsOpacity: false)
                    ColorPicker("Text", selection: foregroundBinding, supportsOpacity: false)
                }

                Section("Preview") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("$ hermes --help")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(currentAppearance.foregroundColor)
                        Text("Terminal preview")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(currentAppearance.foregroundColor.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(currentAppearance.backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Section {
                    Button("Reset Default Theme") {
                        backgroundHex = TerminalAppearance.default.backgroundHex
                        foregroundHex = TerminalAppearance.default.foregroundHex
                    }
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var currentAppearance: TerminalAppearance {
        TerminalAppearance(
            backgroundHex: backgroundHex,
            foregroundHex: foregroundHex
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { currentAppearance.backgroundColor },
            set: { newValue in
                backgroundHex = UIColor(newValue).terminalHexString ?? backgroundHex
            }
        )
    }

    private var foregroundBinding: Binding<Color> {
        Binding(
            get: { currentAppearance.foregroundColor },
            set: { newValue in
                foregroundHex = UIColor(newValue).terminalHexString ?? foregroundHex
            }
        )
    }
}

private struct TerminalSessionChip: View {
    @ObservedObject var session: HermesTerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.isConnected ? Color.green : (session.isConnecting ? Color.orange : Color.secondary.opacity(0.6)))
                            .frame(width: 6, height: 6)
                        Text(session.displayTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if session.isConnecting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    Text(session.chipSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 124, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    private var backgroundColor: Color {
        return isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.06)
    }

    private var borderColor: Color {
        return Color.white.opacity(isSelected ? 0.18 : 0.08)
    }
}

final class KeyboardObserver: ObservableObject {
    @Published var bottomInset: CGFloat = 0

    var isVisible: Bool { bottomInset > 0 }

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            Task { @MainActor [weak self] in
                self?.handle(keyboardFrame: frame)
            }
        })

        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bottomInset = 0
        })
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
    }

    @MainActor
    private func handle(keyboardFrame: CGRect?) {
        guard
            let keyboardFrame,
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first(where: \.isKeyWindow)
        else {
            return
        }

        let overlap = max(0, window.bounds.maxY - keyboardFrame.minY - window.safeAreaInsets.bottom)
        bottomInset = overlap
    }
}

private struct ActiveWorkspaceStrip: View {
    @EnvironmentObject private var store: HermesPhoneStore
    let compact: Bool
    let showsConnectionSummary: Bool

    init(compact: Bool = false, showsConnectionSummary: Bool = true) {
        self.compact = compact
        self.showsConnectionSummary = showsConnectionSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.availableProfiles) { profile in
                        Button {
                            Task { await store.switchHermesProfile(to: profile.name) }
                        } label: {
                            HStack(spacing: 6) {
                                if profile.name == store.activeConnection?.resolvedHermesProfileName {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                }
                                Text(profile.name)
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(profileBackground(for: profile), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isBusy || store.isLoadingOverview)
                    }
                }
                .padding(.horizontal, 2)
            }

            if showsConnectionSummary, let connection = store.activeConnection {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.label)
                        .font(compact ? .headline : .title3.weight(.semibold))
                        .lineLimit(1)
                    Text(connection.displayDestination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                .stroke(Color.white.opacity(0.06))
        )
    }

    private func profileBackground(for profile: RemoteHermesProfile) -> Color {
        if profile.name == store.activeConnection?.resolvedHermesProfileName {
            return Color(red: 0.12, green: 0.36, blue: 0.31)
        }
        return Color.white.opacity(0.06)
    }
}

private struct ChatInboxScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var query = ""

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let connection = store.activeConnection {
                Section {
                    ConversationLaunchCard(
                        connection: connection,
                        chatStore: store.nativeChatStore,
                        onNewChat: store.openNewChat,
                        onOpenTerminal: store.ensureTerminalConnected
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if store.isLoadingSessions && store.sessions.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading chats…")
                            Spacer()
                        }
                    }
                } else if store.sessions.isEmpty {
                    Section("Recent Conversations") {
                        ContentUnavailableView(
                            "No Chats Yet",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Start a new Hermes chat with the selected profile. Your past conversations for this profile will appear here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                } else {
                    Section(querySectionTitle) {
                        ForEach(store.sessions) { session in
                            NavigationLink(value: HermesPhoneChatRoute.transcript(session)) {
                                ConversationRow(
                                    session: session,
                                    isActiveConversation: store.nativeChatStore.currentSessionID == session.id
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Continue", systemImage: "bubble.left.and.bubble.right") {
                                    store.continueSessionInChat(session)
                                }
                                .tint(.blue)

                                Button("Terminal", systemImage: "terminal") {
                                    store.resumeSessionInTerminal(session)
                                }
                                .tint(.green)
                            }
                            .contextMenu {
                                Button {
                                    store.continueSessionInChat(session)
                                } label: {
                                    Label("Continue in Chat", systemImage: "bubble.left.and.bubble.right")
                                }

                                Button {
                                    store.resumeSessionInTerminal(session)
                                } label: {
                                    Label("Resume in Terminal", systemImage: "terminal")
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "No Active Connection",
                        systemImage: "server.rack",
                        description: Text("Choose a saved SSH connection to browse profile-specific chats or start a new Hermes conversation.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chats")
        .toolbar {
            if store.activeConnection != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.openNewChat()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search past chats"
        )
        .onSubmit(of: .search) {
            Task { await store.loadSessions(query: query) }
        }
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await store.loadSessions() }
            }
        }
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.refreshOverview()
            await store.loadSessions()
            await store.nativeChatStore.syncWithActiveConnection()
            await store.nativeChatStore.refreshBootstrapStatus(force: true)
        }
        .refreshable {
            await store.refreshOverview()
            await store.loadSessions(query: query)
            await store.nativeChatStore.refreshBootstrapStatus(force: true)
        }
    }

    private var querySectionTitle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recent Conversations" : "Search Results"
    }
}

private struct ConversationLaunchCard: View {
    let connection: ConnectionProfile
    @ObservedObject var chatStore: HermesNativeChatStore
    let onNewChat: () -> Void
    let onOpenTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onNewChat) {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("New Chat")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onOpenTerminal) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                        Text("Terminal")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !chatStore.canUseNativeChat, let fallbackReason = chatStore.fallbackReason {
                Text(fallbackReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.18, blue: 0.17),
                            Color(red: 0.06, green: 0.11, blue: 0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat actions for \(connection.resolvedHermesProfileName)")
    }
}

private struct ConversationRow: View {
    let session: SessionSummary
    let isActiveConversation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.resolvedTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(timestampText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(previewText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if isActiveConversation {
                    DetailBadge(title: "Live", tint: Color(red: 0.18, green: 0.72, blue: 0.62))
                }

                if let model = session.displayModel {
                    DetailBadge(title: model, tint: .blue)
                }

                if let count = session.messageCount {
                    DetailBadge(title: "\(count) msgs", tint: .secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var previewText: String {
        if let snippet = session.searchMatch?.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snippet.isEmpty {
            return snippet
        }

        if let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            return preview
        }

        return "Open this chat to review the transcript or continue it."
    }

    private var timestampText: String {
        if let date = session.lastActive?.dateValue ?? session.startedAt?.dateValue {
            return DateFormatters.shortDateTimeString(from: date)
        }
        return "No date"
    }
}

private struct SessionSummaryCard: View {
    let session: SessionSummary
    let onContinueInChat: () -> Void
    let onResumeInTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.resolvedTitle)
                    .font(.headline)

                if let preview = session.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            HStack(spacing: 8) {
                if let model = session.displayModel {
                    DetailBadge(title: model, tint: .blue)
                }

                if let count = session.messageCount {
                    DetailBadge(title: "\(count) msgs", tint: .secondary)
                }

                if let lastActive = session.lastActive?.dateValue ?? session.startedAt?.dateValue {
                    DetailBadge(title: DateFormatters.shortDateTimeString(from: lastActive), tint: .secondary)
                }
            }

            HStack(spacing: 10) {
                Button(action: onContinueInChat) {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("Continue in Chat")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onResumeInTerminal) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                        Text("Resume in Terminal")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct TranscriptMessageRow: View {
    let message: SessionMessage
    @State private var isDetailExpanded: Bool
    @State private var isReasoningExpanded = false
    @State private var isMetadataExpanded = false

    init(message: SessionMessage) {
        self.message = message
        _isDetailExpanded = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.role.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleTint)

                Spacer()

                if let date = message.timestamp?.dateValue {
                    Text(DateFormatters.shortDateTimeString(from: date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if isPrimaryConversationTurn {
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                DisclosureGroup(isExpanded: $isDetailExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        transcriptExpandedContent
                        transcriptSupplementalSections
                    }
                    .padding(.top, 8)
                } label: {
                    transcriptCollapsedSummary
                }
                .tint(roleTint)
            }

            if isPrimaryConversationTurn {
                transcriptSupplementalSections
            }
        }
        .padding(14)
        .background(roleBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var transcriptExpandedContent: some View {
        if let toolSummary {
            VStack(alignment: .leading, spacing: 8) {
                Text(toolSummary.title)
                    .font(.subheadline.weight(.semibold))

                if let preview = SessionToolMessageSummary.detailPreview(from: message.content), !preview.isEmpty {
                    Text(preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if toolSummary.isDetailPreviewTruncated {
                    Text("Preview truncated")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if let content = message.content, !content.isEmpty {
            Text(content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptCollapsedSummary: some View {
        if let toolSummary {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(toolSummary.title, systemImage: toolStatusIconName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(roleTint)

                    if let statusText = toolSummary.statusText {
                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(toolStatusTint)
                    }

                    if let sizeText = toolSummary.sizeText {
                        Text(sizeText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let preview = toolSummary.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(collapsedSummaryTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let collapsedPreviewText, !collapsedPreviewText.isEmpty {
                    Text(collapsedPreviewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptSupplementalSections: some View {
        if !reasoningMetadataItems.isEmpty {
            DisclosureGroup(isExpanded: $isReasoningExpanded) {
                TranscriptMetadataBlock(items: reasoningMetadataItems)
                    .padding(.top, 8)
            } label: {
                Label("Reasoning", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        }

        if !plainMetadataItems.isEmpty {
            DisclosureGroup(isExpanded: $isMetadataExpanded) {
                TranscriptMetadataBlock(items: plainMetadataItems)
                    .padding(.top, 8)
            } label: {
                Label("Metadata", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        }
    }

    private var isPrimaryConversationTurn: Bool {
        switch message.role {
        case .user, .assistant:
            return true
        case .system, .event, .custom:
            return false
        }
    }

    private var toolSummary: SessionToolMessageSummary? {
        message.role.isToolRole ? SessionToolMessageSummary(content: message.content) : nil
    }

    private var reasoningMetadataItems: [SessionMetadataDisplayItem] {
        metadataItems.filter { item in
            let normalizedKey = item.key.lowercased()
            return normalizedKey.contains("reasoning")
        }
    }

    private var plainMetadataItems: [SessionMetadataDisplayItem] {
        metadataItems.filter { item in
            let normalizedKey = item.key.lowercased()
            return !normalizedKey.contains("reasoning")
        }
    }

    private var metadataItems: [SessionMetadataDisplayItem] {
        let metadata = message.displayMetadata ?? [:]
        return metadata.keys.sorted().compactMap { key in
            guard let value = metadata[key] else { return nil }
            return SessionMetadataDisplayItem(key: key, value: value)
        }
    }

    private var collapsedSummaryTitle: String {
        switch message.role {
        case .system:
            return "System note"
        case .event:
            return "Event details"
        case .custom(let value):
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        case .user, .assistant:
            return message.role.displayTitle
        }
    }

    private var collapsedPreviewText: String? {
        let source = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !source.isEmpty else {
            if !reasoningMetadataItems.isEmpty {
                return "Contains reasoning details"
            }
            if !plainMetadataItems.isEmpty {
                return "Contains metadata"
            }
            return nil
        }

        let normalized = source
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > 140 else { return normalized }
        return String(normalized.prefix(137)) + "..."
    }

    private var toolStatusTint: Color {
        guard let toolSummary else { return roleTint }
        switch toolSummary.statusKind {
        case .success:
            return .green
        case .failure:
            return .red
        case .neutral:
            return .secondary
        }
    }

    private var toolStatusIconName: String {
        guard let toolSummary else { return "wrench.and.screwdriver" }
        switch toolSummary.statusKind {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.octagon.fill"
        case .neutral:
            return "wrench.and.screwdriver"
        }
    }

    private var roleTint: Color {
        switch message.role {
        case .user:
            return Color(red: 0.18, green: 0.72, blue: 0.62)
        case .assistant:
            return .secondary
        case .system:
            return .blue
        case .event:
            return .purple
        case .custom:
            return message.role.isToolRole ? .orange : .red
        }
    }

    private var roleBackground: Color {
        switch message.role {
        case .user:
            return Color(red: 0.18, green: 0.72, blue: 0.62).opacity(0.12)
        case .assistant:
            return Color(.secondarySystemBackground)
        case .system:
            return Color.blue.opacity(0.10)
        case .event:
            return Color.purple.opacity(0.08)
        case .custom:
            return message.role.isToolRole ? Color.orange.opacity(0.10) : Color.red.opacity(0.10)
        }
    }
}

private struct TranscriptMetadataBlock: View {
    let items: [SessionMetadataDisplayItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.key.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(item.displayValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct DetailBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isNeutral ? Color.secondary : tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((isNeutral ? Color(.tertiarySystemFill) : tint.opacity(0.12)), in: Capsule())
    }

    private var isNeutral: Bool {
        title.hasSuffix("msgs") || title.contains(":")
    }
}

private struct SessionTranscriptScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    let session: SessionSummary
    @State private var messages: [SessionMessage] = []
    @State private var isLoadingMessages = true

    var body: some View {
        List {
            Section {
                SessionSummaryCard(
                    session: session,
                    onContinueInChat: { store.continueSessionInChat(session) },
                    onResumeInTerminal: { store.resumeSessionInTerminal(session) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if isLoadingMessages {
                Section("Transcript") {
                    HStack {
                        Spacer()
                        ProgressView("Loading transcript…")
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            } else if messages.isEmpty {
                Section("Transcript") {
                    ContentUnavailableView(
                        "No Transcript Available",
                        systemImage: "text.bubble",
                        description: Text("Hermes did not expose transcript lines for this session yet. You can still continue it in chat or reopen it in the terminal.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else {
                Section("Transcript") {
                    ForEach(messages) { message in
                        TranscriptMessageRow(message: message)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session.resolvedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Chat") {
                store.continueSessionInChat(session)
            }

            Button("Resume") {
                store.resumeSessionInTerminal(session)
            }
        }
        .task(id: session.id) {
            await loadTranscript()
        }
        .refreshable {
            await loadTranscript()
        }
    }

    private func loadTranscript() async {
        isLoadingMessages = true
        messages = await store.transcript(for: session.id)
        isLoadingMessages = false
    }
}

private struct CronJobsScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            ForEach(store.cronJobs) { job in
                NavigationLink {
                    CronJobDetailScreen(job: job)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.resolvedName)
                            .font(.headline)
                        Text(job.resolvedScheduleDisplay)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(job.displayState)
                            .font(.caption)
                            .foregroundStyle(job.isActive ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .navigationTitle("Cron Jobs")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.loadCronJobs()
        }
        .refreshable {
            await store.loadCronJobs()
        }
    }
}

private struct CronJobDetailScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    let job: CronJob

    var body: some View {
        List {
            DetailCard(title: "Job") {
                DetailRow(label: "Name", value: job.resolvedName)
                DetailRow(label: "State", value: job.displayState)
                DetailRow(label: "Schedule", value: job.resolvedScheduleDisplay)
                if let lastRunAt = job.lastRunAt {
                    DetailRow(label: "Last Run", value: DateFormatters.shortDateTimeString(from: lastRunAt))
                }
                if let nextRunAt = job.nextRunAt {
                    DetailRow(label: "Next Run", value: DateFormatters.shortDateTimeString(from: nextRunAt))
                }
            }

            if let prompt = job.trimmedPrompt {
                DetailCard(title: "Prompt") {
                    Text(prompt)
                        .font(.body)
                }
            }

            Section {
                Button("Run Now") {
                    Task { await store.operateCron(job) { service, connection, jobID in
                        try await service.runJobNow(connection: connection, jobID: jobID)
                    } }
                }

                if job.isPaused {
                    Button("Resume") {
                        Task { await store.operateCron(job) { service, connection, jobID in
                            try await service.resumeJob(connection: connection, jobID: jobID)
                        } }
                    }
                } else {
                    Button("Pause") {
                        Task { await store.operateCron(job) { service, connection, jobID in
                            try await service.pauseJob(connection: connection, jobID: jobID)
                        } }
                    }
                }

                Button("Delete", role: .destructive) {
                    Task { await store.operateCron(job) { service, connection, jobID in
                        try await service.removeJob(connection: connection, jobID: jobID)
                    } }
                }
            }
        }
        .navigationTitle(job.resolvedName)
    }
}

private struct FilesScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var browsePath = ""

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Canonical Files") {
                ForEach(store.canonicalFileReferences) { reference in
                    Button {
                        Task { await store.openCanonicalFile(reference) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reference.title)
                            Text(reference.remotePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Pinned Files & Folders") {
                if store.bookmarkedWorkspaceFileGroups.isEmpty {
                    Text("Pin remote files or folders from the browser below to keep them within easy reach.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.bookmarkedWorkspaceFileGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.directoryPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            ForEach(group.references) { reference in
                                Button {
                                    Task { await store.openWorkspaceFileReference(reference) }
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: reference.systemImage)
                                            .foregroundStyle(reference.opensDirectory ? .yellow : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(reference.title)
                                            Text(reference.remotePath)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if let bookmarkID = reference.bookmarkID {
                                        Button(role: .destructive) {
                                            store.removeWorkspaceFileBookmark(id: bookmarkID)
                                        } label: {
                                            Label("Unpin", systemImage: "pin.slash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Browse") {
                TextField("Remote path", text: $browsePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open Directory") {
                    Task { await store.browseDirectory(path: browsePath) }
                }
            }

            if let listing = store.directoryListing {
                Section(listing.displayPath) {
                    if let parent = listing.parentDisplayPath {
                        Button(".. (\(parent))") {
                            Task { await store.browseDirectory(path: listing.parentPath) }
                        }
                    }

                    ForEach(listing.entries) { entry in
                        Button {
                            Task { await store.openDirectoryEntry(entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: entry.kind == .directory ? "folder" : "doc.text")
                                        .foregroundStyle(entry.kind == .directory ? .yellow : .secondary)
                                    Text(entry.name)
                                }
                                Text(entry.displayPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let targetKind = entry.bookmarkTargetKind, entry.canBookmark {
                                if store.isWorkspaceFileBookmarked(remotePath: entry.displayPath) {
                                    Button {
                                        store.removeWorkspaceFileBookmark(remotePath: entry.displayPath)
                                    } label: {
                                        Label("Unpin", systemImage: "pin.slash")
                                    }
                                    .tint(.secondary)
                                } else {
                                    Button {
                                        _ = store.addWorkspaceFileBookmark(
                                            remotePath: entry.displayPath,
                                            title: entry.name,
                                            targetKind: targetKind
                                        )
                                    } label: {
                                        Label("Pin", systemImage: "pin")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            browsePath = store.overview?.hermesHome ?? store.activeConnection?.remoteHermesHomePath ?? "~/.hermes"
            await store.browseDirectory(path: browsePath)
        }
        .refreshable {
            await store.browseDirectory(path: browsePath)
        }
    }
}

private struct MoreScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Workspace") {
                NavigationLink {
                    GatewayLabView(chatStore: store.nativeChatStore)
                } label: {
                    Label("Gateway Lab", systemImage: "wave.3.right.circle")
                }

                NavigationLink {
                    ConnectionsScreen()
                } label: {
                    Label("Connections", systemImage: "server.rack")
                }

                NavigationLink {
                    CronJobsScreen()
                } label: {
                    Label("Cron Jobs", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle("More")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.refreshOverview()
        }
    }
}

private struct FileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: HermesPhoneStore
    let draft: RemoteFileDraft
    @State private var content: String

    init(draft: RemoteFileDraft) {
        self.draft = draft
        _content = State(initialValue: draft.content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .padding(12)
            }
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.saveOpenFile(content: content) {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

private struct ConnectionDraft {
    var label = ""
    var host = ""
    var port = "22"
    var user = ""
    var hermesProfile = ""
    var customHermesHomePath = ""
    var authKind: SSHCredentialKind = .password
    var password = ""
    var privateKey = ""
    var passphrase = ""

    init() {}

    init(connection: ConnectionProfile, credential: SSHCredentialRecord) {
        label = connection.label
        host = connection.sshHost
        port = connection.sshPort.map(String.init) ?? "22"
        user = connection.sshUser
        hermesProfile = connection.hermesProfile ?? ""
        customHermesHomePath = connection.customHermesHomePath ?? ""
        authKind = connection.authKind
        password = credential.password ?? ""
        privateKey = credential.privateKey ?? ""
        passphrase = credential.passphrase ?? ""
    }

    func makeProfile(existingID: UUID?) -> ConnectionProfile {
        ConnectionProfile(
            id: existingID ?? UUID(),
            label: label,
            sshAlias: "",
            sshHost: host,
            sshPort: Int(port),
            sshUser: user,
            hermesProfile: hermesProfile.nilIfBlank,
            customHermesHomePath: customHermesHomePath.nilIfBlank,
            authKind: authKind
        )
    }

    var credential: SSHCredentialRecord {
        SSHCredentialRecord(
            password: password.nilIfBlank,
            privateKey: privateKey.nilIfBlank,
            passphrase: passphrase.nilIfBlank
        )
    }

    var trimmedHermesProfile: String? {
        guard let value = hermesProfile.nilIfBlank else { return nil }
        guard value.caseInsensitiveCompare("default") != .orderedSame else { return nil }
        return value
    }

    var trimmedCustomHermesHomePath: String? {
        guard var value = customHermesHomePath.nilIfBlank else { return nil }
        if value == "~/" {
            return "~"
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

private struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: HermesPhoneStore
    @Binding var draft: ConnectionDraft
    let editingConnectionID: UUID?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Host") {
                TextField("Label", text: $draft.label)
                TextField("Host or IP", text: $draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $draft.port)
                    .keyboardType(.numberPad)
                TextField("User", text: $draft.user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Hermes") {
                TextField("Profile (optional)", text: $draft.hermesProfile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Custom Hermes Home (optional)", text: $draft.customHermesHomePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Standard remote layout: Hermes lives in ~/.hermes, or in ~/.hermes/profiles/<name> when you choose a profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let customHermesHomePath = draft.trimmedCustomHermesHomePath {
                    Text("Custom Hermes Home override: \(customHermesHomePath). HermesPhone will use this path as HERMES_HOME for Terminal and app-driven Hermes actions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let hermesProfile = draft.trimmedHermesProfile {
                    Text("Resolved profile path: ~/.hermes/profiles/\(hermesProfile). The default Terminal shell stays host-level and auto-detects the Hermes install from the standard layout.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The default Terminal shell auto-detects Hermes from the standard layout, checking ~/.hermes first and falling back to default or available profiles when needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $draft.authKind) {
                    ForEach(SSHCredentialKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                switch draft.authKind {
                case .password:
                    SecureField("Password", text: $draft.password)
                case .privateKey:
                    TextEditor(text: $draft.privateKey)
                        .frame(minHeight: 180)
                        .font(.body.monospaced())
                    SecureField("Passphrase (optional)", text: $draft.passphrase)
                }
            }

            Section {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    Task {
                        isTesting = true
                        let message = await store.testConnection(
                            profile: draft.makeProfile(existingID: editingConnectionID),
                            credential: draft.credential
                        )
                        testResult = message
                        isTesting = false
                    }
                }
                .disabled(isTesting)

                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(editingConnectionID == nil ? "New Host" : "Edit Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let profile = draft.makeProfile(existingID: editingConnectionID)
                    store.saveConnection(
                        profile: profile,
                        credential: draft.credential,
                        makeActive: store.activeConnectionID == nil || editingConnectionID == store.activeConnectionID
                    )
                    dismiss()
                }
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
