import CryptoKit
import Foundation

struct AppPaths {
    let fileManager: FileManager
    let applicationSupportURL: URL
    let connectionsURL: URL
    let preferencesURL: URL
    let controlSocketDirectoryURL: URL

    private static let privateDirectoryPermissions = NSNumber(value: Int16(0o700))

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appSupport = baseSupport.appendingPathComponent("HermesDesktop", isDirectory: true)

        let baseCaches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? baseSupport
        let cacheSupport = baseCaches.appendingPathComponent("HermesDesktop", isDirectory: true)
        let controlDirectory = cacheSupport.appendingPathComponent("ControlSockets", isDirectory: true)

        self.applicationSupportURL = appSupport
        self.connectionsURL = appSupport.appendingPathComponent("connections.json")
        self.preferencesURL = appSupport.appendingPathComponent("preferences.json")
        self.controlSocketDirectoryURL = controlDirectory

        createPrivateDirectoryIfNeeded(at: appSupport)
        createPrivateDirectoryIfNeeded(at: cacheSupport)
        createPrivateDirectoryIfNeeded(at: controlDirectory)
    }

    func controlPath(for connection: ConnectionProfile) -> String {
        controlSocketDirectoryURL
            .appendingPathComponent(controlSocketIdentifier(for: connection))
            .path
    }

    private func createPrivateDirectoryIfNeeded(at url: URL) {
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: Self.privateDirectoryPermissions
        ]

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        } else {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return
            }
        }

        try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func controlSocketIdentifier(for connection: ConnectionProfile) -> String {
        // Scope SSH control sockets to the workspace so profiles on the same host stay isolated.
        let digest = SHA256.hash(data: Data(connection.workspaceScopeFingerprint.utf8))
        let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        return String(hexDigest.prefix(24))
    }
}
