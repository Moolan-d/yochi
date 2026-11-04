#if DEBUG
import SwiftUI

/// A made-up home page with a remote space, a pinned Agent, a child Agent,
/// a to-do, an unseen finish and folded terminals, for UI tests and
/// screenshots without running Agents: SIMCTL_CHILD_COMPANION_SAMPLE_HOME=1.
struct SampleHomeView: View {
    static var requested: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_HOME"] != nil }

    @State private var home = Self.home(now: .now)

    var body: some View {
        NavigationStack {
            HomeList(home: home, queued: { $0 == "t4" }, newSession: {}) {}
                .navigationTitle("Agent")
                .navigationDestination(for: Session.self) { session in
                    Text(session.title).navigationTitle(session.title)
                }
        }
    }

    static func home(now: Date) -> Home {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let sessions = #"""
        [
          {"id":"t1","title":"服务助手页面自动断联后重连卡住","program":"claude","command":"claude","cwd":"/Users/me/wx-mini","turn":12,
           "status":{"state":"blocked","message":"要运行 npm test，允许吗？"},"status_ms":\#(ms - 40_000),
           "repo":{"name":"wx-mini","worktree":"fix-reconnect"}},
          {"id":"t2","title":"主页改版","program":"claude","command":"claude","cwd":"/Users/me/companion/ios","turn":30,"pinned":true,
           "status":{"state":"working"},"status_ms":\#(ms - 135_000),
           "repo":{"name":"companion"},"todo":{"text":"正在写主页列表","done":3,"total":7}},
          {"id":"t3","title":"查路线图剩余项","program":"claude","command":"claude","cwd":"/Users/me/companion/ios","turn":2,"parent":"t2",
           "status":{"state":"working"},"status_ms":\#(ms - 20_000),"repo":{"name":"companion"}},
          {"id":"t4","title":"补单元测试","program":"pi","command":"pi","cwd":"/Users/me/companion/gateway","turn":8,"seen":7,
           "status":{"state":"done"},"status_ms":\#(ms - 180_000),"repo":{"name":"companion"}},
          {"id":"t5","title":"zsh","program":"zsh","cwd":"/Users/me/companion","turn":0},
          {"id":"t6","title":"pnpm dev","program":"node","cwd":"/Users/me/wx-mini","turn":0},
          {"id":"vps/t1","machine":"vps","title":"升级 Caddy 配置","program":"claude","command":"claude","cwd":"/srv/infra","turn":4,"seen":4,
           "status":{"state":"done"},"status_ms":\#(ms - 7_200_000),"repo":{"name":"infra"}},
          {"id":"vps/t2","machine":"vps","title":"整理日志轮转","program":"claude","command":"claude","cwd":"/srv/infra","turn":6,
           "status":{"state":"done"},"status_ms":\#(ms - 600_000),"repo":{"name":"infra"}},
          {"id":"vps/t3","machine":"vps","title":"htop","program":"htop","cwd":"/root","turn":0},
          {"id":"t9","title":"Claude Code","program":"claude","command":"claude","cwd":"/Users/me/notes","turn":1,"status":{"state":"idle"}}
        ]
        """#
        let spaces = #"""
        [
          {"id":"sp1","name":"companion","tabs":[
            {"id":"sp1/1","name":"1","sessions":["t2","t3","t5"]},
            {"id":"sp1/2","name":"gateway","sessions":["t4"]}]},
          {"id":"sp2","name":"小程序","tabs":[{"id":"sp2/1","name":"1","sessions":["t1","t6"]}]},
          {"id":"vps/sp1","machine":"vps","name":"运维","tabs":[{"id":"vps/sp1/1","name":"1","sessions":["vps/t1","vps/t2","vps/t3"]}]}
        ]
        """#
        let decoder = JSONDecoder()
        let decodedSessions = (try? decoder.decode([Session].self, from: Data(sessions.utf8))) ?? []
        let decodedSpaces = (try? decoder.decode([Space].self, from: Data(spaces.utf8))) ?? []
        return makeHome(sessions: decodedSessions, spaces: decodedSpaces)
    }
}
#endif
