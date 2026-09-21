import UIKit
import Vision

enum OCRServiceError: Error {
    case unsupported
    case recognitionFailed
}

/// Stateless OCR wrapper. Kept as a `Sendable` value type so it can be called
/// from any actor without an unsafe global singleton reference.
enum OCRService {
    /// Performs on-device text recognition. Runs the Vision request
    /// synchronously on the calling executor; callers off the main actor
    /// (see `UIImage.ocrText()`) get the work off the render path.
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRServiceError.unsupported
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        // Read results off the request after `perform` rather than mutating a
        // captured variable from Vision's callback queue.
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }

        guard !lines.isEmpty else {
            throw OCRServiceError.recognitionFailed
        }
        return lines.joined(separator: "\n")
    }
}

extension UIImage {
    /// Detached so a large screenshot never blocks the main actor while Vision runs.
    func ocrText() async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try await OCRService.recognizeText(in: self)
        }.value
    }
}

extension MessageAttachment {
    func ocrText() async throws -> String {
        guard let image = UIImage(data: data) else {
            throw OCRServiceError.unsupported
        }
        return try await image.ocrText()
    }
}