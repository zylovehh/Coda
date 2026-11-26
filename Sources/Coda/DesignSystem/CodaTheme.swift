// CodaTheme.swift
// 主题系统：照壁纸匣 V2.9.3 里搬来的 WQ Files 主题（默认 / 自定颜色 / Midnight / Sunset）。
// 颜色值照 WQ Files 安装包里的 midnight.wqtheme / sunset.wqtheme（JSON，
// 颜色串最后两位是透明度）。只有这四项，不做导入导出主题。
// 主题只改 App 的样子（背景、强调色、卡片），不改播放和登录。
// 播放页另有封面变色（见 CoverReactiveColors.swift），只影响播放页。

import SwiftUI

// MARK: - 颜色值

/// 一套深色或浅色的颜色。
struct CodaThemeVariant {
    let backgroundTop: Color
    let backgroundBottom: Color
    /// 四团光晕（左上、右上、左下、右中）。
    let glows: [Color]
    let accent: Color
    /// 卡片底色（Midnight dark 有；Sunset dark 没有，用 accent 加透明度凑）。
    let card: Color?
    /// 纯色背景用的单色（只有 dark 有；light 用 backgroundTop）。
    let plain: Color?
}

/// 一个主题的完整定义。
struct CodaThemeDefinition {
    let id: String
    let name: String
    let dark: CodaThemeVariant
    let light: CodaThemeVariant
    /// 卡片轮换用的渐变（Midnight 8 个，Sunset 6 个，按文件里的顺序）。
    let tiles: [(Color, Color)]
}

extension Color {
    /// "#RRGGBB" 或 "#RRGGBBAA"（最后两位是透明度）。
    init(codaHex hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        if h.count == 8 {
            let r = Double((value >> 24) & 0xFF) / 255
            let g = Double((value >> 16) & 0xFF) / 255
            let b = Double((value >> 8) & 0xFF) / 255
            let a = Double(value & 0xFF) / 255
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        } else {
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
        }
    }

    /// 取出 sRGB 四个分量（取不到就返回 nil）。
    private var codaRGBA: (r: Double, g: Double, b: Double, a: Double)? {
        guard let cg = self.cgColor,
              let comps = cg.components, comps.count >= 3 else { return nil }
        return (Double(comps[0]), Double(comps[1]), Double(comps[2]),
                comps.count >= 4 ? Double(comps[3]) : 1)
    }

    /// 转回 "#RRGGBB"（取色器写回 UserDefaults 用）。
    var codaHexString: String {
        guard let c = codaRGBA else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
    }

    /// 变亮一点（自定颜色的卡片渐变用）。
    func codaLightened(by amount: Double) -> Color {
        guard let c = codaRGBA else { return self }
        return Color(.sRGB, red: min(1, c.r + amount), green: min(1, c.g + amount),
                     blue: min(1, c.b + amount), opacity: c.a)
    }

    /// 变暗一点（强调色的深色版用）。
    func codaDarkened(by amount: Double) -> Color {
        guard let c = codaRGBA else { return self }
        return Color(.sRGB, red: max(0, c.r - amount), green: max(0, c.g - amount),
                     blue: max(0, c.b - amount), opacity: c.a)
    }

    /// 往另一个颜色混过去（amount 0 = 自己，1 = 目标色）。
    func codaBlended(toward other: Color, amount: Double) -> Color {
        guard let c = codaRGBA, let o = other.codaRGBA else { return self }
        let t = min(max(amount, 0), 1)
        return Color(.sRGB, red: c.r + (o.r - c.r) * t, green: c.g + (o.g - c.g) * t,
                     blue: c.b + (o.b - c.b) * t, opacity: c.a + (o.a - c.a) * t)
    }
}

/// 内置主题的数据（照 .wqtheme 文件）。
enum CodaBuiltinThemes {
    static let midnight = CodaThemeDefinition(
        id: "midnight", name: "Midnight",
        dark: CodaThemeVariant(
            // 注意：WQ 原版底色是 #05070F→#0B1226，但那两个值在手机屏上和纯黑没区别，
            // 用户眼里就是“主题没生效”。这里特意提亮成深海军蓝，渐变+光晕的路子不变。
            backgroundTop: Color(codaHex: "#1E2A4A"), backgroundBottom: Color(codaHex: "#121C38"),
            glows: [Color(codaHex: "#2F6BFF9E"), Color(codaHex: "#00C2FF66"), Color(codaHex: "#7A5CFF55"), Color(codaHex: "#00E0B03A")],
            accent: Color(codaHex: "#5AA9FF"), card: Color(codaHex: "#1A2A5C33"), plain: Color(codaHex: "#121C38")),
        light: CodaThemeVariant(
            backgroundTop: Color(codaHex: "#EEF3FF"), backgroundBottom: Color(codaHex: "#DCE6FF"),
            glows: [Color(codaHex: "#7FA8FF80"), Color(codaHex: "#7FE0FF60"), Color(codaHex: "#B9A8FF55"), Color(codaHex: "#7FF0D040")],
            accent: Color(codaHex: "#2F6BFF"), card: nil, plain: nil),
        tiles: [
            (Color(codaHex: "#6FB6FF"), Color(codaHex: "#2F6BFF")),
            (Color(codaHex: "#7FE0FF"), Color(codaHex: "#1FA5E0")),
            (Color(codaHex: "#A08CFF"), Color(codaHex: "#5B3FE0")),
            (Color(codaHex: "#8C9CFF"), Color(codaHex: "#3A4BD0")),
            (Color(codaHex: "#5FF0D0"), Color(codaHex: "#0FA88C")),
            (Color(codaHex: "#7FC4FF"), Color(codaHex: "#3570E8")),
            (Color(codaHex: "#9FDCFF"), Color(codaHex: "#3A8FD9")),
            (Color(codaHex: "#B9A8FF"), Color(codaHex: "#6E4DE8")),
        ])

