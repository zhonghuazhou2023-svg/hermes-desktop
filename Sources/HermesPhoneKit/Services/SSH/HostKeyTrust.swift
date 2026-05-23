@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security

struct HostKeyTrustChallenge: Codable, Equatable, Hashable, Identifiable, Sendable {
    let hostIdentity: String
    let displayDestination: String
    let algorithm: String
    let fingerprintSHA256: String
    let openSSHPublicKey: String

    var id: String {
        "\(hostIdentity)|\(fingerprintSHA256)"
    }

    init(
        hostIdentity: String,
        displayDestination: String,
        algorithm: String,
        fingerprintSHA256: String,
        openSSHPublicKey: String
    ) {
        self.hostIdentity = hostIdentity
        self.displayDestination = displayDestination
        self.algorithm = algorithm
        self.fingerprintSHA256 = fingerprintSHA256
        self.openSSHPublicKey = openSSHPublicKey
    }

    init(connection: ConnectionProfile, hostKey: NIOSSHPublicKey) {
        let openSSHPublicKey = String(openSSHPublicKey: hostKey)
        let components = openSSHPublicKey.split(separator: " ", omittingEmptySubsequences: true)
        let algorithm = components.first.map(String.init) ?? "unknown"
        let keyData = components.dropFirst().first.flatMap { Data(base64Encoded: String($0)) } ?? Data()
        let digest = SHA256.hash(data: keyData)

        self.hostIdentity = connection.hostTrustFingerprint
        self.displayDestination = connection.displayDestination
        self.algorithm = algorithm
        self.fingerprintSHA256 = "SHA256:\(Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: ""))"
        self.openSSHPublicKey = openSSHPublicKey
    }
}

struct TrustedHostKeyRecord: Codable, Equatable, Sendable {
    let hostIdentity: String
    let displayDestination: String
    let algorithm: String
    let fingerprintSHA256: String
    let openSSHPublicKey: String
    let acceptedAt: Date

    init(
        hostIdentity: String,
        displayDestination: String,
        algorithm: String,
        fingerprintSHA256: String,
        openSSHPublicKey: String,
        acceptedAt: Date
    ) {
        self.hostIdentity = hostIdentity
        self.displayDestination = displayDestination
        self.algorithm = algorithm
        self.fingerprintSHA256 = fingerprintSHA256
        self.openSSHPublicKey = openSSHPublicKey
        self.acceptedAt = acceptedAt
    }

    init(challenge: HostKeyTrustChallenge, acceptedAt: Date = Date()) {
        self.hostIdentity = challenge.hostIdentity
        self.displayDestination = challenge.displayDestination
        self.algorithm = challenge.algorithm
        self.fingerprintSHA256 = challenge.fingerprintSHA256
        self.openSSHPublicKey = challenge.openSSHPublicKey
        self.acceptedAt = acceptedAt
    }
}

enum HostKeyTrustDecision: Equatable {
    case allow
    case requireTrust(HostKeyTrustChallenge)
    case rejectMismatch(expected: TrustedHostKeyRecord, presented: HostKeyTrustChallenge)
}

enum HostKeyTrustEvaluator {
    static func evaluate(
        presented challenge: HostKeyTrustChallenge,
        storedRecord: TrustedHostKeyRecord?
    ) -> HostKeyTrustDecision {
        guard let storedRecord else {
            return .requireTrust(challenge)
        }

        guard storedRecord.hostIdentity == challenge.hostIdentity,
              storedRecord.openSSHPublicKey == challenge.openSSHPublicKey else {
            return .rejectMismatch(expected: storedRecord, presented: challenge)
        }

        return .allow
    }
}

enum HostKeyValidationError: LocalizedError, Sendable {
    case unknownHost(HostKeyTrustChallenge)
    case hostKeyMismatch(expected: TrustedHostKeyRecord, presented: HostKeyTrustChallenge)
    case storeFailure(String)

    var errorDescription: String? {
        switch self {
        case .unknownHost(let challenge):
            return """
            Verify the SSH host key for \(challenge.displayDestination) before connecting.
            \(challenge.algorithm) \(challenge.fingerprintSHA256)
            """
        case .hostKeyMismatch(let expected, let presented):
            return """
            The SSH host key for \(presented.displayDestination) changed.
            Expected \(expected.fingerprintSHA256) but received \(presented.fingerprintSHA256). \
            Connection blocked until you verify the remote host key out of band.
            """
        case .storeFailure(let message):
            return message
        }
    }
}

struct HostKeyTrustPrompt: Identifiable, Equatable, Sendable {
    let challenge: HostKeyTrustChallenge
    let expectedRecord: TrustedHostKeyRecord?

    var id: String {
        challenge.id
    }

    var allowsTrust: Bool {
        expectedRecord == nil
    }

    var title: String {
        allowsTrust ? "Trust SSH Host Key" : "SSH Host Key Changed"
    }

    var message: String {
        if let expectedRecord {
            return """
            \(challenge.displayDestination)

            Saved:
            \(expectedRecord.algorithm) \(expectedRecord.fingerprintSHA256)

            Presented:
            \(challenge.algorithm) \(challenge.fingerprintSHA256)

            Connection remains blocked until the host key matches the trusted record.
            """
        }

        return """
        \(challenge.displayDestination)

        \(challenge.algorithm) \(challenge.fingerprintSHA256)

        Trust this host key to allow future connections from HermesPhone.
        """
    }
}

enum HostKeyTrustStoreError: LocalizedError {
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            return "Unable to access the trusted SSH host-key store (\(status))."
        }
    }
}

final class HostKeyTrustStore {
    private let service = "com.hermes.phone.hostkeys"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load(for hostIdentity: String) throws -> TrustedHostKeyRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostIdentity,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try decoder.decode(TrustedHostKeyRecord.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw HostKeyTrustStoreError.keychainFailure(status)
        }
    }

    func save(_ record: TrustedHostKeyRecord) throws {
        let data = try encoder.encode(record)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: record.hostIdentity,
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw HostKeyTrustStoreError.keychainFailure(addStatus)
            }
            return
        }

        throw HostKeyTrustStoreError.keychainFailure(status)
    }
}

final class ConnectionHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let connection: ConnectionProfile
    private let trustStore: HostKeyTrustStore

    init(connection: ConnectionProfile, trustStore: HostKeyTrustStore) {
        self.connection = connection
        self.trustStore = trustStore
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        do {
            let challenge = HostKeyTrustChallenge(connection: connection, hostKey: hostKey)
            let storedRecord = try trustStore.load(for: connection.hostTrustFingerprint)

            switch HostKeyTrustEvaluator.evaluate(presented: challenge, storedRecord: storedRecord) {
            case .allow:
                validationCompletePromise.succeed(())
            case .requireTrust(let challenge):
                validationCompletePromise.fail(HostKeyValidationError.unknownHost(challenge))
            case .rejectMismatch(let expected, let presented):
                validationCompletePromise.fail(
                    HostKeyValidationError.hostKeyMismatch(expected: expected, presented: presented)
                )
            }
        } catch {
            validationCompletePromise.fail(
                HostKeyValidationError.storeFailure(error.localizedDescription)
            )
        }
    }
}
