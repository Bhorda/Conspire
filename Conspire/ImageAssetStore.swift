//
//  ImageAssetStore.swift
//  Conspire
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turning image files into something cheap to draw.
///
/// The whole strategy is one decode per image. An imported file is downscaled
/// once to a display asset and that is what gets handed to a `CALayer`, which
/// the GPU then resamples at any zoom for free. There is no automatic
/// level-of-detail and no cache eviction, because there is nothing to evict:
/// one image, one decode. When enlarging an image outruns its pixels, the user
/// asks for a resample and we build a bigger display asset from the original.
/// An image ready to be put on the board, prepared off the main actor.
struct PreparedImage: Sendable {
    let originalData: Data
    let displayData: Data
    let nativePixelSize: CGSize
    let displayPixelCap: Int
}

enum ImageCodec {
    /// Long edge of the display asset at import.
    static let baseDisplayCap = 1024
    /// Hard ceiling for a resample, whatever the original's resolution.
    static let maxDisplayCap = 4096

    /// Pixel size as it will be *shown*, i.e. with any EXIF quarter turn
    /// already accounted for. Reading the properties does not decode the image.
    static func orientedPixelSize(of data: Data) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double,
            let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }

        // Orientations 5…8 are the quarter turns, where the stored pixels are
        // transposed relative to how the picture is meant to be seen.
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Decode straight to `longEdgeCap` rather than decoding full size and
    /// shrinking — ImageIO's thumbnail path never materialises the full image,
    /// which is the difference between a hitch and no hitch on a phone photo.
    static func decodeDownscaled(_ data: Data, longEdgeCap: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, so portrait photos are upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdgeCap,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The display asset: downscaled bytes plus the pixel size they came out at.
    static func downscaled(_ data: Data, longEdgeCap: Int) -> (data: Data, pixelSize: CGSize)? {
        guard
            let image = decodeDownscaled(data, longEdgeCap: longEdgeCap),
            let encoded = encode(image)
        else { return nil }
        return (encoded, CGSize(width: image.width, height: image.height))
    }

    /// Decode an already-downscaled display asset at its own size.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
    }

    private static func encode(_ image: CGImage) -> Data? {
        for type in encodingCandidates(for: image) {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, type.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            )
            if CGImageDestinationFinalize(destination), out.length > 0 { return out as Data }
        }
        return nil
    }

    /// Transparency has to survive the round trip, so an image with alpha goes
    /// to PNG. Everything else prefers HEIC and falls back to JPEG, since HEIC
    /// encoding is not available for every colour space.
    private static func encodingCandidates(for image: CGImage) -> [UTType] {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return [.heic, .jpeg]
        default:
            return [.png]
        }
    }

    // MARK: - Preparing an import

    /// Read and downscale off the main actor. A phone photo decoded on the main
    /// thread is a visible hitch, and this is the one slow step.
    static func prepare(contentsOf url: URL) async -> PreparedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return prepare(originalData: data)
        }.value
    }

    static func prepare(data: Data) async -> PreparedImage? {
        await Task.detached(priority: .userInitiated) { prepare(originalData: data) }.value
    }

    static func prepare(originalData: Data) -> PreparedImage? {
        guard let native = orientedPixelSize(of: originalData) else { return nil }
        let cap = baseCap(nativeLongEdge: max(native.width, native.height))
        guard let display = downscaled(originalData, longEdgeCap: cap) else { return nil }
        return PreparedImage(
            originalData: originalData,
            displayData: display.data,
            nativePixelSize: native,
            displayPixelCap: cap
        )
    }

    /// The cap to build the display asset at on import — never larger than the
    /// original, which is why a small image is left alone.
    static func baseCap(nativeLongEdge: CGFloat) -> Int {
        min(baseDisplayCap, max(1, Int(nativeLongEdge.rounded())))
    }

    /// The cap that would make an image sharp at the size it is currently being
    /// shown: twice its world long edge for retina, floored at the import cap
    /// and never above the original's own resolution.
    static func neededCap(forWorldLongEdge worldLongEdge: CGFloat, nativeLongEdge: CGFloat) -> Int {
        let floor = baseCap(nativeLongEdge: nativeLongEdge)
        let ceiling = max(min(max(1, Int(nativeLongEdge.rounded())), maxDisplayCap), floor)
        let wanted = Int((max(worldLongEdge, 0) * 2).rounded())
        return min(max(wanted, floor), ceiling)
    }

    /// Whether resampling would visibly help, so the menu item can stay absent
    /// when it would do nothing — including for an image already at its
    /// original resolution.
    static func resampleWorthwhile(currentCap: Int, neededCap: Int) -> Bool {
        neededCap > Int(Double(currentCap) * 1.25)
    }
}

extension ImageAsset {
    /// Import geometry: `longEdge` across the longer side, aspect preserved,
    /// centred on the drop point.
    static func importRect(
        centeredAt worldCenter: CGPoint,
        pixelSize: CGSize,
        longEdge: CGFloat
    ) -> CGRect {
        let native = max(pixelSize.width, pixelSize.height)
        guard native > 0, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGRect(
                x: worldCenter.x - longEdge / 2, y: worldCenter.y - longEdge / 2,
                width: longEdge, height: longEdge
            )
        }
        let factor = longEdge / native
        let size = CGSize(width: pixelSize.width * factor, height: pixelSize.height * factor)
        return CGRect(
            x: worldCenter.x - size.width / 2,
            y: worldCenter.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Resize keeping the aspect of the original, driven by the corner handle.
    /// The top-left corner stays put, so the handle is the only thing that moves.
    func resized(toCornerWorld corner: CGPoint, minimumLongEdge: CGFloat) -> CGRect {
        let origin = worldRect.origin
        let proposedWidth = corner.x - origin.x
        let proposedHeight = corner.y - origin.y
        // Follow whichever axis the pointer pushed furthest, so the drag feels
        // direct rather than snapping between the two.
        let fromWidth = max(proposedWidth, 0)
        let fromHeight = max(proposedHeight, 0) * aspect
        var width = max(fromWidth, fromHeight)
        let minWidth = aspect >= 1 ? minimumLongEdge : minimumLongEdge * aspect
        width = max(width, minWidth)
        return CGRect(origin: origin, size: CGSize(width: width, height: width / aspect))
    }
}
