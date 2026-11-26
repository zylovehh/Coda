// CodaThemeSettingsView.swift
// 主题设置页：从设置页的“主题”入口进来。照壁纸匣 V2.9.3 的 WQ 主题设置页搬过来，
// 四项主题（默认 / 自定颜色 / Midnight / Sunset）+ 三个开关（纯色背景 / 彩色卡片 / 卡片颜色）。
// 不做导入导出主题。换主题立刻生效，不用重启 App。

import SwiftUI

struct CodaThemeSettingsView: View {
    @ObservedObject private var theme = CodaThemeManager.shared
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { theme.colors(for: scheme).accent }

    var body: some View {
        Form {
            Section {
                themeRow(id: .default, title: "默认", subtitle: "App 默认样子，深灰渐变底色",
                         bar: LinearGradient(colors: [Color(codaHex: "#EC4949"), Color(codaHex: "#3A3F4A")],
                                             startPoint: .leading, endPoint: .trailing))
                customRow
                themeRow(id: .midnight, title: "Midnight", subtitle: "内置 · 深蓝",
                         bar: LinearGradient(colors: [Color(codaHex: "#2F6BFF"), Color(codaHex: "#00C2FF"), Color(codaHex: "#7A5CFF")],
                                             startPoint: .leading, endPoint: .trailing))
                themeRow(id: .sunset, title: "Sunset", subtitle: "内置 · 暖橙",
                         bar: LinearGradient(colors: [Color(codaHex: "#FF6A3D"), Color(codaHex: "#FF2E7A"), Color(codaHex: "#FFC24A")],
                                             startPoint: .leading, endPoint: .trailing))
            } header: {
                Text("主题")
            } footer: {
                Text("轻点主题即可使用，深色和浅色自动跟随系统。")
            }

            Section {
                Toggle(isOn: $theme.plainBackground) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("纯色背景")
                        Text("打开后背景用纯色，不用渐变和光晕")
                            .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $theme.colorfulCards) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("彩色卡片")
                        Text("没有封面的歌单卡片带上主题色")
                            .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("卡片颜色")
                        Text("每张卡片使用其图标的颜色")
                            .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if theme.fixedCardColor != nil {
                        Button("恢复轮换") { theme.fixedCardColor = nil }
                            .font(Theme.Typography.caption).foregroundStyle(accent)
                    }
                    ColorPicker("", selection: Binding(
                        get: { theme.fixedCardColor ?? theme.colors(for: scheme).accent },
                        set: { theme.fixedCardColor = $0 }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            } header: {
                Text("选项")
            } footer: {
                Text("挑一个固定颜色后，全部卡片都用这个颜色；不挑就按主题色轮着来。")
            }

            Section {
                Text("主题只改 App 的样子，不改播放和登录。\n换主题立刻生效，不用重启 App。")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .pageFormStyle()
        .navigationTitle("主题")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// 一行主题：名字、说明、右边色条、选中打勾。
    private func themeRow(id: CodaThemeManager.ID, title: String, subtitle: String, bar: LinearGradient) -> some View {
        Button {
            theme.themeID = id
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(Theme.Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 8)
                    .fill(bar)
                    .frame(width: 56, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25), lineWidth: 1))
                if theme.themeID == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 自定颜色那行：右边是个取色器，点了就切到自定颜色。
    private var customRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("自定颜色")
                Text("自己挑一个颜色当主题色").font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ColorPicker("", selection: Binding(
                get: { theme.customColor },
                set: {
                    theme.customColor = $0
                    theme.themeID = .custom
                }
            ), supportsOpacity: false)
            .labelsHidden()
            if theme.themeID == .custom {
                Image(systemName: "checkmark")
                    .foregroundStyle(accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { theme.themeID = .custom }
    }
}
