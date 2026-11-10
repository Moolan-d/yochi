#if DEBUG
import Foundation

/// A Herdr tab made up for UI tests, so switching panes can be tested on
/// throwaway terminals without touching the desktop's own layout:
/// SIMCTL_CHILD_YOCHI_TEST_TAB=<id>,<id>.
enum UITestTab {
    static let sessions: [String] = ProcessInfo.processInfo.environment["YOCHI_TEST_TAB"]?
        .split(separator: ",").map(String.init) ?? []

    static func adding(to spaces: [Space]) -> [Space] {
        guard sessions.count > 1 else { return spaces }
        let tab = SpaceTab(id: "uitest-tab", name: "uitest", sessions: sessions, layout: nil)
        return spaces + [Space(id: "uitest-space", machine: nil, name: "uitest", folder: nil, tabs: [tab])]
    }
}
#endif
