import Foundation
import OSLog

struct TerminalOutgoingSanitizationResult: Equatable {
    let forwardedBytes: [UInt8]
    let droppedSequenceCount: Int

    var didDropBytes: Bool {
        droppedSequenceCount > 0
    }

    var didDropEntirePacket: Bool {
        didDropBytes && forwardedBytes.isEmpty
    }
}

enum TerminalOutgoingSanitizer {
    private static let escape: UInt8 = 0x1B
    private static let osc: UInt8 = 0x5D
    private static let bell: UInt8 = 0x07
    private static let terminator: UInt8 = 0x5C
    private static let semicolon: UInt8 = 0x3B
    private static let rgbPrefix = Array("rgb:".utf8)

    static func sanitize(_ bytes: [UInt8]) -> TerminalOutgoingSanitizationResult {
        guard !bytes.isEmpty else {
            return TerminalOutgoingSanitizationResult(forwardedBytes: [], droppedSequenceCount: 0)
        }

        var forwarded = [UInt8]()
        forwarded.reserveCapacity(bytes.count)

        var droppedSequenceCount = 0
        var index = 0

        while index < bytes.count {
            if let consumed = consumedOSCColorResponseLength(in: bytes, startingAt: index) {
                droppedSequenceCount += 1
                index += consumed
                continue
            }

            forwarded.append(bytes[index])
            index += 1
        }

        return TerminalOutgoingSanitizationResult(
            forwardedBytes: forwarded,
            droppedSequenceCount: droppedSequenceCount
        )
    }

    private static func consumedOSCColorResponseLength(
        in bytes: [UInt8],
        startingAt start: Int
    ) -> Int? {
        guard start + 8 < bytes.count else { return nil }
        guard bytes[start] == escape, bytes[start + 1] == osc else { return nil }

        let firstCodeDigit = bytes[start + 2]
        let secondCodeDigit = bytes[start + 3]
        guard firstCodeDigit == UInt8(ascii: "1") else { return nil }
        guard [UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2")].contains(secondCodeDigit) else {
            return nil
        }
        guard bytes[start + 4] == semicolon else { return nil }

        let prefixStart = start + 5
        let prefixEnd = prefixStart + rgbPrefix.count
        guard prefixEnd <= bytes.count else { return nil }
        guard Array(bytes[prefixStart..<prefixEnd]) == rgbPrefix else { return nil }

        var cursor = prefixEnd
        while cursor < bytes.count {
            switch bytes[cursor] {
            case bell:
                return cursor - start + 1
            case escape:
                let next = cursor + 1
                guard next < bytes.count else { return nil }
                if bytes[next] == terminator {
                    return next - start + 1
                }
                cursor += 1
            default:
                cursor += 1
            }
        }

        return nil
    }
}

enum TerminalOutgoingDebugLogger {
    private static let logger = Logger(subsystem: "HermesPhoneKit", category: "TerminalOutgoing")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_PHONE_TERMINAL_DEBUG"] == "1" ||
            UserDefaults.standard.bool(forKey: "hermesPhone.terminal.debugLogging")
    }

    static func log(
        originalBytes: [UInt8],
        result: TerminalOutgoingSanitizationResult
    ) {
        guard isEnabled else { return }

        let decision: String
        if result.didDropEntirePacket {
            decision = "dropped"
        } else if result.didDropBytes {
            decision = "forwarded_after_filter"
        } else {
            decision = "forwarded"
        }

        logger.debug(
            """
            terminal outgoing \(decision, privacy: .public) original=\(hex(originalBytes), privacy: .public) \
            forwarded=\(hex(result.forwardedBytes), privacy: .public) preview=\(asciiPreview(result.forwardedBytes), privacy: .public) \
            dropped_sequences=\(result.droppedSequenceCount, privacy: .public)
            """
        )
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "∅" }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func asciiPreview(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "∅" }
        return String(
            bytes.map { byte in
                if (0x20...0x7E).contains(byte) {
                    return Character(UnicodeScalar(byte))
                }
                return "."
            }
        )
    }
}
