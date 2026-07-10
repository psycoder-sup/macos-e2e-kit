import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Pure helper that normalizes an image before it's used elsewhere (e.g. as a screenshot attachment or an
/// upload). Only depends on ImageIO/CoreGraphics — no SwiftUI/NSImage/NSPasteboard (clipboard/file-picker
/// concerns belong to the host app).
///
/// Normalization is (1) decode → (2) downscale to a max long-edge cap (2000px) → (3) re-encode as PNG/JPEG
/// **without carrying over** source metadata (drops EXIF/GPS) → (4) enforce a size ceiling (5 MiB) (JPEG
/// retries at lower quality). Non-PNG inputs (HEIC, etc.) export as JPEG; PNG inputs export as lossless PNG
/// (falling back to JPEG if the PNG exceeds the ceiling).
public enum ImageAttachment {
    /// Max number of attachments allowed at once.
    public static let maxAttachmentCount = 3

    /// Max long-edge length (px) used as the downscale basis. Images larger than this are fit to this value
    /// while preserving aspect ratio.
    public static let maxPixelSize = 2000

    /// Encoded-result size ceiling (5 MiB). JPEG steps quality down to fit; throws if it still exceeds the
    /// ceiling at the lowest quality.
    public static let maxByteSize = 5 * 1024 * 1024

    /// JPEG re-encode quality steps — tried in order, adopting the first result at or under the ceiling.
    private static let jpegQualitySteps: [CGFloat] = [0.85, 0.7, 0.55, 0.4, 0.3, 0.2]

    /// Normalization result — an inline base64 payload.
    public struct Payload: Sendable, Codable, Equatable {
        public let filename: String
        /// Only ever `"image/png"` or `"image/jpeg"`.
        public let contentType: String
        public let dataBase64: String

        public init(filename: String, contentType: String, dataBase64: String) {
            self.filename = filename
            self.contentType = contentType
            self.dataBase64 = dataBase64
        }
    }

    public enum NormalizeError: Error, Equatable {
        /// Input isn't an image, or is corrupt and fails to decode.
        case unsupportedImage
        /// CGImageDestination encoding itself failed.
        case encodingFailed
        /// Still exceeds the size ceiling even at the lowest quality.
        case tooLargeAfterCompression
    }

    /// Normalizes image `Data` (PNG/JPEG/HEIC) into a base64 payload. `maxPixelSize`/`maxByteSize` default to
    /// the standard caps but are exposed as parameters so tests (or callers) can inject their own.
    public static func normalize(
        _ data: Data,
        filename: String,
        maxPixelSize: Int = ImageAttachment.maxPixelSize,
        maxByteSize: Int = ImageAttachment.maxByteSize
    ) throws -> Payload {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw NormalizeError.unsupportedImage
        }
        // Output format follows the source type — PNG stays lossless, everything else (JPEG/HEIC/etc.) becomes JPEG.
        let isPNG = (CGImageSourceGetType(source) as String?)
            .flatMap { UTType($0)?.conforms(to: .png) } ?? false

        // Thumbnail downscaled to the max long edge. WithTransform bakes EXIF orientation into the pixels,
        // making the orientation metadata moot.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NormalizeError.unsupportedImage
        }

        // PNG sources stay lossless PNG (the main screenshot case). Falls through to the JPEG path below if
        // it exceeds the ceiling.
        if isPNG, let png = encode(image, as: .png, quality: nil), png.count <= maxByteSize {
            return payload(png, contentType: "image/png", filename: filename, ext: "png")
        }

        // JPEG path — steps quality down, adopting the first result at or under the ceiling.
        var encodedAtLeastOnce = false
        for quality in jpegQualitySteps {
            guard let jpeg = encode(image, as: .jpeg, quality: quality) else { continue }
            encodedAtLeastOnce = true
            if jpeg.count <= maxByteSize {
                return payload(jpeg, contentType: "image/jpeg", filename: filename, ext: "jpg")
            }
        }
        // If encoding itself never succeeded once, it's an encoding failure; otherwise it's a size overflow.
        throw encodedAtLeastOnce ? NormalizeError.tooLargeAfterCompression : NormalizeError.encodingFailed
    }

    // MARK: - Internal

    /// Encodes a CGImage in the given format. Doesn't pass through the source's properties (EXIF/GPS), so
    /// metadata is dropped.
    private static func encode(_ image: CGImage, as type: UTType, quality: CGFloat?) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    private static func payload(_ data: Data, contentType: String, filename: String, ext: String) -> Payload {
        Payload(
            filename: normalizedFilename(filename, ext: ext),
            contentType: contentType,
            dataBase64: data.base64EncodedString()
        )
    }

    /// Replaces the filename's extension to match the output format (empty names become `image`).
    private static func normalizedFilename(_ filename: String, ext: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return "\(stem.isEmpty ? "image" : stem).\(ext)"
    }
}
