// The idle menu bar glyph: the ace reduced to a solid card with three voice bars cut out
// (docs/designs/maagical-brand.md, "Menu bar"). Drawn by hand as a template image, so it takes
// the menu bar's light or dark ink like an SF Symbol does; the busy and error states keep their
// SF Symbols (IconState.symbolName), which read better than the card at 18 pt.

import AppKit

enum MenuBarGlyph {
    /// The name AppContainer.iconSymbol returns for the idle state; not an SF Symbol.
    static let cardName = "maagical.card"

    /// The status item image for an icon name: the card, or the SF Symbol of that name.
    static func image(named name: String) -> NSImage? {
        name == cardName ? card : NSImage(systemSymbolName: name, accessibilityDescription: "Maagical")
    }

    /// An 18 pt card, 11 x 15, with three bars (3.5, 7, 3.5 tall) punched out of its middle.
    /// Even-odd filled, so the bars show the menu bar through the card on any background.
    static let card: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let card = CGRect(x: 3.5, y: 1.5, width: 11, height: 15)
            context.addPath(CGPath(roundedRect: card, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            let heights: [CGFloat] = [3.5, 7, 3.5]
            let width: CGFloat = 1.5, gap: CGFloat = 1
            var x = card.midX - (CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap) / 2
            for height in heights {
                let bar = CGRect(x: x, y: card.midY - height / 2, width: width, height: height)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
                x += width + gap
            }
            context.setFillColor(.black)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Maagical"
        return image
    }()
}
