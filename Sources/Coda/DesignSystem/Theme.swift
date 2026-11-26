import SwiftUI

/// Design tokens: color, radius, spacing, layout metrics.
enum Theme {
    /// App 强调色，跟着当前主题走（默认是网易云红 #EC4949；见 CodaThemeManager）。
    static var accent: Color { CodaThemeManager.shared.accent }
    static var accentDeep: Color { CodaThemeManager.shared.accentDeep }

    /// 卡片底色，跟着当前主题走（Midnight 自带的卡片色，其他主题用强调色加透明度凑）。
    static func cardBackground(_ scheme: ColorScheme) -> Color {
        CodaThemeManager.shared.cardBackground(for: scheme)
    }

    /// Shared translucent surface for the iPad navigation and playback bars.
    static let barMaterial: Material = .regular

    enum LikedMusic {
        static func background(_ scheme: ColorScheme) -> Color {
            #if os(iOS)
            return Color(uiColor: .systemBackground)
            #else
            return groupedBackground(scheme)
            #endif
        }
        static func groupedBackground(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.063) : Color(red: 0.95, green: 0.95, blue: 0.965)
        }
        static func surface(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(red: 0.106, green: 0.106, blue: 0.118) : .white
        }
        static func selection(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(red: 0.18, green: 0.12, blue: 0.12) : Color(red: 0.99, green: 0.94, blue: 0.94)
        }
        static func accent(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(red: 1, green: 0.43, blue: 0.38) : Color(red: 0.81, green: 0.19, blue: 0.16)
        }
        static let cover = Color(red: 0.43, green: 0.43, blue: 0.45)
    }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent.codaBlended(toward: .white, amount: 0.08), accentDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    enum Radius {
        static let badge: CGFloat = 4
        static let small: CGFloat = 6
        static let standard: CGFloat = 8
        static let large: CGFloat = 12
        /// Playlist and album covers, matching the home radar cards.
        static let cover: CGFloat = 22
        static let panel: CGFloat = 20
    }

    /// Shared spacing rhythm. Safe-area clearance and optical corrections live
    /// with their owning component rather than being rounded to this scale.
    enum Spacing {
        static let micro: CGFloat = 2
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let control: CGFloat = 12
        static let component: CGFloat = 16
        /// Space within a composed component, independent of page section rhythm.
        static let group: CGFloat = 24
        static let phonePage: CGFloat = 20
        static let page: CGFloat = 24
        static let section: CGFloat = 20
        static let largeSection: CGFloat = 24
        static let discoverySection: CGFloat = 32
    }

    /// iOS follows Dynamic Type; desktop keeps a denser reading rhythm.
    /// Symbol sizes and lyric typography are intentionally separate roles.
    enum Typography {
        #if os(iOS)
        static let pageTitle: Font = .largeTitle.bold()
        static let sectionTitle: Font = .title2.weight(.semibold)
        static let detailTitle: Font = .title2.bold()
        static let cardTitle: Font = .headline
        static let body: Font = .body
        static let trackTitle: Font = .body.weight(.medium)
        static let secondary: Font = .subheadline
        static let caption: Font = .footnote
        static let badge: Font = .caption2.weight(.medium)
        #else
        static let pageTitle: Font = .system(size: 28, weight: .bold)
        static let sectionTitle: Font = .system(size: 22, weight: .semibold)
        static let detailTitle: Font = .system(size: 22, weight: .bold)
        static let cardTitle: Font = .system(size: 15, weight: .semibold)
        static let body: Font = .system(size: 13)
        static let trackTitle: Font = .system(size: 13, weight: .medium)
        static let secondary: Font = .system(size: 12)
        static let caption: Font = .system(size: 11)
        static let badge: Font = .system(size: 10, weight: .medium)
        #endif
    }

    enum Layout {
        static var contentInset: CGFloat {
            #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .phone ? Spacing.phonePage : Spacing.page
            #else
            Spacing.page
            #endif
        }
        static let dividedColumnSpacing: CGFloat = 32
        static let emptyStateInset: CGFloat = 40
        static let controlHeight: CGFloat = 44
        static let detailActionHeight: CGFloat = 56
        static let trackRowHeight: CGFloat = 64
        static let trackArtworkSize: CGFloat = 48
        static let trackRowHorizontalInset = Spacing.control
        /// Align row content, including its internal inset, to the page edge.
        static var trackListInset: CGFloat { contentInset - trackRowHorizontalInset }
        /// Home song shelves use one column width on Mac, iPad and iPhone:
        /// the width of a 393pt-wide iPhone's column (393 − 2×8 − 20pt peek).
        static let homeSongColumnWidth: CGFloat = 357
        /// Cover cards everywhere match the home radar cards.
        static let cardSize: CGFloat = 178
        static func fittedShelfCardSize(availableWidth: CGFloat, leadingInset: CGFloat, spacing: CGFloat = 16) -> CGFloat {
            let usableWidth = availableWidth - leadingInset - spacing
            // A zero-width proposal while the split view is resizing still needs one 1pt card.
            let visibleCount = max(1, Int(ceil((usableWidth + spacing) / (cardSize + spacing))))
            return max(1, (usableWidth - CGFloat(visibleCount - 1) * spacing) / CGFloat(visibleCount))
        }
        /// Row height for a shelf of cover cards: artwork, then up to two lines
        /// of title and one of subtitle.
        static let coverShelfHeight: CGFloat = cardSize + 96
        static let sidebarWidth: CGFloat = 332
        static let playerBarHeight: CGFloat = 64
        static let playerBarHorizontalMargin: CGFloat = 16
        static let playerBarProgressMinimumWidth: CGFloat = 720
        /// Gap between the floating player bar and the window's bottom edge.
        /// Must match the bar's own `.padding(.bottom,)` in PlayerBar.
        static let playerBarBottomMargin: CGFloat = 10
        /// Bottom inset pages need so scrolled content clears the floating bar.
        static var playerChromeClearance: CGFloat { playerBarHeight + playerBarBottomMargin }
        /// Extra breathing margin for scrollable content clearing chrome.
        static let scrollBreathingMargin: CGFloat = 8

        #if os(iOS)
        /// Shared dimensions for the floating iPad playback surface.
        static let iPadPlayerBarHeight = playerBarHeight
        static let iPadPlayerBarHorizontalMargin = playerBarHorizontalMargin
        static let iPadPlayerBarBottomMargin = playerBarBottomMargin
        static let iPadChromeCornerRadius: CGFloat = 26
        static var iPadPlayerChromeClearance: CGFloat {
            iPadPlayerBarHeight + iPadPlayerBarBottomMargin
        }

        #endif

        enum FloatingChrome {
            /// Total height of GlassTabBar: 56pt content + 2 * 4pt inset.
            static let tabBarHeight: CGFloat = 64
            /// Total height of legacy mini player bar: 44pt button + 2 * 4pt vertical padding.
            static let miniPlayerHeight: CGFloat = 52
            static let horizontalMargin: CGFloat = 12
            /// Spacing between mini player and tab bar in customTabInterface.
            static let barSpacing: CGFloat = 8
            /// Bottom padding under the tab bar.
            static let bottomMargin: CGFloat = 6
            /// Breathing margin ensuring content clears above the floating bars.
            static let extraPadding: CGFloat = 12

            /// Clearance needed when only the tab bar is visible.
            static var tabBarClearance: CGFloat {
                tabBarHeight + bottomMargin + extraPadding
            }

            /// Clearance needed when both mini player and tab bar are visible.
            static var fullChromeClearance: CGFloat {
                miniPlayerHeight + barSpacing + tabBarHeight + bottomMargin + extraPadding
            }
        }
        static let minWindowHeight: CGFloat = 640
        static let defaultWindowWidth: CGFloat = 1200
        static let defaultWindowHeight: CGFloat = 780
    }
}

