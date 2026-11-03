import Foundation
import Testing
@testable import Companion

struct ChangesTests {
    @Test("Changes and their failures decode")
    func decodes() throws {
        let data = Data(#"{"type":"changes","id":"g1","repo":"companion","files":[{"path":"ios/A.swift","status":"M","added":12,"deleted":3},{"path":"B.md","old_path":"docs/A.md","status":"R","added":0,"deleted":0},{"path":"logo.png","status":"?"}],"truncated":false}"#.utf8)
        guard case .changes(let id, let list) = try JSONDecoder().decode(ServerMessage.self, from: data) else {
            Issue.record("not changes")
            return
        }
        #expect(id == "g1")
        #expect(list == ChangeList(repo: "companion", files: [
            FileChange(path: "ios/A.swift", status: .modified, added: 12, deleted: 3),
            FileChange(path: "B.md", oldPath: "docs/A.md", status: .renamed, added: 0, deleted: 0),
            FileChange(path: "logo.png", status: .untracked, added: nil, deleted: nil),
        ]))
        #expect((list.added, list.deleted) == (12, 3))

        let diff = Data(#"{"type":"change_diff","id":"g2","patch":"diff --git","truncated":true}"#.utf8)
        guard case .changeDiff(_, let patch, let truncated) = try JSONDecoder().decode(ServerMessage.self, from: diff) else {
            Issue.record("not change_diff")
            return
        }
        #expect(patch == "diff --git" && truncated)

        for type in ["changes_failed", "change_diff_failed"] {
            let failed = Data(#"{"type":"\#(type)","id":"g3","kind":"not_git","message":"不是 git 仓库"}"#.utf8)
            let message = try JSONDecoder().decode(ServerMessage.self, from: failed)
            switch message {
            case .changesFailed(_, let kind, _) where type == "changes_failed": #expect(kind == "not_git")
            case .changeDiffFailed(_, let kind, _) where type == "change_diff_failed": #expect(kind == "not_git")
            default: Issue.record("wrong case for \(type)")
            }
        }
    }

    @Test("A file row names its directory and what happened to it")
    func rows() {
        let modified = FileChange(path: "web/src/index.vue", status: .modified, added: 12, deleted: 3)
        #expect(modified.name == "index.vue")
        #expect(modified.detail == "web/src")
        #expect(modified.accessibilityLabel == "index.vue，修改，增加 12 行，删除 3 行")
        #expect(FileChange(path: "README.md", status: .added, added: 4, deleted: 0).detail == "根目录 · 新文件")
        #expect(FileChange(path: "a/new.txt", status: .untracked, added: 1, deleted: 0).detail == "a · 未跟踪")
        #expect(FileChange(path: "docs/B.md", oldPath: "docs/A.md", status: .renamed, added: 0, deleted: 0).detail == "docs · 改名自 A.md")
        let binary = FileChange(path: "logo.png", status: .untracked, added: nil, deleted: nil)
        #expect(binary.isBinary)
        #expect(binary.accessibilityLabel == "logo.png，未跟踪，二进制文件")
    }

    @Test("Hunks number deleted lines by the old file and the rest by the new one")
    func modifiedFile() {
        let patch = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -2,3 +2,3 @@ struct A {
             let x = 1
        -    let y = 2
        +    let y = 3
        +++ looks like a header
        -- also not one
        @@ -40 +40,2 @@
         end
        +more
        \\ No newline at end of file

        """
        let diff = ParsedDiff(patch)
        #expect(!diff.binary)
        #expect(diff.hunks.map(\.line) == [2, 40])
        #expect(diff.hunks[0].context == "struct A {")
        let first = diff.hunks[0].lines.map { "\($0.kind) \($0.number) \($0.text)" }
        #expect(first == [
            "context 2     let x = 1",
            "deleted 3     let y = 2",
            "added 3     let y = 3",
            "added 4 ++ looks like a header",
            "deleted 4 - also not one",
        ])
        #expect(diff.hunks[1].lines.map(\.number) == [40, 41])
        #expect(diff.hunks[1].lines.last?.noNewline == true)
        #expect(diff.hunks[0].lines[2].accessibilityLabel == "第 3 行，增加：    let y = 3")
    }

    @Test("New, deleted and binary files")
    func wholeFiles() {
        let new = ParsedDiff("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+one\n+\n")
        #expect(new.hunks.count == 1)
        #expect(new.hunks[0].line == 1)
        #expect(new.hunks[0].lines.map(\.number) == [1, 2])
        #expect(new.hunks[0].lines[1].accessibilityLabel == "第 2 行，增加：空行")

        let gone = ParsedDiff("--- a/g\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-one\n-two\n")
        #expect(gone.hunks[0].line == 1)
        #expect(gone.hunks[0].lines.map(\.kind) == [.deleted, .deleted])

        let binary = ParsedDiff("diff --git a/p.png b/p.png\nnew file mode 100644\nBinary files /dev/null and b/p.png differ\n")
        #expect(binary.binary && binary.hunks.isEmpty)
    }

    @Test("A cut-off patch keeps the lines it has")
    func truncated() {
        let diff = ParsedDiff("@@ -1,10 +1,10 @@\n a\n-b\n")
        #expect(diff.hunks[0].lines.count == 2)
    }
}
