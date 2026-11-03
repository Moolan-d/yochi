import Foundation
import Testing
import UIKit

@testable import Companion

/// Photos are shrunk before they leave the phone and named in the draft by path.
struct ImageAttachmentTests {
    private func image(width: CGFloat, height: CGFloat, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("A large photo is shrunk to 2048 pixels on its long edge")
    func shrinks() throws {
        let data = try #require(ImageShrinker.jpeg(from: image(width: 2000, height: 1500, scale: 2)))
        let shrunk = try #require(UIImage(data: data))
        #expect(shrunk.size.width * shrunk.scale == 2048)
        #expect(shrunk.size.height * shrunk.scale == 1536)
    }

    @Test("A small photo keeps its size")
    func keepsSmall() throws {
        let data = try #require(ImageShrinker.jpeg(from: image(width: 800, height: 1200)))
        let shrunk = try #require(UIImage(data: data))
        #expect(shrunk.size.width * shrunk.scale == 800)
        #expect(shrunk.size.height * shrunk.scale == 1200)
    }

    @Test("Names are plain, timed and numbered")
    func names() {
        let date = Date(timeIntervalSince1970: 0)
        let name = ImageShrinker.name(at: date, index: 2)
        #expect(name.hasPrefix("image-19"))
        #expect(name.hasSuffix("-2.jpg"))
        #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-.".contains($0)) })
    }

    @Test("A path joins the draft after a space and leaves it cleanly")
    func draftPaths() {
        #expect(DraftPaths.insert("/t/a.jpg", into: "") == "/t/a.jpg")
        #expect(DraftPaths.insert("/t/a.jpg", into: "看这张") == "看这张 /t/a.jpg")
        #expect(DraftPaths.insert("/t/a.jpg", into: "看这张\n") == "看这张\n/t/a.jpg")
        let draft = DraftPaths.insert("/t/b.jpg", into: DraftPaths.insert("/t/a.jpg", into: "比较"))
        #expect(DraftPaths.remove("/t/a.jpg", from: draft) == "比较 /t/b.jpg")
        #expect(DraftPaths.remove("/t/a.jpg", from: "/t/a.jpg") == "")
        #expect(DraftPaths.remove("/t/c.jpg", from: draft) == draft)
    }
}
