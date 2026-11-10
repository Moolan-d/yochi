import Testing
@testable import Yochi

struct SlashCompletionTests {
    @Test("Completion follows a bare command name only")
    func query() {
        #expect(SlashCompletion.query(in: "/") == "")
        #expect(SlashCompletion.query(in: "/Com") == "com")
        #expect(SlashCompletion.query(in: "/compact ") == nil)
        #expect(SlashCompletion.query(in: "hi /compact") == nil)
        #expect(SlashCompletion.query(in: "") == nil)
    }

    @Test("Built-ins first, prefixes before substrings, built-ins can't be shadowed")
    func matches() {
        let custom = [
            SlashCommand(name: "/research", description: "", source: .skill),
            SlashCommand(name: "/compact", description: "mine", source: .user),
            SlashCommand(name: "/re-plan", description: "", source: .project),
        ]
        #expect(SlashCompletion.matches("re", custom: custom).map(\.name)
            == ["/resume", "/rewind", "/research", "/re-plan"])
        let compact = SlashCompletion.matches("compact", custom: custom)
        #expect(compact.count == 1 && compact[0].source == .builtin)
        #expect(SlashCompletion.matches("", custom: custom).count == SlashCompletion.builtins.count + 2)
        #expect(SlashCompletion.matches("search", custom: custom).map(\.name) == ["/research"])
    }

    @Test("Only /exit asks first, and it comes last")
    func exit() {
        #expect(SlashCompletion.builtins.last?.name == "/exit")
        #expect(SlashCompletion.builtins.filter(\.endsSession).map(\.name) == ["/exit"])
        #expect(SlashCompletion.fill(SlashCompletion.builtins[0]) == "/compact ")
    }
}
