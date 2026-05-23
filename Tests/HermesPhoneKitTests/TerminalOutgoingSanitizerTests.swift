import Foundation
import Testing

@testable import HermesPhoneKit

struct TerminalOutgoingSanitizerTests {
    @Test
    func dropsOSCBackgroundColorResponses() {
        let payload = Array("\u{1B}]11;rgb:0000/0000/0000\u{07}".utf8)

        let result = TerminalOutgoingSanitizer.sanitize(payload)

        #expect(result.forwardedBytes.isEmpty)
        #expect(result.droppedSequenceCount == 1)
        #expect(result.didDropEntirePacket)
    }

    @Test
    func preservesRegularApprovalInput() {
        let approve = Array("/approve\r".utf8)
        let deny = Array("/deny\r".utf8)
        let upArrow = Array("\u{1B}[A".utf8)

        let approveResult = TerminalOutgoingSanitizer.sanitize(approve)
        let denyResult = TerminalOutgoingSanitizer.sanitize(deny)
        let arrowResult = TerminalOutgoingSanitizer.sanitize(upArrow)

        #expect(approveResult.forwardedBytes == approve)
        #expect(denyResult.forwardedBytes == deny)
        #expect(arrowResult.forwardedBytes == upArrow)
        #expect(approveResult.droppedSequenceCount == 0)
        #expect(denyResult.droppedSequenceCount == 0)
        #expect(arrowResult.droppedSequenceCount == 0)
    }

    @Test
    func stripsOnlyColorQueryResponsesFromMixedPayload() {
        let mixed = Array("a\u{1B}]10;rgb:FFFF/FFFF/FFFF\u{1B}\\b".utf8)

        let result = TerminalOutgoingSanitizer.sanitize(mixed)

        #expect(String(decoding: result.forwardedBytes, as: UTF8.self) == "ab")
        #expect(result.droppedSequenceCount == 1)
    }
}
