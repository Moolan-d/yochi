import XCTest
@testable import Yochi

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

    func testStopSaysOnlyWhatTheConversationWillNot() {
        XCTAssertNil(AgentMessagePresentation.stopped(.pressed(outcome: "stopped")))
        XCTAssertEqual(AgentMessagePresentation.stopped(.pressed(outcome: "still_working")), "Agent 没有停下，可以再按一次")
        XCTAssertEqual(AgentMessagePresentation.stopped(.pressed(outcome: "exited")), "Agent 已退出")
        XCTAssertEqual(AgentMessagePresentation.stopped(.pressed(outcome: "unknown")), "已按停止键，无法确认 Agent 是否停下")
        XCTAssertEqual(AgentMessagePresentation.stopped(.failed(kind: "finished", message: "会话已结束")), "停止失败：会话已结束")
        XCTAssertEqual(AgentMessagePresentation.stopped(.unknown), "停止结果未知")
    }
}
