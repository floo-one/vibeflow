// Draws the app icons into VibeFlow/Assets.xcassets: AppIcon for VibeFlow and AppIconDev for
// VibeFlow Dev (orange, with a DEV band), so the two apps look different in Finder, Spotlight
// and System Settings (docs/designs/dev-prod-channels.md, P3). Run from the repo root after
// changing the design:
//
//   swift scripts/make-icons.swift
//
// The waveform is drawn here rather than taken from SF Symbols: Apple's license keeps SF
// Symbols out of app icons.

import AppKit

struct Style {
    let name: String
    let top: NSColor
    let bottom: NSColor
    let devBand: Bool
}

let styles = [
    Style(name: "AppIcon",
          top: NSColor(srgbRed: 0.42, green: 0.44, blue: 1.00, alpha: 1),
          bottom: NSColor(srgbRed: 0.25, green: 0.19, blue: 0.78, alpha: 1),
          devBand: false),
    Style(name: "AppIconDev",
          top: NSColor(srgbRed: 1.00, green: 0.67, blue: 0.24, alpha: 1),
          bottom: NSColor(srgbRed: 0.94, green: 0.39, blue: 0.07, alpha: 1),
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

/// 1024 x 1024 on the macOS icon grid: an 824 x 824 rounded square with a soft shadow, seven
/// waveform bars, and for Dev a dark band with DEV across the bottom.
@MainActor func icon(_ style: Style) -> CGImage {
    canvas(1024) { _ in
        let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 28
        shadow.set()
        style.bottom.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: style.top, ending: style.bottom)!.draw(in: body, angle: -90)

        NSColor.white.setFill()
        let heights: [CGFloat] = [0.30, 0.56, 0.86, 1.0, 0.74, 0.50, 0.30]
        let barWidth: CGFloat = 54, gap: CGFloat = 34, tallest: CGFloat = 420, centerY: CGFloat = 530
        var x = 512 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap) / 2
        for height in heights.map({ $0 * tallest }) {
            let bar = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }

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
    }
}

// A script's top level runs on the main thread but is not main-actor isolated in Swift 6.
try MainActor.assumeIsolated { try writeCatalog() }
