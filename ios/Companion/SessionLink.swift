import Foundation

/// `yochi://session?id=<session>`: what a notification opens, sent by the
/// Gateway through Bark. Opens that session once the list has it.
struct SessionLink: Equatable {
    var id: String

    init?(url: URL) {
        guard url.scheme == "yochi", url.host() == "session",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty
        else { return nil }
        self.id = id
    }
}
