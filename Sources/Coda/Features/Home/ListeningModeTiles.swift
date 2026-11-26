import SwiftUI
#if os(macOS)
import AppKit
import ImageIO
#else
import UIKit
#endif

/// A square listening-mode tile, shared by the Qishui and QQ Music home pages.
struct ListeningModeTile: View {
    let title: String
    let icon: Image
    let isSelected: Bool
    var isPending = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel)
        let iconTint = isSelected ? Color.white : Theme.accent

        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: Theme.Spacing.small) {
                        Group {
                            if isPending {
                                ProgressView().controlSize(.small).tint(iconTint)
                            } else {
                                icon
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(iconTint)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)

                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.white : .primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(Theme.Spacing.small)
                }
                .background { background(shape) }
                .contentShape(shape)
        }
        #if os(macOS)
        .buttonStyle(InteractiveCardStyle(hoverScale: reduceMotion ? 1 : 1.025,
                                         pressScale: reduceMotion ? 1 : 0.98))
        #else
        .buttonStyle(PressableButtonStyle(pressScale: 1))
        .hoverEffect(reduceMotion ? .highlight : .lift)
        #endif
        .accessibilityLabel(title)
        .accessibilityHint("播放此场景的推荐歌曲")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Tiles sit on the theme page background, so the theme card color
    /// separates them. On macOS the tiles keep a light shadow, drawn on the
    /// shape only so the icon and text don't render offscreen.
    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        #if os(iOS)
        shape.fill(isSelected ? Theme.accentDeep : Theme.cardBackground(colorScheme))
        #else
        shape.fill(isSelected ? Theme.accentDeep : Theme.cardBackground(colorScheme))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        #endif
    }
}

/// Adaptive grid sizing shared by both providers' mode tiles.
struct ListeningModeGrid<Content: View>: View {
    @ScaledMetric(relativeTo: .subheadline) private var minimumTileSize: CGFloat = 88
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileSize), spacing: Theme.Spacing.control)],
                  spacing: Theme.Spacing.control, content: content)
    }
}

/// Mode icons bundled from Qishui; QQ modes reuse them by matching the mode name.
enum ListeningModeIcons {
    private static var resourceURLs: [URL] {
        // The macOS packaging script embeds SwiftPM bundles in Contents/Resources.
        let bundle = Bundle.main.url(forResource: "Coda_CodaCore", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? .module
        return bundle.urls(forResourcesWithExtension: "png", subdirectory: "QishuiModeIcons") ?? []
    }

    #if os(macOS)
    static let thumbnails = Task.detached(priority: .userInitiated) {
        var images: [String: CGImage] = [:]
        for url in resourceURLs {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64,
                      kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            images[url.deletingPathExtension().lastPathComponent] = bitmap
        }
        return images
    }

    static func image(for mode: String, in bitmaps: [String: CGImage]) -> Image {
        if let bitmap = bitmaps[mode] ?? bitmaps["scene_mode_\(mode)"] ?? bitmaps["default"] {
            return Image(decorative: bitmap, scale: 2)
        }
        return Image(systemName: "music.note")
    }
    #else
    static func image(for mode: String) -> Image {
        images[mode] ?? images["scene_mode_\(mode)"] ?? images["default"] ?? Image(systemName: "music.note")
    }

    private static let images: [String: Image] = {
        var images: [String: Image] = [:]
        for url in resourceURLs {
            guard let file = UIImage(contentsOfFile: url.path) else { continue }
            let image = Image(uiImage: file.preparingForDisplay() ?? file)
            images[url.deletingPathExtension().lastPathComponent] = image
        }
        return images
    }()
    #endif
}
