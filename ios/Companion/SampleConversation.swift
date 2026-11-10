#if DEBUG
import SwiftUI

/// A made-up conversation with every kind of card, for UI tests and
/// screenshots without a running Agent: SIMCTL_CHILD_COMPANION_SAMPLE_CONVERSATION=1.
/// `=long` is a long one with long replies, and more replies arriving;
/// `=markdown` is one reply with every kind of Markdown block.
struct SampleConversationView: View {
    static var requested: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_CONVERSATION"] != nil }
    static var long: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_CONVERSATION"] == "long" }
    static var markdown: Bool { ProcessInfo.processInfo.environment["COMPANION_SAMPLE_CONVERSATION"] == "markdown" }

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
            if Self.markdown {
                apply(["type": "conversation", "supported": true, "items": [
                    ["kind": "user", "id": "u1", "text": SampleText.pick("How does the list keep its place?", "列表是怎样保持位置的？")],
                    ["kind": "agent", "id": "a1", "text": Self.markdownReply]]])
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

    static var markdownReply: String {
        let code = """
            ```swift
            // Keep the newest reply in view as rows arrive.
            struct ConversationPane: View {
                @State private var position = ScrollPosition(edge: .bottom)
                let feed: ConversationFeed

                var body: some View {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(feed.items) { item in
                                ConversationRow(item: item)
                            }
                        }
                    }
                    .scrollPosition($position)
                    .onChange(of: feed.items.count) { _, count in
                        if count > 0 { position.scrollTo(edge: .bottom) }
                    }
                }
            }
            ```
            """
        let english = """
            ## Why the list jumps

            A lazy list only **guesses** the height of rows it hasn't drawn. When `ConversationPane` scrolls to the newest reply, a bad guess stops it past the end. See [the docs](https://developer.apple.com/documentation/swiftui/scrollposition).

            ### What changed

            1. Keep the position in `ScrollPosition` instead of an id
            2. Scroll again once the last row has its real height
            3. Leave the keyboard's inset to the system

            - [x] Read `ConversationPane.swift`
            - [x] Reproduce with 40 long replies
            - [ ] Check the iPad split view

            > The guess comes from the rows already drawn, so it gets better as you scroll.

            \(code)

            | File | Change | Lines |
            | --- | --- | ---: |
            | `ConversationPane.swift` | Scroll position | 24 |
            | `ConversationFeed.swift` | Row heights | 8 |
            | `README.md` | Notes | 3 |

            Run `xcodebuild test` to check, then try it on the phone.
            """
        let chinese = """
            ## 列表为什么会跳

            按需排版的列表只能**估计**还没画出来的行有多高。`ConversationPane` 滚到最新一条时，估得不准就会停在内容之外。参见[官方文档](https://developer.apple.com/documentation/swiftui/scrollposition)。

            ### 改了什么

            1. 用 `ScrollPosition` 记位置，不再记 id
            2. 最后一行有了真实高度后再滚一次
            3. 键盘的留白交给系统

            - [x] 读 `ConversationPane.swift`
            - [x] 用 40 条长回复复现
            - [ ] 检查 iPad 分屏

            > 估计来自已经画过的行，所以越往回滚越准。

            \(code)

            | 文件 | 改动 | 行数 |
            | --- | --- | ---: |
            | `ConversationPane.swift` | 滚动位置 | 24 |
            | `ConversationFeed.swift` | 行高 | 8 |
            | `README.md` | 说明 | 3 |

            运行 `xcodebuild test` 检查，再到手机上试一下。
            """
        return SampleText.pick(english, chinese)
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