    static let sunset = CodaThemeDefinition(
        id: "sunset", name: "Sunset",
        dark: CodaThemeVariant(
            backgroundTop: Color(codaHex: "#140806"), backgroundBottom: Color(codaHex: "#2A0F12"),
            glows: [Color(codaHex: "#FF6A3DA0"), Color(codaHex: "#FF2E7A70"), Color(codaHex: "#FFC24A55"), Color(codaHex: "#B34DFF3A")],
            accent: Color(codaHex: "#FF8A4C"), card: nil, plain: Color(codaHex: "#140806")),
        light: CodaThemeVariant(
            backgroundTop: Color(codaHex: "#FFF4EC"), backgroundBottom: Color(codaHex: "#FFE3D6"),
            glows: [Color(codaHex: "#FFAA7A80"), Color(codaHex: "#FF8AB560"), Color(codaHex: "#FFD27A55"), Color(codaHex: "#D9A6FF40")],
            accent: Color(codaHex: "#E8562A"), card: nil, plain: nil),
        tiles: [
            (Color(codaHex: "#FF9A6B"), Color(codaHex: "#E8562A")),
            (Color(codaHex: "#FFB38A"), Color(codaHex: "#F06A3A")),
            (Color(codaHex: "#FF8AB5"), Color(codaHex: "#D9367A")),
            (Color(codaHex: "#FF7A8A"), Color(codaHex: "#C93A55")),
            (Color(codaHex: "#FFC86B"), Color(codaHex: "#E0901F")),
            (Color(codaHex: "#D9B3A6"), Color(codaHex: "#9C6B5C")),
        ])
}

// MARK: - 主题管理

/// 主题选择存在 UserDefaults 里；单例，各页直接用。Coda 自己的红是默认主题，
/// 换主题后整个 App 的强调色、背景、卡片都跟着变；播放页另有封面变色盖在上面。
/// 公开是因为 iOS 应用入口（CodaIOSApp.swift，在 CodaCore 模块外面）也要拿它：
/// 换主题时整棵视图树跟着刷新。其他成员保持 internal，只把外面用到的公开。
public final class CodaThemeManager: ObservableObject {
    public static let shared = CodaThemeManager()

    enum ID: String, CaseIterable {
        case `default` = "default"
        case custom = "custom"
        case midnight = "midnight"
        case sunset = "sunset"

        var displayName: String {
            switch self {
            case .default: return "默认"
            case .custom: return "自定颜色"
            case .midnight: return "Midnight"
            case .sunset: return "Sunset"
            }
        }
    }

    // @AppStorage 只写 UserDefaults，不会自己发 objectWillChange，观察它的页面
    // （主题背景、强调色）就收不到刷新通知——换主题后背景一直停在旧样子。
    // 每个值加 willSet 手动发，换主题立刻全 App 刷新。
    @AppStorage("coda.theme.id") var themeIDRaw: String = ID.default.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("coda.theme.customColor") var customColorHex: String = "#EC4949" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("coda.theme.plainBackground") var plainBackground: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("coda.theme.colorfulCards") var colorfulCards: Bool = false {
        willSet { objectWillChange.send() }
    }
    /// 固定卡片颜色的 hex；空串 = 不固定，按主题色轮着来。
    @AppStorage("coda.theme.cardColor") var cardColorHex: String = "" {
        willSet { objectWillChange.send() }
    }

    var themeID: ID {
        get { ID(rawValue: themeIDRaw) ?? .default }
        set { themeIDRaw = newValue.rawValue }
    }

    var customColor: Color {
        get { Color(codaHex: customColorHex) }
        set { customColorHex = newValue.codaHexString }
    }

    var fixedCardColor: Color? {
        get { cardColorHex.isEmpty ? nil : Color(codaHex: cardColorHex) }
        set { cardColorHex = newValue?.codaHexString ?? "" }
    }

