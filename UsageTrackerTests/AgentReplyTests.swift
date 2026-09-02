import XCTest
@testable import Omelette

final class AgentReplyTests: XCTestCase {
    /// Handlers are `@Sendable`; a captured var cannot be mutated from one, so the
    /// tests observe through the same box pattern `AgentEventServerTests` uses.
    private final class Flag: @unchecked Sendable { var fired = false }

    func testLineFormat() {
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: AgentFixture.requestID, decision: .allow), as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"allow"}"# + "\n")
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: AgentFixture.requestID, decision: .deny), as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"# + "\n")
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: AgentFixture.requestID, decision: nil), as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"# + "\n")
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: nil, decision: nil), as: UTF8.self),
                       #"{"v":2,"decision":null}"# + "\n")
    }

    func testSendWritesOnceThenEOF() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        XCTAssertFalse(reply.isSettled)

        reply.send(.deny)
        reply.send(.allow)          // ignored: the first answer stands
        reply.send(nil)

        XCTAssertTrue(reply.isSettled)
        XCTAssertEqual(AgentSocketTestClient.readLine(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"#)
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0, "after the line the helper sees EOF, nothing else")
        reply.closeDescriptor()
    }

    func testAnAlreadyAnsweredHandleIsInert() {
        let reply = AgentReply(requestID: nil)
        XCTAssertTrue(reply.isSettled)
        XCTAssertNil(reply.requestID)
        reply.send(.allow)          // nothing to write to; must not crash
        let flag = Flag()
        reply.onPeerClosed { flag.fired = true }
        XCTAssertFalse(flag.fired, "a settled handle never reports a lost peer")
    }

    func testPeerClosedFiresTheHandlerOnceAndSettles() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        reply.onPeerClosed { counter.count += 1 }

        reply.peerClosed()
        reply.peerClosed()
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(reply.isSettled)

        reply.send(.allow)          // too late: nothing is written
        XCTAssertNil(AgentSocketTestClient.readLine(peer, timeout: 0.1))
        reply.closeDescriptor()
    }

    func testHandlerRegisteredAfterThePeerLeftRunsImmediately() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        reply.peerClosed()
        let flag = Flag()
        reply.onPeerClosed { flag.fired = true }
        XCTAssertTrue(flag.fired)
        reply.closeDescriptor()
    }

    func testPeerClosedAfterSendIsANoOp() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        let flag = Flag()
        reply.onPeerClosed { flag.fired = true }
        reply.send(.allow)
        reply.peerClosed()          // the wake-up after our own shutdown
        XCTAssertFalse(flag.fired)
        reply.closeDescriptor()
    }

    func testSendAfterCloseDescriptorIsSafe() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        reply.closeDescriptor()
        reply.send(.allow)          // fd is gone; must not write to a recycled descriptor
        XCTAssertTrue(reply.isSettled)
    }
}
