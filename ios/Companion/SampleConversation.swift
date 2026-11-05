#if DEBUG
import SwiftUI

/// A made-up conversation with every kind of card, for UI tests and
/// screenshots without a running Agent: SIMCTL_CHILD_COMPANION_SAMPLE_CONVERSATION=1.
/// `=long` is a long one with long replies, and more replies arriving.
struct SampleConversationView: View {
    static var requested: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_CONVERSATION"] != nil }
    static var long: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_CONVERSATION"] == "long" }

    @State private var feed = ConversationFeed()

    var body: some View {
        NavigationStack {
            ConversationPane(feed: feed, status: nil, keyboardShown: false, retry: {})
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let progress = feed.todoProgress {
                        TodoProgressLine(progress: progress)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(.bar)
                    }
                }
                .navigationTitle("样例对话")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if Self.long {
                await playLong()
                return
            }
            let data = Data(SampleText.localized(Self.json(now: .now)).utf8)
            if let message = try? JSONDecoder().decode(ConversationMessage.self, from: data) {
                feed.apply(message)
            }
        }
    }

    /// Forty turns, then a new reply every few seconds, as an Agent at work.
    private func playLong() async {
        var items: [[String: Any]] = []
        for turn in 0..<40 {
            items.append(["kind": "user", "id": "u\(turn)", "text": "第 \(turn + 1) 个问题：这一段怎么改？"])
            items.append(["kind": "tool", "id": "r\(turn)", "name": "Read", "summary": "ios/Companion/File\(turn).swift", "state": "done"])
            items.append(["kind": "agent", "id": "a\(turn)", "text": Self.reply(turn, paragraphs: 3 + turn % 6)])
        }
        apply(["type": "conversation", "supported": true, "items": items])
        for turn in 40..<46 {
            try? await Task.sleep(for: .seconds(4))
            apply(["type": "items", "items": [["kind": "agent", "id": "a\(turn)", "text": Self.reply(turn, paragraphs: 8)]]])
        }
    }

    private func apply(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let message = try? JSONDecoder().decode(ConversationMessage.self, from: data) else { return }
        feed.apply(message)
    }

    static func reply(_ turn: Int, paragraphs: Int) -> String {
        var parts = ["## 第 \(turn + 1) 段回复"]
        for paragraph in 0..<paragraphs {
            switch paragraph % 4 {
            case 1:
                parts.append("- 先看 `ConversationPane` 的滚动位置\n- 再看列表是怎样按需排版的\n- 最后确认键盘弹出时最新一条仍在上方")
            case 3:
                parts.append("```swift\nposition.scrollTo(edge: .bottom)\nlet rows = feed.items.count\nprint(rows)\n```")
            default:
                parts.append("这是第 \(paragraph + 1) 段。为了让这一条足够长，这里写了很多字：列表里的每一行高度都不一样，按需排版的列表只能先估计没出现的行有多高，等它们真的出现在屏幕上才知道准确的高度。回到最新时，如果估计偏差太大，滚动就会停在内容之外。")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func json(now: Date) -> String {
        let started = Int64(now.timeIntervalSince1970 * 1000) - 12_000
        return #"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"user","id":"u1","text":"把会话列表的空状态改一下，顺便查查路线图里还剩什么"},
          {"kind":"todos","id":"t1","items":[
            {"text":"读会话列表的代码","status":"in_progress"},
            {"text":"改空状态","status":"pending"},
            {"text":"查路线图","status":"pending"}]},
          {"kind":"tool","id":"t2","name":"Edit","summary":"/Users/me/app/ios/Companion/SessionListView.swift","state":"done",
           "edit":{"path":"/Users/me/app/ios/Companion/SessionListView.swift","added":3,"deleted":1,"truncated":false,
                   "patch":"@@ -40,6 +40,8 @@ struct SessionListView: View {\n         if sessions.isEmpty {\n             ContentUnavailableView {\n-                Label(\"没有会话\", systemImage: \"terminal\")\n+                Label(\"还没有会话\", systemImage: \"terminal\")\n+            } description: {\n+                Text(\"在 Mac 上开一个终端，或点右上角新建。\")\n             }\n         }\n         list\n"}},
          {"kind":"tool","id":"t3","name":"Write","summary":"/Users/me/app/docs/empty-state.md","state":"done",
           "edit":{"path":"/Users/me/app/docs/empty-state.md","added":4,"deleted":0,"created":true,"truncated":false,
                   "patch":"@@ -0,0 +1,4 @@\n+# 空状态\n+\n+- 没有会话时说明怎样开一个\n+- 配对失效时引导重新配对\n"}},
          {"kind":"tool","id":"t4","name":"Agent","summary":"查路线图剩余项","state":"running",
           "agent":{"name":"查路线图剩余项","type":"Explore","started_ms":\#(started),"background":false}},
          {"kind":"tool","id":"t5","name":"Agent","summary":"跑一遍 UI 测试","state":"done",
           "agent":{"name":"跑一遍 UI 测试","started_ms":\#(started - 150_000),"duration_ms":150000,"background":true}},
          {"kind":"peer","id":"p1","direction":"sent","name":"web-session","text":"空状态的文案改好了，网页版要不要同步？","state":"done"},
          {"kind":"peer","id":"p2","direction":"received","name":"web-session","text":"要，**网页版**下周一起改。先把 iOS 的提交了。","state":"done"},
          {"kind":"todos","id":"t6","items":[
            {"text":"读会话列表的代码","status":"completed"},
            {"text":"改空状态","status":"completed"},
            {"text":"查路线图","active":"正在查路线图","status":"in_progress"}]}
        ]}
        """#
    }
}
#endif
