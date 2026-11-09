#if DEBUG
import SwiftUI

/// A made-up home with a remote space, a pinned Agent, a child Agent,
/// a to-do, an unseen finish and plain terminals, for UI tests and
/// screenshots without running Agents: SIMCTL_CHILD_COMPANION_SAMPLE_HOME=1.
/// SIMCTL_CHILD_COMPANION_SAMPLE_TAB=spaces starts on the Spaces tab.
struct SampleHomeView: View {
    static var requested: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_HOME"] != nil }

    @State private var data = Self.data(now: .now)
    @State private var tab: HomeTab = ProcessInfo.processInfo.environment["COMPANION_SAMPLE_TAB"] == "spaces" ? .spaces : .inbox
    @State private var inboxPath: [Route] = []
    @State private var spacesPath: [Route] = []

    var body: some View {
        let seen: [String: UInt64] = [:]
        TabView(selection: $tab) {
            Tab("Inbox", systemImage: "tray.fill", value: HomeTab.inbox) {
                stack($inboxPath, title: "Inbox") {
                    InboxList(inbox: makeInbox(sessions: data.sessions, spaces: data.spaces, seen: seen),
                              queued: { $0 == "t4" }, newSession: {}) {}
                }
            }
            .badge(makeInbox(sessions: data.sessions, spaces: data.spaces, seen: seen).badge)
            Tab("Spaces", systemImage: "square.grid.2x2.fill", value: HomeTab.spaces) {
                stack($spacesPath, title: "Spaces") {
                    SpacesList(board: makeSpacesBoard(sessions: data.sessions, spaces: data.spaces, seen: seen),
                               newSession: {}) {}
                }
            }
        }
    }

    private func stack<Root: View>(_ path: Binding<[Route]>, title: LocalizedStringKey, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: path) {
            root()
                .navigationTitle(title)
                .navigationDestination(for: Route.self) { route in
                    HomeRouteView(route: route, sessions: data.sessions, spaces: data.spaces, seen: [:],
                                  queued: { $0 == "t4" }) { session in
                        Text(session.title).navigationTitle(session.title)
                            .toolbar(.hidden, for: .tabBar)
                    }
                }
        }
    }

    static func data(now: Date) -> (sessions: [Session], spaces: [Space]) {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let sessions = #"""
        [
          {"id":"t1","title":"Support page hangs reconnecting after a drop","program":"claude","command":"claude","cwd":"/Users/me/wx-mini","turn":12,
           "status":{"state":"blocked","kind":"permission","message":"Run npm test?"},"status_ms":\#(ms - 40_000),
           "repo":{"name":"wx-mini","worktree":"fix-reconnect"}},
          {"id":"t2","title":"Home page redesign","program":"claude","command":"claude","cwd":"/Users/me/companion/ios","turn":30,"pinned":true,
           "status":{"state":"working"},"status_ms":\#(ms - 135_000),
           "repo":{"name":"companion"},"todo":{"text":"Writing the home list","done":3,"total":7}},
          {"id":"t3","title":"Check what's left on the roadmap","program":"claude","command":"claude","cwd":"/Users/me/companion/ios","turn":2,"parent":"t2",
           "status":{"state":"working"},"status_ms":\#(ms - 20_000),"repo":{"name":"companion"}},
          {"id":"t4","title":"Add unit tests","program":"pi","command":"pi","cwd":"/Users/me/companion/gateway","turn":8,"seen":7,
           "status":{"state":"done"},"status_ms":\#(ms - 180_000),"repo":{"name":"companion"}},
          {"id":"t5","title":"zsh","program":"zsh","cwd":"/Users/me/companion","turn":0},
          {"id":"t6","title":"pnpm dev","program":"node","cwd":"/Users/me/wx-mini","turn":0},
          {"id":"vps/t1","machine":"vps","title":"Upgrade the Caddy config","program":"claude","command":"claude","cwd":"/srv/infra","turn":4,"seen":4,
           "status":{"state":"done"},"status_ms":\#(ms - 7_200_000),"repo":{"name":"infra"}},
          {"id":"vps/t2","machine":"vps","title":"Tidy up log rotation","program":"claude","command":"claude","cwd":"/srv/infra","turn":6,
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
          {"id":"sp2","name":"mini-app","tabs":[{"id":"sp2/1","name":"1","sessions":["t1","t6"]}]},
          {"id":"vps/sp1","machine":"vps","name":"ops","tabs":[{"id":"vps/sp1/1","name":"1","sessions":["vps/t1","vps/t2","vps/t3"]}]}
        ]
        """#
        let decoder = JSONDecoder()
        let decodedSessions = (try? decoder.decode([Session].self, from: Data(SampleText.localized(sessions).utf8))) ?? []
        let decodedSpaces = (try? decoder.decode([Space].self, from: Data(SampleText.localized(spaces).utf8))) ?? []
        return (decodedSessions, decodedSpaces)
    }
}

/// The samples' made-up text is English; this gives the Chinese for
/// screenshots and UI tests run with the app in Chinese.
enum SampleText {
    static var chinese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true }

    static func localized(_ json: String) -> String {
        guard chinese else { return json }
        return pairs.sorted { $0.0.count > $1.0.count }
            .reduce(json) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// `english` normally, `chinese` with the app in Chinese.
    static func pick(_ english: String, _ chinese: String) -> String {
        Self.chinese ? chinese : english
    }

    private static let pairs: [(String, String)] = [
        // Home
        ("Support page hangs reconnecting after a drop", "服务助手页面自动断联后重连卡住"),
        ("Run npm test?", "要运行 npm test，允许吗？"),
        ("Home page redesign", "主页改版"),
        ("Writing the home list", "正在写主页列表"),
        ("Check what's left on the roadmap", "查路线图剩余项"),
        ("Add unit tests", "补单元测试"),
        ("Upgrade the Caddy config", "升级 Caddy 配置"),
        ("Tidy up log rotation", "整理日志轮转"),
        ("mini-app", "小程序"),
        ("ops", "运维"),
        // Conversation
        ("Fix the session list's empty state, and check what's left on the roadmap", "把会话列表的空状态改一下，顺便查查路线图里还剩什么"),
        ("Read the session list code", "读会话列表的代码"),
        ("Fix the empty state", "改空状态"),
        ("Checking the roadmap", "正在查路线图"),
        ("Check the roadmap", "查路线图"),
        ("No sessions", "没有会话"),
        ("No sessions yet", "还没有会话"),
        ("Open a terminal on your Mac, or tap New.", "在 Mac 上开一个终端，或点右上角新建。"),
        ("# Empty states", "# 空状态"),
        ("With no sessions, explain how to start one", "没有会话时说明怎样开一个"),
        ("When pairing has lapsed, lead to pairing again", "配对失效时引导重新配对"),
        ("Run the UI tests", "跑一遍 UI 测试"),
        ("The empty-state copy is done. Should the web version match?", "空状态的文案改好了，网页版要不要同步？"),
        ("Yes, the **web version** changes next week. Commit the iOS part first.", "要，**网页版**下周一起改。先把 iOS 的提交了。"),
    ]
}
#endif
