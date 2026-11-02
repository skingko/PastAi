import AppKit
import SwiftUI

/// Renders `symbol:`, `text:` and `file:` icons the same way in the bar and in settings.
public struct ExtensionIconView: View {
    var icon: String
    var fileURL: URL?
    var size: CGFloat

    public init(icon: String, fileURL: URL?, size: CGFloat) {
        self.icon = icon
        self.fileURL = fileURL
        self.size = size
    }

    public var body: some View {
        Group {
            if icon.hasPrefix("symbol:") {
                Image(systemName: String(icon.dropFirst(7)))
                    .font(.system(size: size * 0.88, weight: .medium))
            } else if icon.hasPrefix("text:") {
                Text(String(icon.dropFirst(5)))
                    .font(.system(size: size * 0.82, weight: .semibold))
                    .minimumScaleFactor(0.6)
            } else if let image = loadImage() {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.88))
            }
        }
        .frame(width: size, height: size)
    }

    private func loadImage() -> NSImage? {
        guard let fileURL, let image = NSImage(contentsOf: fileURL) else { return nil }
        // Brand marks are single-colour shapes, so they follow the text colour in light and dark.
        image.isTemplate = true
        return image
    }
}
