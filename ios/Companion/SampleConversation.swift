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
                .navigationTitle("Sample Conversation")
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
            items.append(["kind": "user", "id": "u\(turn)", "text": SampleText.pick("Question \(turn + 1): how should this part change?", "第 \(turn + 1) 个问题：这一段怎么改？")])
            items.append(["kind": "tool", "id": "r\(turn)", "name": "Read", "summary": "ios/Companion/File\(turn).swift", "state": "done"])
            items.append(["kind": "agent", "id": "a\(turn)", "text": Self.reply(turn, paragraphs: 3 + turn % 6)])
        }
        apply(["type": "conversation", "supported": true, "items": items])
        for turn in 40..<100 {
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
        var parts = [SampleText.pick("## Reply \(turn + 1)", "## 第 \(turn + 1) 段回复")]
        for paragraph in 0..<paragraphs {
            switch paragraph % 4 {
            case 1:
                parts.append(SampleText.pick(
                    "- First, the scroll position of `ConversationPane`\n- Then how the list lays itself out lazily\n- Last, that the newest reply stays in view when the keyboard comes up",
                    "- 先看 `ConversationPane` 的滚动位置\n- 再看列表是怎样按需排版的\n- 最后确认键盘弹出时最新一条仍在上方"))
            case 3:
                parts.append("```swift\nposition.scrollTo(edge: .bottom)\nlet rows = feed.items.count\nprint(rows)\n```")
            default:
                parts.append(SampleText.pick(
                    "This is paragraph \(paragraph + 1). To make this reply long enough, it says a lot: every row in the list has a different height, and a lazy list can only guess how tall the rows it hasn't shown are, learning their real height once they are on screen. If the guess is far off, jumping back to the newest can stop past the end of the content.",
                    "这是第 \(paragraph + 1) 段。为了让这一条足够长，这里写了很多字：列表里的每一行高度都不一样，按需排版的列表只能先估计没出现的行有多高，等它们真的出现在屏幕上才知道准确的高度。回到最新时，如果估计偏差太大，滚动就会停在内容之外。"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func json(now: Date) -> String {
        let started = Int64(now.timeIntervalSince1970 * 1000) - 12_000
        return #"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"user","id":"u1","text":"Fix the session list's empty state, and check what's left on the roadmap"},
          {"kind":"todos","id":"t1","items":[
            {"text":"Read the session list code","status":"in_progress"},
            {"text":"Fix the empty state","status":"pending"},
            {"text":"Check the roadmap","status":"pending"}]},
          {"kind":"tool","id":"t2","name":"Edit","summary":"/Users/me/app/ios/Companion/SessionListView.swift","state":"done",
           "edit":{"path":"/Users/me/app/ios/Companion/SessionListView.swift","added":3,"deleted":1,"truncated":false,
                   "patch":"@@ -40,6 +40,8 @@ struct SessionListView: View {\n         if sessions.isEmpty {\n             ContentUnavailableView {\n-                Label(\"No sessions\", systemImage: \"terminal\")\n+                Label(\"No sessions yet\", systemImage: \"terminal\")\n+            } description: {\n+                Text(\"Open a terminal on your Mac, or tap New.\")\n             }\n         }\n         list\n"}},
          {"kind":"tool","id":"t3","name":"Write","summary":"/Users/me/app/docs/empty-state.md","state":"done",
           "edit":{"path":"/Users/me/app/docs/empty-state.md","added":4,"deleted":0,"created":true,"truncated":false,
                   "patch":"@@ -0,0 +1,4 @@\n+# Empty states\n+\n+- With no sessions, explain how to start one\n+- When pairing has lapsed, lead to pairing again\n"}},
          {"kind":"tool","id":"t4","name":"Agent","summary":"Check what's left on the roadmap","state":"running",
           "agent":{"name":"Check what's left on the roadmap","type":"Explore","started_ms":\#(started),"background":false}},
          {"kind":"tool","id":"t5","name":"Agent","summary":"Run the UI tests","state":"done",
           "agent":{"name":"Run the UI tests","started_ms":\#(started - 150_000),"duration_ms":150000,"background":true}},
          {"kind":"peer","id":"p1","direction":"sent","name":"web-session","text":"The empty-state copy is done. Should the web version match?","state":"done"},
          {"kind":"peer","id":"p2","direction":"received","name":"web-session","text":"Yes, the **web version** changes next week. Commit the iOS part first.","state":"done"},
          {"kind":"todos","id":"t6","items":[
            {"text":"Read the session list code","status":"completed"},
            {"text":"Fix the empty state","status":"completed"},
            {"text":"Check the roadmap","active":"Checking the roadmap","status":"in_progress"}]}
        ]}
        """#
    }
}
#endif
