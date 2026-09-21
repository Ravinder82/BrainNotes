import VisionKit
import UIKit

extension VNDocumentCameraScan {
    var images: [UIImage] {
        (0..<pageCount).compactMap { index in
            imageOfPage(at: index)
        }
    }
    
    func ocrAllPages() async throws -> String {
        var fullText = ""
        for image in images {
            let text = try await image.ocrText()
            fullText += text + "\n\n"
        }
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func firstPageAttachment() -> MessageAttachment? {
        guard pageCount > 0 else { return nil }
        return MessageAttachment.from(imageOfPage(at: 0), name: "scan.jpg")
    }
}
