#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

@MainActor
final class HermesPhoneStore: ObservableObject {
    @Published var selectedRootTab: HermesPhoneRootTab = .chat
    @Published var chatNavigationPath: [HermesPhoneChatRoute] = []
    @Published var connections: [ConnectionProfile] = []
    @Published var activeConnectionID: UUID?
    @Published var overview: RemoteDiscovery?
    @Published var sessions: [SessionSummary] = []
    @Published var sessionsLoadState: SessionListLoadState = .idle
    @Published var cronJobs: [CronJob] = []
    @Published var directoryListing: RemoteDirectoryListing?
    @Published var activeDirectoryPath: String = "~/.hermes"
    @Published var skills: [SkillSummary] = []
    @Published var selectedSkillDetail: SkillDetail?
    @Published var skillsError: String?
    @Published var isLoadingOverview = false
    @Published var isLoadingSessions = false
    @Published var isLoadingCronJobs = false
    @Published var isLoadingFiles = false
    @Published var isLoadingSkills = false
    @Published var isLoadingSkillDetail = false
    @Published var isBusy = false
    @Published var activeCronOperation: CronOperationState?
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
    private lazy var skillBrowserService = SkillBrowserService(sshTransport: sshTransport)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var currentSessionsLoadID: UUID?

    init() {
        terminalWorkspace.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistConnections()
            }
        }
        loadPersistedConnections()
        markSessionsPendingLoadIfNeeded()
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
            markSessionsPendingLoadIfNeeded()
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
            markSessionsPendingLoadIfNeeded()
            cronJobs = []
            skills = []
            selectedSkillDetail = nil
            skillsError = nil
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
        markSessionsPendingLoadIfNeeded()
        cronJobs = []
        skills = []
        selectedSkillDetail = nil
        skillsError = nil
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
        markSessionsPendingLoadIfNeeded()
        cronJobs = []
        skills = []
        selectedSkillDetail = nil
        skillsError = nil
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
        let requestedFingerprint = connection.workspaceScopeFingerprint
        isLoadingOverview = true
        defer { isLoadingOverview = false }

        do {
            let discovery = try await remoteHermesService.discover(connection: connection)
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            overview = discovery
            activeDirectoryPath = overview?.hermesHome ?? connection.remoteHermesHomePath
        } catch {
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            present(error)
        }
    }

    func loadSessions(query: String = "") async {
        guard let connection = activeConnection else {
            sessions = []
            sessionsLoadState = .idle
            currentSessionsLoadID = nil
            isLoadingSessions = false
            return
        }
        let requestedFingerprint = connection.workspaceScopeFingerprint
        let requestID = UUID()
        currentSessionsLoadID = requestID
        sessionsLoadState = .loading
        isLoadingSessions = true
        defer {
            if currentSessionsLoadID == requestID {
                currentSessionsLoadID = nil
                isLoadingSessions = false
            }
        }

        do {
            let page = try await sessionBrowserService.listSessions(
                connection: connection,
                offset: 0,
                limit: 100,
                query: query
            )
            guard currentSessionsLoadID == requestID,
                  activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            sessions = page.items
            sessionsLoadState = .loaded
        } catch {
            guard currentSessionsLoadID == requestID,
                  activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            sessionsLoadState = .failed
            present(error)
        }
    }

    func transcript(for sessionID: String) async throws -> [SessionMessage] {
        guard let connection = activeConnection else { return [] }
        return try await sessionBrowserService.loadTranscript(connection: connection, sessionID: sessionID)
    }

    func resumeSessionInTerminal(_ session: SessionSummary) {
        guard let connection = activeConnection else {
            present(HermesPhoneStoreError.missingTerminalConnection)
            return
        }
        let invocation = HermesSessionResumeInvocation(sessionID: session.id, connection: connection)
        terminalWorkspace.replaceWithSingleSession(
            for: connection,
            startupCommandLine: invocation.startupCommandLine,
            titleHint: session.resolvedTitle
        )
        selectedRootTab = .terminal
    }

    func continueSessionInChat(_ session: SessionSummary) {
        selectedRootTab = .chat
        chatNavigationPath = [.conversation]
        if nativeChatStore.isActiveConversation(session), nativeChatStore.hasConversationContent {
            return
        }
        Task { @MainActor in
            await nativeChatStore.queueResumeSessionReplacingActiveConversation(session)
        }
    }

    func openNewChat() {
        selectedRootTab = .chat
        chatNavigationPath = [.conversation]
        Task { @MainActor in
            await nativeChatStore.prepareNewChatReplacingActiveConversation()
        }
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
        terminalWorkspace.ensureSingleSession(for: connection)
        selectedRootTab = .terminal
    }

    func openNewTerminalSession() {
        openMonoTerminalSession()
    }

    func openMonoTerminalSession() {
        guard let connection = terminalConnection else { return }
        terminalWorkspace.ensureSingleSession(for: connection)
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

    func loadSkills() async {
        guard let connection = activeConnection else { return }
        let requestedFingerprint = connection.workspaceScopeFingerprint
        isLoadingSkills = true
        skillsError = nil
        defer { isLoadingSkills = false }

        do {
            let loadedSkills = try await skillBrowserService.listSkills(connection: connection)
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            skills = loadedSkills
        } catch {
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            skillsError = error.localizedDescription
            present(error)
        }
    }

    func loadSkillDetail(summary: SkillSummary) async {
        guard let connection = activeConnection else { return }
        let requestedFingerprint = connection.workspaceScopeFingerprint
        isLoadingSkillDetail = true
        skillsError = nil
        defer { isLoadingSkillDetail = false }

        do {
            let detail = try await skillBrowserService.loadSkillDetail(
                connection: connection,
                locator: summary.locator
            )
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            selectedSkillDetail = detail
        } catch {
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            skillsError = error.localizedDescription
            present(error)
        }
    }

    func operateCron(
        _ job: CronJob,
        kind: CronOperationKind,
        operation: @escaping (CronBrowserService, ConnectionProfile, String) async throws -> Void
    ) async {
        guard let connection = activeConnection else { return }
        guard activeCronOperation?.jobID != job.id else { return }
        isBusy = true
        activeCronOperation = CronOperationState(jobID: job.id, kind: kind)
        defer {
            isBusy = false
            activeCronOperation = nil
        }

        do {
            try await operation(cronBrowserService, connection, job.id)
            cronJobs = try await cronBrowserService.listJobs(connection: connection)
        } catch {
            present(error)
        }
    }

    func browseDirectory(path: String? = nil) async {
        guard let connection = activeConnection else { return }
        let requestedFingerprint = connection.workspaceScopeFingerprint
        directoryListing = nil
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
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            directoryListing = listing
            activeDirectoryPath = listing.displayPath
        } catch {
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
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
        let requestedFingerprint = connection.workspaceScopeFingerprint
        isBusy = true
        defer { isBusy = false }

        do {
            let snapshot = try await fileEditorService.read(remotePath: remotePath, connection: connection)
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
            fileEditor = RemoteFileDraft(
                path: remotePath,
                title: title ?? WorkspaceFileBookmark.displayTitle(for: remotePath),
                content: snapshot.content,
                contentHash: snapshot.contentHash
            )
        } catch {
            guard activeConnection?.workspaceScopeFingerprint == requestedFingerprint else { return }
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

    private func markSessionsPendingLoadIfNeeded() {
        sessions = []
        currentSessionsLoadID = nil
        isLoadingSessions = false
        sessionsLoadState = activeConnectionID == nil ? .idle : .pending
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

#endif
