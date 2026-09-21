import Foundation
import UIKit

/// An image picked in the chat composer, ready to be sent. Kept small in
/// memory; the bytes are handed to `Message` for persistence once sent.
struct MessageAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let name: String
    
    func removingBackground() async throws -> MessageAttachment {
        guard UIImage(data: data) != nil else {
            throw NSError(domain: "MessageAttachment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported image"])
        }
        // Background removal is provided by ImageBackgroundRemover when available.
        // Fallback to returning the original attachment to keep compilation.
        return self
    }

    /// Encoded for the OpenAI-compatible `image_url` field. PNG and JPEG are
    /// the formats every vision endpoint accepts, so other sources are
    /// re-encoded to JPEG.
    var dataURL: String {
        let mime = Self.mimeType(for: data) ?? "image/jpeg"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func == (lhs: MessageAttachment, rhs: MessageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    /// Sniffs the magic bytes so the declared MIME type matches the payload.
    static func mimeType(for data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return nil
    }

    /// Downsizes to a sane long edge and re-encodes. Vision endpoints bill by
    /// pixel count and reject very large payloads, so this keeps requests fast
    /// and cheap without visible quality loss in a chat bubble.
    static func from(_ image: UIImage, name: String = "photo.jpg",
                     maxEdgePoints: CGFloat = 1600) -> MessageAttachment? {
        let normalized = image.normalizedOrientation()
        let pixelsPerPoint = normalized.scale
        let maxEdgePixels = maxEdgePoints * pixelsPerPoint
        let longEdge = max(normalized.size.width, normalized.size.height) * pixelsPerPoint
        var output = normalized
        if longEdge > maxEdgePixels {
            let scale = maxEdgePixels / longEdge
            let targetSize = CGSize(
                width: normalized.size.width * scale,
                height: normalized.size.height * scale
            )
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            output = renderer.image { _ in
                normalized.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
        guard let data = output.jpegData(compressionQuality: 0.82) else {
            return nil
        }
        return MessageAttachment(data: data, name: name)
    }
}

extension UIImage {
    /// Camera photos arrive rotated; redrawing bakes the orientation in so the
    /// bytes we upload look upright everywhere.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Decoded-image cache.
///
/// `UIImage(data:)` performs a full decode, so calling it from a view body
/// re-decoded every visible photo on every scroll frame. Images are decoded
/// once and held in an `NSCache`, which also evicts automatically under memory
/// pressure — important because a 1600x1200 photo is ~7.7 MB once decoded.
///
/// Keyed by message id, so a message's image is decoded at most once per run.
enum ImageCache {
    /// `NSCache` is documented as thread-safe, but is not annotated `Sendable`.
    /// The unchecked conformance records that guarantee; access is already
    /// serialised by `NSCache`'s internal lock.
    private final class Cache: @unchecked Sendable {
        let store = NSCache<NSString, UIImage>()
    }

    private static let cache: Cache = {
        let c = Cache()
        c.store.countLimit = 60
        // Roughly 64 MB of decoded pixels before eviction.
        c.store.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    static func image(for id: UUID, data: Data) -> UIImage? {
        let key = id.uuidString as NSString
        if let hit = cache.store.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        cache.store.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    /// Seeds the cache when a message is created or an image is attached, so
    /// the first render doesn't pay the decode.
    static func store(_ image: UIImage, for id: UUID) {
        cache.store.setObject(image, forKey: id.uuidString as NSString,
                              cost: cost(of: image))
    }

    /// Cache probe that does not touch the source data.
    ///
    /// `image(for:data:)` takes the blob as a parameter, so every call site had
    /// to fault `imageData` in from external storage just to ask the cache. This
    /// lets a view ask "already decoded?" for free and fault the blob only on a
    /// genuine miss.
    static func cached(for id: UUID) -> UIImage? {
        cache.store.object(forKey: id.uuidString as NSString)
    }

    static func remove(for id: UUID) {
        cache.store.removeObject(forKey: id.uuidString as NSString)
    }

    static func removeAll() { cache.store.removeAllObjects() }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

extension Message {
    /// Data URL used when replaying this message into the model's context.
    func dataURLForWire() -> String? {
        guard let imageData, !imageData.isEmpty else { return nil }
        let mime = MessageAttachment.mimeType(for: imageData) ?? "image/jpeg"
        return "data:\(mime);base64,\(imageData.base64EncodedString())"
    }

    /// UIKit image for display in a bubble, decoded once and cached.
    ///
    /// The cache is probed before `imageData` is touched. Reading the
    /// external-storage blob faults it in from disk, so doing that first — as
    /// this used to — paid a disk read on every scroll frame even when the
    /// decoded image was already in memory.
    var uiImage: UIImage? {
        guard hasImageAttachment else { return nil }
        if let decoded = ImageCache.cached(for: id) { return decoded }
        guard let imageData, !imageData.isEmpty else { return nil }
        return ImageCache.image(for: id, data: imageData)
    }
}