    /// 当前主题的定义（自定颜色是现算的：底用深蓝黑，光晕是自定颜色加透明度）。
    var currentDefinition: CodaThemeDefinition {
        switch themeID {
        case .default:
            // 默认就是 Coda 现在的样子：网易云红强调色，系统背景。
            return CodaThemeDefinition(
                id: "default", name: "默认",
                dark: CodaThemeVariant(backgroundTop: Color(codaHex: "#171A21"), backgroundBottom: Color(codaHex: "#101218"),
                                      glows: [Color(codaHex: "#78829659"), Color(codaHex: "#5A647866"), Color(codaHex: "#46506440"), Color(codaHex: "#646E8233")],
                                      accent: Color(codaHex: "#EC4949"), card: nil, plain: Color(codaHex: "#000000")),
                light: CodaThemeVariant(backgroundTop: .white, backgroundBottom: Color(codaHex: "#F2F2F7"),
                                        glows: [], accent: Color(codaHex: "#EC4949"), card: nil, plain: .white),
                tiles: [])
        case .custom:
            let c = customColor
            return CodaThemeDefinition(
                id: "custom", name: "自定颜色",
                dark: CodaThemeVariant(backgroundTop: Color(codaHex: "#0B0F1C"), backgroundBottom: Color(codaHex: "#070A12"),
                                       glows: [c.opacity(0.62), c.opacity(0.40), c.opacity(0.33), c.opacity(0.23)],
                                       accent: c, card: nil, plain: Color(codaHex: "#070A12")),
                light: CodaThemeVariant(backgroundTop: Color(codaHex: "#F2F4F8"), backgroundBottom: Color(codaHex: "#E8ECF2"),
                                        glows: [c.opacity(0.50), c.opacity(0.38), c.opacity(0.33), c.opacity(0.25)],
                                        accent: c, card: nil, plain: .white),
                tiles: (0..<8).map { i in
                    (c.codaLightened(by: 0.30 - Double(i) * 0.03), c)
                })
        case .midnight:
            return CodaBuiltinThemes.midnight
        case .sunset:
            return CodaBuiltinThemes.sunset
        }
    }

    /// 当前深浅下的一套颜色。
    func colors(for scheme: ColorScheme) -> CodaThemeVariant {
        scheme == .dark ? currentDefinition.dark : currentDefinition.light
    }

    /// 当前系统深浅下的强调色（静态 Theme.accent 走这里）。
    /// 公开：iOS 应用入口拿它当整棵视图树的 tint。
    public var accent: Color {
        colors(for: effectiveScheme).accent
    }

    /// 强调色的深色版（渐变、按压态用）。
    var accentDeep: Color {
        accent.codaDarkened(by: 0.12)
    }

    /// 当前系统是深色还是浅色（视图求值时现取，跟着系统走）。
    var effectiveScheme: ColorScheme {
        #if os(iOS)
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #else
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        #endif
    }

    /// 卡片描边的渐变：固定了卡片颜色就用纯色，没固定就按主题 tiles 轮着来。
    /// id 用歌单/专辑的标题，同一个每次算出来是同一个色（不会切页就变）。
    func cardGradient(forItemID id: String) -> LinearGradient {
        if let fixed = fixedCardColor {
            return LinearGradient(colors: [fixed, fixed], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let tiles = currentDefinition.tiles
        guard !tiles.isEmpty else {
            let accent = currentDefinition.dark.accent
            return LinearGradient(colors: [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        var hash = 0
        for scalar in id.unicodeScalars {
            hash = (hash &* 31) &+ Int(scalar.value)
        }
        // 用掩码去符号位，不用 abs（hash 恰好是 Int.min 时 abs 会 trap）。
        let pair = tiles[(hash & 0x7FFFFFFF) % tiles.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 卡片底色：主题自带 card 就用它（Sunset dark 没有，就用 accent 加透明度凑）。
    func cardBackground(for scheme: ColorScheme) -> Color {
        let variant = colors(for: scheme)
        if let card = variant.card { return card }
        return variant.accent.opacity(0.14)
    }
}

// MARK: - 主题背景

/// 主题渐变 + 四团光晕（照 WQ 主题页预览的位置摆）。
/// 四个主题都走同一条路。默认主题以前直接返回系统背景（深色下纯黑），它自己的
/// #171A21→#101218 渐变色值写了却从来没画出来，用户眼里就是“主题没生效”。
/// 现在默认主题也画自己的渐变底，不再全黑。
struct CodaThemeBackgroundView: View {
    @ObservedObject private var theme = CodaThemeManager.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let variant = theme.colors(for: scheme)
        GeometryReader { geo in
            ZStack {
                if theme.plainBackground {
                    (variant.plain ?? variant.backgroundTop)
                } else {
                    LinearGradient(
                        colors: [variant.backgroundTop, variant.backgroundBottom],
                        startPoint: .top, endPoint: .bottom)
                    // 四团光晕：左上、右上、左下、右中。默认主题浅色没有光晕，不画。
                    if variant.glows.count >= 4 {
                        Circle().fill(variant.glows[0]).frame(width: 300, height: 300).blur(radius: 70)
                            .position(x: -10, y: 10)
                        Circle().fill(variant.glows[1]).frame(width: 300, height: 300).blur(radius: 70)
                            .position(x: geo.size.width + 20, y: 40)
                        Circle().fill(variant.glows[2]).frame(width: 300, height: 300).blur(radius: 70)
                            .position(x: 0, y: geo.size.height + 20)
                        Circle().fill(variant.glows[3]).frame(width: 300, height: 300).blur(radius: 70)
                            .position(x: geo.size.width + 30, y: geo.size.height * 0.42)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}
