import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import VibeFlowCore

/// Draws a role's wallpaper (docs/designs/desktop-roles.md): the background (Apple's Radial in the
/// role color, the plain color, or a picture), with the role name large and faint in the bottom-left corner. The
/// same drawing makes the screen-sized file and the Settings thumbnails.
enum RoleWallpaper {
    /// Draws into the current graphics context, filling `rect`. `showsName` is off for thumbnails.
    static func draw(_ background: RoleBackground, colorHex: String, name: String, in rect: NSRect, showsName: Bool = true) {
        let color = NSColor(hex: colorHex)
        switch background {
        case .colored(let style):
            drawStyle(style, color: color, in: rect)
        case .image(let path):
            if let image = picture(at: path) {
                drawFilling(image, in: rect)
            } else {
                // A picture that was moved or deleted: the plain color, so the role still reads.
                drawStyle(.solid, color: color, in: rect)
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

    /// A thumbnail that draws itself at whatever resolution it is shown at.
    static func thumbnail(_ background: RoleBackground, colorHex: String, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            draw(background, colorHex: colorHex, name: "", in: rect, showsName: false)
            return true
        }
    }

    // MARK: Styles

    private static func drawStyle(_ style: BackgroundStyle, color: NSColor, in rect: NSRect) {
        switch style {
        case .solid:
            color.setFill()
            rect.fill()
        case .radial:
            if let image = AppleRadial.image(in: color) {
                drawFilling(image, in: rect)
            } else {
                // A macOS without the picture: the plain color.
                color.setFill()
                rect.fill()
            }
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

    /// Pictures are big (a system wallpaper is 6K): decoded once, at most screen size, per path.
    nonisolated(unsafe) private static let pictures = NSCache<NSString, NSImage>()

    static func picture(at path: String) -> NSImage? {
        if let cached = pictures.object(forKey: path as NSString) { return cached }
        let url = URL(fileURLWithPath: path) as CFURL
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6144,
        ]
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        pictures.setObject(image, forKey: path as NSString)
        return image
    }

    // MARK: Files

    /// The wallpaper file for `role` at `pixels`, written on first use. macOS caches wallpapers by
    /// URL, so every change (color, style, picture, name, size) gets a new file name.
    static func file(for role: DesktopRole, pixels: NSSize) throws -> URL {
        let width = Int(pixels.width), height = Int(pixels.height)
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "one.floo.vibeflow", isDirectory: true)
            .appendingPathComponent("Tints", isDirectory: true)
        // A flat color compresses to almost nothing as PNG; light, gradients and photos stay far
        // smaller as JPEG (a 5K photo PNG is tens of MB).
        let isFlat = role.background == .colored(.solid)
        let url = folder.appendingPathComponent("role-\(key(role))-\(width)x\(height).\(isFlat ? "png" : "jpg")")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        try data.write(to: url)
        return url
    }

    /// A short stable name for everything the picture depends on, including the picture file's
    /// date, so replacing a picture at the same path redraws.
    private static func key(_ role: DesktopRole) -> String {
        var parts = [role.colorHex.uppercased(), role.name]
        switch role.background {
        case .colored(let style):
            parts.append(style.rawValue)
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

/// Apple's Radial wallpaper, which macOS ships in sky blue, turned to any color: the hue rotates
/// to the color's and the saturation scales to it, so Apple's own light and shading stay.
/// Prototyped against the other bundled pictures (Mac, Sonoma Horizon, Tahoe Day): only Radial
/// is close enough to one hue to recolor cleanly.
enum AppleRadial {
    static let path = "/System/Library/Desktop Pictures/Radial Sky Blue.heic"

    nonisolated(unsafe) private static let recolored = NSCache<NSString, NSImage>()
    nonisolated(unsafe) private static var sourceHSB: (hue: CGFloat, saturation: CGFloat)?
    private static let context = CIContext()

    static func image(in color: NSColor) -> NSImage? {
        let target = color.usingColorSpace(.sRGB) ?? color
        let key = target.hexString as NSString
        if let cached = recolored.object(forKey: key) { return cached }
        guard let picture = RoleWallpaper.picture(at: path),
              let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let source = CIImage(cgImage: cgImage)
        let from = sourceHSB ?? average(of: source)
        sourceHSB = from
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        target.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = CIFilter.hueAdjust()
        hue.inputImage = source
        hue.angle = Float((h - from.hue) * 2 * .pi)
        let controls = CIFilter.colorControls()
        controls.inputImage = hue.outputImage
        // Grey roles get a grey Radial; vivid ones may go a little past Apple's saturation.
        controls.saturation = Float(min(max(s / max(from.saturation, 0.05), 0.1), 1.6))
        controls.brightness = 0
        controls.contrast = 1
        guard let output = controls.outputImage,
              let result = context.createCGImage(output, from: source.extent)
        else { return nil }
        let image = NSImage(cgImage: result, size: picture.size)
        recolored.setObject(image, forKey: key)
        return image
    }

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
