import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

enum ImageBackgroundRemovalError: Error {
    case unsupported
    case processingFailed
}

extension UIImage {
    func removingBackground() async throws -> UIImage {
        try await ImageBackgroundRemover.removeBackground(from: self)
    }
}

/// On-device subject/background separation using Vision's foreground instance
/// mask. Stateless, so it is exposed as an enum namespace instead of a shared
/// mutable singleton — callable from any actor.
enum ImageBackgroundRemover {
    /// `CIContext` is Sendable and safe to share across threads for rendering;
    /// keeping one instance avoids repeatedly paying for context creation.
    private static let ciContext = CIContext()

    static func removeBackground(from image: UIImage) async throws -> UIImage {
        // Vision's handler is synchronous and CPU/GPU heavy; keep it off the
        // main actor so background removal never stalls the UI.
        try await Task.detached(priority: .userInitiated) {
            try performRemoval(from: image)
        }.value
    }

    private static func performRemoval(from image: UIImage) throws -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            throw ImageBackgroundRemovalError.unsupported
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            // No subject detected (flat image, text-only screenshot, etc.).
            throw ImageBackgroundRemovalError.processingFailed
        }

        // Scales the mask to the source image so the blend stays pixel-aligned.
        let maskBuffer = try result.generateScaledMaskForImage(
            forInstances: result.allInstances,
            from: handler
        )
        let maskCIImage = CIImage(cvPixelBuffer: maskBuffer)

        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = ciImage
        blendFilter.maskImage = maskCIImage
        blendFilter.backgroundImage = CIImage.empty()

        guard let outputCI = blendFilter.outputImage,
              let cgImage = ciContext.createCGImage(outputCI, from: outputCI.extent)
        else {
            throw ImageBackgroundRemovalError.processingFailed
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}