import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import MaagicalCore

/// Draws a role's wallpaper (docs/designs/desktop-roles.md): the background (Apple's Radial in the
/// role color, the plain color, or a picture), with the role name large and faint in the
/// bottom-left corner. The same drawing makes the screen-sized file and the Settings thumbnails;
/// thumbnails draw from small sources (Apple's own 356 px wallpaper thumbnail, a picture decoded
/// at 400 px), because a 6K source drawn down to 64 px made Settings > Desktops crawl.
/// Safe off the main thread: LiveDesktops renders the screen files in the background.
enum RoleWallpaper {
    /// Draws into the current graphics context, filling `rect`. `showsName` is off for thumbnails.
    static func draw(_ background: RoleBackground, colorHex: String, name: String, in rect: NSRect,
                     showsName: Bool = true, small: Bool = false) {
        let color = NSColor(hex: colorHex)
        switch background {
        case .colored(let style):
            drawStyle(style, color: color, in: rect, small: small)
        case .image(let path):
            if let image = picture(at: path, maxPixels: small ? 400 : 6144) {
                drawFilling(image, in: rect)
            } else {
                // A picture that was moved or deleted: the plain color, so the role still reads.
                drawStyle(.solid, color: color, in: rect, small: small)
            }
        }
        guard showsName, !name.isEmpty else { return }
        // Large enough to read across the room, faint enough not to fight the windows on top.
        // The shadow keeps it readable on light pictures.
        // A busy background (Radial, a picture) needs a brighter name and a firmer shadow.
        let busy = background != .colored(.solid)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(busy ? 0.55 : 0.25)
        shadow.shadowBlurRadius = rect.height * (busy ? 0.012 : 0.006)
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.09, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(busy ? 0.6 : 0.28),
            .shadow: shadow,
        ])
        let margin = rect.height * 0.05
        text.draw(at: NSPoint(x: rect.minX + margin, y: rect.minY + margin))
    }

    nonisolated(unsafe) private static let thumbnails = NSCache<NSString, NSImage>()

    /// A finished bitmap at twice `size`, cached per background, color and size: SwiftUI asks for
    /// it on every rebuild of the Desktops pane.
    static func thumbnail(_ background: RoleBackground, colorHex: String, size: NSSize) -> NSImage {
        let key = "\(background)|\(colorHex.uppercased())|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let image = NSImage(size: size)
        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            draw(background, colorHex: colorHex, name: "", in: NSRect(origin: .zero, size: size), showsName: false, small: true)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    // MARK: Styles

    private static func drawStyle(_ style: BackgroundStyle, color: NSColor, in rect: NSRect, small: Bool) {
        // An Apple wallpaper not downloaded yet shows as Radial on the desktop (its thumbnail
        // works from Apple's preview); a macOS without the pictures gets the plain color.
        let shown = small || AppleWallpaper.isOnThisMac(style) ? style : .radial
        if shown != .solid, let image = AppleWallpaper.image(shown, in: color, small: small) {
            drawFilling(image, in: rect)
        } else {
            color.setFill()
            rect.fill()
        }
    }

    /// Aspect fill, centered, like macOS's "Fill Screen".
    private static func drawFilling(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let target = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        image.draw(in: target, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Pictures

    /// Pictures are big (a system wallpaper is 6K): decoded once per path and size.
    nonisolated(unsafe) private static let pictures = NSCache<NSString, NSImage>()

    static func picture(at path: String, maxPixels: Int, index: Int = 0) -> NSImage? {
        let key = "\(path)|\(maxPixels)|\(index)" as NSString
        if let cached = pictures.object(forKey: key) { return cached }
        let url = URL(fileURLWithPath: path) as CFURL
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, min(index, max(CGImageSourceGetCount(source) - 1, 0)), options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        pictures.setObject(image, forKey: key)
        return image
    }

    // MARK: Files

    /// Where the wallpaper file for `role` at `pixels` lives. macOS caches wallpapers by URL, so
    /// every change (color, style, picture, name, size) gets a new file name.
    static func url(for role: DesktopRole, pixels: NSSize) throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "one.floo.vibeflow", isDirectory: true)
            .appendingPathComponent("Tints", isDirectory: true)
        // A flat color compresses to almost nothing as PNG; Apple's Radial and photos stay far
        // smaller as JPEG (a 5K photo PNG is tens of MB).
        let ext = role.background == .colored(.solid) ? "png" : "jpg"
        return folder.appendingPathComponent("role-\(key(role))-\(Int(pixels.width))x\(Int(pixels.height)).\(ext)")
    }

    /// Draws the wallpaper file at `url` (from `url(for:pixels:)`). Takes a moment at 5K: run it
    /// off the main thread.
    static func render(_ role: DesktopRole, pixels: NSSize, to url: URL) throws {
        let width = Int(pixels.width), height = Int(pixels.height)
        let isFlat = url.pathExtension == "png"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw(role.background, colorHex: role.colorHex, name: role.name, in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let data = isFlat
            ? bitmap.representation(using: .png, properties: [:])
            : bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    /// A short stable name for everything the picture depends on, including the picture file's
    /// date, so replacing a picture at the same path redraws.
    private static func key(_ role: DesktopRole) -> String {
        var parts = [role.colorHex.uppercased(), role.name]
        switch role.background {
        case .colored(let style):
            // Downloading the Apple picture later changes the name, so the desktop redraws.
            parts.append(style.rawValue + (AppleWallpaper.isOnThisMac(style) ? "" : "-pending"))
        case .image(let path):
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            parts += [path, String(Int(modified))]
        }
        // FNV-1a: stable across launches, unlike hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "|").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Apple's wallpapers turned to any color: the hue rotates to the color's and the saturation
/// scales to it, so Apple's own light and shading stay. Picked from a recolor test of the
/// wallpapers macOS lists (docs/designs/desktop-roles.md): Radial, Motion, iMac, hello and
/// Chroma are close enough to one hue to recolor cleanly; photos and multi-color ones are not.
/// Radial and iMac ship with macOS; Motion, hello and Chroma download the first time they are
/// picked in System Settings > Wallpaper, into ~/Library/Application Support/com.apple.mobileAssetDesktop.
/// Thumbnails always work, from Apple's 356 px previews in Desktop Pictures/.thumbnails.
enum AppleWallpaper {
    private struct Source {
        /// The full picture: shipped in Desktop Pictures, or downloaded under this asset name.
        let shipped: String?
        let asset: String?
        /// Apple's preview, in Desktop Pictures/.thumbnails.
        let preview: String
        /// Dynamic pictures hold a light and a dark image; hello and Chroma look best dark.
        let dark: Bool
    }

    private static let pictures = "/System/Library/Desktop Pictures/"
    private static let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop").path
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!

    private static func source(_ style: BackgroundStyle) -> Source? {
        switch style {
        case .radial: return Source(shipped: "Radial Sky Blue", asset: nil, preview: "Radial Sky Blue", dark: false)
        case .imac: return Source(shipped: "iMac Blue", asset: nil, preview: "iMac Blue", dark: false)
        case .motion: return Source(shipped: nil, asset: "Motion Blue", preview: "Motion Blue", dark: false)
        case .hello: return Source(shipped: nil, asset: "hello Blue", preview: "hello Blue Dark", dark: true)
        case .chroma: return Source(shipped: nil, asset: "Chroma Blue", preview: "Chroma Blue Dark", dark: true)
        case .solid: return nil
        }
    }

    /// The full-size picture on this Mac, nil while it still needs downloading.
    private static func fullPath(_ style: BackgroundStyle) -> String? {
        guard let source = source(style) else { return nil }
        let candidates = [source.shipped.map { pictures + $0 + ".heic" }, source.asset.map { downloads + "/" + $0 + ".heic" }]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Solid always is; an Apple picture once its full size is on disk.
    static func isOnThisMac(_ style: BackgroundStyle) -> Bool {
        style == .solid || fullPath(style) != nil
    }

    /// Apple's own name for the picture, for the "get it in System Settings" hint.
    static func appleName(_ style: BackgroundStyle) -> String? {
        source(style)?.asset ?? source(style)?.shipped
    }

    nonisolated(unsafe) private static let recolored = NSCache<NSString, NSImage>()
    private static let context = CIContext()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sourceHSB: [BackgroundStyle: (hue: CGFloat, saturation: CGFloat)] = [:]

    private static func previewImage(_ style: BackgroundStyle) -> NSImage? {
        guard let source = source(style) else { return nil }
        return RoleWallpaper.picture(at: pictures + ".thumbnails/" + source.preview + ".heic", maxPixels: 400)
    }

    /// The picture's own average hue and saturation, measured once on Apple's preview.
    private static func hsb(_ style: BackgroundStyle) -> (hue: CGFloat, saturation: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        if let known = sourceHSB[style] { return known }
        var measured: (hue: CGFloat, saturation: CGFloat) = (0.6, 0.4)
        if let preview = previewImage(style), let cgImage = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            measured = average(of: CIImage(cgImage: cgImage))
        }
        sourceHSB[style] = measured
        return measured
    }

    static func image(_ style: BackgroundStyle, in color: NSColor, small: Bool) -> NSImage? {
        guard let source = source(style) else { return nil }
        let target = color.usingColorSpace(.sRGB) ?? color
        let key = "\(style.rawValue)|\(target.hexString)|\(small)" as NSString
        if let cached = recolored.object(forKey: key) { return cached }
        let picture: NSImage?
        if small {
            picture = previewImage(style)
        } else if let path = fullPath(style) {
            picture = RoleWallpaper.picture(at: path, maxPixels: 6144, index: source.dark ? darkIndex(path) : lightIndex(path))
        } else {
            picture = nil
        }
        guard let picture, let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let image = CIImage(cgImage: cgImage)
        let from = hsb(style)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        target.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = CIFilter.hueAdjust()
        hue.inputImage = image
        hue.angle = Float((h - from.hue) * 2 * .pi)
        let controls = CIFilter.colorControls()
        controls.inputImage = hue.outputImage
        // Grey roles get a grey picture; vivid ones may go a little past Apple's saturation.
        controls.saturation = Float(min(max(s / max(from.saturation, 0.05), 0.1), 1.6))
        controls.brightness = 0
        controls.contrast = 1
        guard let output = controls.outputImage,
              let result = context.createCGImage(output, from: image.extent)
        else { return nil }
        let recoloredImage = NSImage(cgImage: result, size: picture.size)
        recolored.setObject(recoloredImage, forKey: key)
        return recoloredImage
    }

    // MARK: Light and dark

    /// Dynamic HEICs say which image is light and which dark in their metadata: "apr" for
    /// light/dark ones, "solar" (its "ap") for ones that follow the sun.
    private static func appearance(_ path: String) -> (light: Int, dark: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]
        else { return nil }
        for tag in tags {
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            guard name == "apr" || name == "solar",
                  let base64 = CGImageMetadataTagCopyValue(tag) as? String,
                  let data = Data(base64Encoded: base64),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let pair = (name == "solar" ? plist["ap"] as? [String: Any] : plist) ?? [:]
            if let light = (pair["l"] as? NSNumber)?.intValue, let dark = (pair["d"] as? NSNumber)?.intValue {
                return (light, dark)
            }
        }
        return nil
    }

    private static func darkIndex(_ path: String) -> Int { appearance(path)?.dark ?? 1 }
    private static func lightIndex(_ path: String) -> Int { appearance(path)?.light ?? 0 }

    private static func average(of image: CIImage) -> (hue: CGFloat, saturation: CGFloat) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let output = filter.outputImage else { return (0.55, 0.4) }
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s)
    }
}
