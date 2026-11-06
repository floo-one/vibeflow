// Draws the app icons into VibeFlow/Assets.xcassets: AppIcon for Maagical and AppIconDev for
// Maagical Dev (orange, with a DEV band), so the two apps look different in Finder, Spotlight
// and System Settings (docs/designs/dev-prod-channels.md, P3). The same master also becomes the
// website's favicon.png (64 px) and apple-touch-icon.png (180 px). Run from the repo root after
// changing the design:
//
//   swift scripts/make-icons.swift
//
// The mark is "the ace": a white playing card on a flat indigo tile, an A in two corners and
// the five voice bars as its suit, the middle one gold (docs/designs/maagical-brand.md).
// Everything is rectangles, circles and one system font, so this file is the whole design.

import AppKit

struct Style {
    let name: String
    /// The tile; also the ink of the card's A's and outer bars.
    let tile: NSColor
    let devBand: Bool
}

let gold = NSColor(srgbRed: 0.961, green: 0.722, blue: 0.180, alpha: 1)   // #F5B82E

let styles = [
    Style(name: "AppIcon",
          tile: NSColor(srgbRed: 0.227, green: 0.184, blue: 0.749, alpha: 1),  // #3A2FBF indigo
          devBand: false),
    Style(name: "AppIconDev",
          tile: NSColor(srgbRed: 0.949, green: 0.478, blue: 0.102, alpha: 1),  // #F27A1A orange
          devBand: true),
]

/// An sRGB canvas that AppKit drawing goes into.
@MainActor func canvas(_ pixels: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

/// 1024 x 1024 on the macOS icon grid: an 824 x 824 rounded square with a soft shadow, a white
/// card with an A top left and bottom right (turned, like a real card), five bars in the
/// middle, and for Dev a dark band with DEV across the bottom.
@MainActor func icon(_ style: Style) -> CGImage {
    canvas(1024) { context in
        let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 28
        shadow.set()
        style.tile.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 292, y: 180, width: 440, height: 664), xRadius: 48, yRadius: 48).fill()

        // The suit: five bars centred on the card, the tallest in the middle and gold.
        let heights: [CGFloat] = [110, 190, 260, 190, 110]
        let barWidth: CGFloat = 36, gap: CGFloat = 22, centerY: CGFloat = 512
        var x = 512 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap) / 2
        for (i, height) in heights.enumerated() {
            (i == heights.count / 2 ? gold : style.tile).setFill()
            let bar = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }

        // The corner A's. draw(at:) takes the line's bottom, below the baseline, so the baseline
        // sits at the given y when the descender is added.
        let font = NSFont.systemFont(ofSize: 120, weight: .black)
        let a = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: style.tile])
        a.draw(at: NSPoint(x: 340, y: 712 + font.descender))
        context.saveGState()
        context.translateBy(x: 684, y: 312)
        context.rotate(by: .pi)
        a.draw(at: NSPoint(x: 0, y: font.descender))
        context.restoreGState()

        if style.devBand {
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            NSColor.black.withAlphaComponent(0.28).setFill()
            NSRect(x: 100, y: 100, width: 824, height: 160).fill()
            let font = NSFont.systemFont(ofSize: 118, weight: .black)
            let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white])
            // Center the capitals in the band; draw(at:) takes the line's bottom, below the baseline.
            let baseline = 100 + (160 - font.capHeight) / 2
            text.draw(at: NSPoint(x: 512 - text.size().width / 2, y: baseline + font.descender))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

@MainActor func png(_ image: CGImage, pixels: Int) -> Data {
    let scaled = canvas(pixels) { context in
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }
    return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])!
}

@MainActor func writeCatalog() throws {
    let catalog = URL(fileURLWithPath: "VibeFlow/Assets.xcassets")
    let files = FileManager.default
    try files.createDirectory(at: catalog, withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))

    for style in styles {
        let master = icon(style)
        let folder = catalog.appendingPathComponent("\(style.name).appiconset")
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var images: [[String: String]] = []
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(master, pixels: points * scale).write(to: folder.appendingPathComponent(name))
                images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
            }
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("Contents.json"))
        print("Wrote \(folder.path)")

        // The website shows the release icon (website/src/layouts/Base.astro).
        if !style.devBand {
            let site = URL(fileURLWithPath: "website/public")
            try png(master, pixels: 64).write(to: site.appendingPathComponent("favicon.png"))
            try png(master, pixels: 180).write(to: site.appendingPathComponent("apple-touch-icon.png"))
            print("Wrote \(site.path)/favicon.png and apple-touch-icon.png")
        }
    }
}

// A script's top level runs on the main thread but is not main-actor isolated in Swift 6.
try MainActor.assumeIsolated { try writeCatalog() }
