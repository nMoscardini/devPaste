import AppKit
import ImageIO
import DevPasteCore

/// Bounded image decoding off the main thread (spec: Files and images). A bad image returns nil,
/// it never crashes the app.
enum ImageLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    static func thumbnail(store: HistoryStore, id: String, maxPixel: Int) async -> NSImage? {
        let key = "\(id)-\(maxPixel)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        let cg: CGImage? = await Task.detached(priority: .utility) {
            guard let data = try? store.firstPayload(id: id, utis: PBType.imageTypes) else { return nil }
            return ImageLoader.downsample(data, maxPixel: maxPixel)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        Self.cache.setObject(image, forKey: key)
        return image
    }

    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}
