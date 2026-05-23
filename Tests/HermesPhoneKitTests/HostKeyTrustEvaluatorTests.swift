import Foundation
import Testing

@testable import HermesPhoneKit

struct HostKeyTrustEvaluatorTests {
    @Test
    func unknownHostRequiresExplicitTrust() {
        let challenge = HostKeyTrustChallenge(
            hostIdentity: "mac-mini.local|22",
            displayDestination: "ed@mac-mini.local",
            algorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:new",
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey"
        )

        let decision = HostKeyTrustEvaluator.evaluate(
            presented: challenge,
            storedRecord: nil
        )

        #expect(decision == .requireTrust(challenge))
    }

    @Test
    func matchingTrustedKeyConnectsSilently() {
        let challenge = HostKeyTrustChallenge(
            hostIdentity: "mac-mini.local|22",
            displayDestination: "ed@mac-mini.local",
            algorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:trusted",
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITrusted"
        )
        let record = TrustedHostKeyRecord(challenge: challenge, acceptedAt: Date(timeIntervalSince1970: 1))

        let decision = HostKeyTrustEvaluator.evaluate(
            presented: challenge,
            storedRecord: record
        )

        #expect(decision == .allow)
    }

    @Test
    func changedHostKeyIsRejected() {
        let trustedChallenge = HostKeyTrustChallenge(
            hostIdentity: "mac-mini.local|22",
            displayDestination: "ed@mac-mini.local",
            algorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:trusted",
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITrusted"
        )
        let presentedChallenge = HostKeyTrustChallenge(
            hostIdentity: "mac-mini.local|22",
            displayDestination: "ed@mac-mini.local",
            algorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:changed",
            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChanged"
        )
        let record = TrustedHostKeyRecord(challenge: trustedChallenge, acceptedAt: Date(timeIntervalSince1970: 1))

        let decision = HostKeyTrustEvaluator.evaluate(
            presented: presentedChallenge,
            storedRecord: record
        )

        #expect(decision == .rejectMismatch(expected: record, presented: presentedChallenge))
    }
}
