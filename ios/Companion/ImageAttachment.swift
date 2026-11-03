import SwiftUI
import UIKit

/// A photo for the Agent: shrunk on the phone, put beside the terminal, and
/// named in the draft by its path, which Claude Code opens as an image.
struct ImageAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case uploaded(path: String)
        case failed(String)
    }

    let id = UUID()
    let thumbnail: UIImage
    let jpeg: Data
    let name: String
    var state: State = .uploading

    static let limit = 4
}

enum ImageShrinker {
    static let longEdge: CGFloat = 2048
    static let quality: CGFloat = 0.8

    /// A JPEG at most 2048 pixels on its long edge, upright.
    static func jpeg(from image: UIImage) -> Data? {
        render(image, longEdge: longEdge).jpegData(compressionQuality: quality)
    }

    static func thumbnail(from image: UIImage) -> UIImage {
        render(image, longEdge: 240)
    }

    /// Times keep names apart; core adds a suffix if one is taken anyway.
    static func name(at date: Date, index: Int) -> String {
        let format = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian))
        return "image-\(date.formatted(format))-\(index).jpg"
    }

    private static func render(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let ratio = min(1, longEdge / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: (pixels.width * ratio).rounded(), height: (pixels.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing applies the photo's orientation, so the JPEG needs none.
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The image paths an attachment adds to and takes out of the draft.
enum DraftPaths {
    static func insert(_ path: String, into draft: String) -> String {
        guard let last = draft.last else { return path }
        return last.isWhitespace ? draft + path : draft + " " + path
    }

    static func remove(_ path: String, from draft: String) -> String {
        var draft = draft
        if let range = draft.range(of: " " + path) ?? draft.range(of: path) {
            draft.removeSubrange(range)
        }
        return draft
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let take: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.take(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// The photos waiting to go with the next message, above the composer.
struct AttachmentStrip: View {
    let attachments: [ImageAttachment]
    let remove: (ImageAttachment.ID) -> Void
    let retry: (ImageAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    thumbnail(attachment, number: index + 1)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
        }
        .accessibilityIdentifier("attachments")
    }

    private func thumbnail(_ attachment: ImageAttachment, number: Int) -> some View {
        Image(uiImage: attachment.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 60, height: 60)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay { overlay(attachment) }
            .overlay(alignment: .topTrailing) {
                Button { remove(attachment.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .offset(x: 8, y: -8)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("图片 \(number)")
            .accessibilityValue(stateText(attachment.state))
            .accessibilityAction(named: "移除") { remove(attachment.id) }
            .accessibilityActions {
                if case .failed = attachment.state {
                    Button("重试") { retry(attachment.id) }
                }
            }
            .accessibilityIdentifier("attachment-\(number)")
    }

    @ViewBuilder
    private func overlay(_ attachment: ImageAttachment) -> some View {
        switch attachment.state {
        case .uploading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.3), in: .rect(cornerRadius: 10, style: .continuous))
        case .failed:
            Button { retry(attachment.id) } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.red.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
            }
            .accessibilityHidden(true)
        case .uploaded:
            EmptyView()
        }
    }

    private func stateText(_ state: ImageAttachment.State) -> String {
        switch state {
        case .uploading: "上传中"
        case .uploaded: "已上传"
        case .failed(let message): "上传失败：\(message)，可重试"
        }
    }
}
