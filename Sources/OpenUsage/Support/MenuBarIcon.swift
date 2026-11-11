import AppKit
import SwiftUI

/// Renders the HopUsage gauge glyph into a template `NSImage` for the menu bar.
///
/// Fork note: the original OpenUsage brand mark (`ProviderIcons/openusage.svg`) is a trademark of its
/// author, so this fork draws the SF Symbol in `symbolName` everywhere the brand mark used to appear:
/// the menu bar, the screen-share privacy label, and the share card watermark.
@MainActor
enum MenuBarIcon {
    /// The SF Symbol that stands in for the brand mark across the app.
    nonisolated static let symbolName = "gauge.with.dots.needle.bottom.100percent"

    /// Side length (points) of the menu bar glyph.
    private static let side: CGFloat = 18

    /// Cached template image, or `nil` if the symbol is unavailable.
    static let image: NSImage? = render()

    private static func render() -> NSImage? {
        let renderer = ImageRenderer(
            content: Image(systemName: symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.black)
                .frame(width: side, height: side)
        )
        renderer.scale = 2
        guard let nsImage = renderer.nsImage else { return nil }
        nsImage.size = NSSize(width: side, height: side)
        nsImage.isTemplate = true
        return nsImage
    }
}
