import Foundation
import Testing
@testable import Yochi

struct SessionLinkTests {
    @Test func aNotificationNamesItsSession() {
        #expect(SessionLink(url: URL(string: "yochi://session?id=t3")!)?.id == "t3")
        #expect(SessionLink(url: URL(string: "yochi://session?id=vps-us/t1")!)?.id == "vps-us/t1")
        #expect(SessionLink(url: URL(string: "yochi://session?id=t%202%26x")!)?.id == "t 2&x")
    }

    @Test func otherLinksAreNotSessions() {
        #expect(SessionLink(url: URL(string: "yochi://session")!) == nil)
        #expect(SessionLink(url: URL(string: "yochi://session?id=")!) == nil)
        #expect(SessionLink(url: URL(string: "yochi://pair?host=h&code=c")!) == nil)
        #expect(SessionLink(url: URL(string: "https://session?id=t3")!) == nil)
    }
}
