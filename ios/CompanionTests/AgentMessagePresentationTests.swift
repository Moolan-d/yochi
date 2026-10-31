import XCTest
@testable import Companion

final class AgentMessagePresentationTests: XCTestCase {
    func testAcceptedWordingUsesSendTimeStatusAndStarted() {
        XCTAssertEqual(AgentMessagePresentation.accepted(status: "idle", started: true), "已发送")
        XCTAssertEqual(AgentMessagePresentation.accepted(status: nil, started: nil), "已发送")
        XCTAssertEqual(AgentMessagePresentation.accepted(status: "working", started: true), "已发送 · Agent 正忙")
        XCTAssertEqual(
            AgentMessagePresentation.accepted(status: "idle", started: false),
            "已发送 · Agent 尚未开始处理"
        )
    }

    func testTurnAfterWorkingSendDoesNotClaimReply() {
        XCTAssertEqual(AgentMessagePresentation.afterTurn(status: "working"), "Agent 已结束一轮")
        XCTAssertEqual(AgentMessagePresentation.afterTurn(status: "idle"), "Agent 已回应")
        XCTAssertEqual(AgentMessagePresentation.afterTurn(status: nil), "Agent 已回应")
    }
}
