import Foundation
import Testing
import UIKit

@testable import Yochi

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

    /// The Gateway's rule: ASCII letters, digits and `.-_`, not starting with a dot, at most 100.
    private func accepted(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return !name.isEmpty && name.count <= 100 && !name.hasPrefix(".") && name.allSatisfy(allowed.contains)
    }

    @Test("A file's name is made one the Gateway accepts, never a path")
    func sanitizedNames() {
        #expect(AttachmentName.sanitized("report.pdf") == "report.pdf")
        #expect(AttachmentName.sanitized("my notes (v2).txt") == "my_notes__v2_.txt")
        #expect(AttachmentName.sanitized("../../etc/passwd") == "_.._etc_passwd")
        #expect(AttachmentName.sanitized(".hidden") == "hidden")
        #expect(AttachmentName.sanitized("日本語.md") == "___.md")
        #expect(AttachmentName.sanitized("日本語") == "file", "nothing left to say")
        #expect(AttachmentName.sanitized("") == "file")
        let long = AttachmentName.sanitized(String(repeating: "a", count: 300) + ".swift")
        #expect(long.count == 100 && long.hasSuffix(".swift"))
        for name in ["a/b", "x\u{0}y", "..", "...", " ", "~", "a b.c", String(repeating: "é", count: 150)] {
            #expect(accepted(AttachmentName.sanitized(name)), "\(name)")
        }
    }

    @Test("A file the Gateway can't take in one piece is known before it goes")
    func sizeLimit() {
        #expect(ImageAttachment.maxBytes == 8 * 1024 * 1024)
        let file = ImageAttachment(thumbnail: nil, data: Data(), name: "a.bin")
        #expect(file.isFile)
        #expect(!ImageAttachment(thumbnail: UIImage(), data: Data(), name: "a.jpg").isFile)
    }
}