/// Motion tokens (mirrors kaset's `AppAnimation`).
enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.25)
    static let smooth = Animation.easeInOut(duration: 0.35)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    static let staggerDelay = 0.04
    static let maxStaggerDelay = 0.4

    static func stagger(for index: Int) -> Double {
        min(Double(index) * staggerDelay, maxStaggerDelay)
    }
}

extension View {
    /// `scrollClipDisabled` is iOS 17 / macOS 14; older systems clip normally.
    @ViewBuilder
    func compatScrollClipDisabled() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) { scrollClipDisabled() } else { self }
    }

    /// Hides the toolbar background; `toolbarBackgroundVisibility` is
    /// macOS 15+/iOS 18+, so iOS 17 falls back to `toolbarBackground`.
    @ViewBuilder
    func compatHiddenToolbarBackground() -> some View {
        #if os(macOS)
        toolbarBackgroundVisibility(.hidden, for: .automatic)
        #else
        if #available(iOS 18.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .automatic)
        } else {
            toolbarBackground(.hidden, for: .navigationBar)
        }
        #endif
    }

    /// Native glass on new systems, with the same fallback recipe across devices.
    func compatGlass(interactive: Bool = false, in shape: some Shape) -> some View {
        modifier(CompatibleGlassSurface(shape: shape, interactive: interactive))
    }
}

private struct CompatibleGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Platform.windowBackgroundColor, in: shape)
        } else {
            nativeOrLegacy(content)
        }
    }

    @ViewBuilder
    private func nativeOrLegacy(_ content: Content) -> some View {
        #if compiler(<6.2)
        content.background { LegacyGlassBackground(shape: shape) }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background { LegacyGlassBackground(shape: shape) }
        }
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background { LegacyGlassBackground(shape: shape) }
        }
        #else
        content.background { LegacyGlassBackground(shape: shape) }
        #endif
    }
}
