import AppKit
import AVFoundation
import ImageIO

enum WallpaperRenderer {
    /// Decodes the wallpaper and produces a sharp and a pre-blurred copy.
    ///
    /// Done once, off the main thread: doing it on the first scroll event is what made the shade
    /// appear only after 100-150px of dragging.
    /// Decodes the wallpaper straight to the size it will be drawn at.
    ///
    /// This used to go through `NSImage.cgImage(forProposedRect:)`, passing the screen rect. That
    /// rect is a *proposal*, not a constraint: `NSImage` hands back the best representation it
    /// has, and macOS wallpapers are square and enormous - the system set is 6016x6016, which is
    /// 145MB decoded. The full bitmap was then kept alive for the life of the app as the sharp
    /// layer's contents, for a screen that can show 4.1 megapixels of it.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` downsamples during decode, so the full-size bitmap
    /// is never materialised at all. Nothing is lost: the image is composited into a screen-sized
    /// box either way, so every pixel beyond that was being thrown away by the compositor.
    ///
    /// `maxPixelSize` bounds the *longer* edge, which is the right constraint here: the layers
    /// draw with `resizeAspectFill`, so a square source must still cover the screen's long side.
    private static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        // `shouldCache` false so the image source does not hold a full-size decoded copy
        // alongside the downsampled one, which would defeat the point.
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
        else { return decodeVideoFrame(url: url, maxPixelSize: maxPixelSize) }
        let options: [CFString: Any] = [
            // Always build from the full image: an embedded thumbnail would be a postage stamp.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on this background thread, rather than lazily on the first frame.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            ?? decodeVideoFrame(url: url, maxPixelSize: maxPixelSize)
    }

    /// The first frame of an animated wallpaper.
    ///
    /// Several of the built-in wallpapers - the Sonoma graphics among them - ship only as `.mov`,
    /// with no still image anywhere beside them. `maximumSize` keeps this to the same budget as
    /// the image path: the generator decodes down to it rather than handing back a full frame.
    private static func decodeVideoFrame(url: URL, maxPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    static func render(url: URL, screen: CGSize, scale: CGFloat,
                       completion: @escaping (CGImage?, CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let maxPixel = Int(max(screen.width, screen.height) * max(scale, 1))
            guard let cg = decode(url: url, maxPixelSize: maxPixel) else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            // Blur at half resolution: it is a blur, so the lost detail is invisible, and it
            // keeps the one-off cost small.
            let ci = CIImage(cgImage: cg)
            let scale = 0.5
            let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.setValue(small, forKey: kCIInputImageKey)
            blur?.setValue(Config.maxBlurRadius * scale, forKey: kCIInputRadiusKey)

            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            var blurredCG: CGImage?
            if let out = blur?.outputImage {
                // Clamp back to the original extent; a blur grows the image.
                blurredCG = ctx.createCGImage(out, from: small.extent)
            }
            DispatchQueue.main.async { completion(cg, blurredCG) }
        }
    }
}
