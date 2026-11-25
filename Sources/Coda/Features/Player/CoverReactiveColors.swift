// CoverReactiveColors.swift
// 播放页封面变色：取当前歌曲封面的主色调，用到播放页的背景和强调色上。
// 只影响播放页，App 其他地方还是 WQ 主题的颜色。
// 封面颜色用 App 现成的 ArtworkPalette 提取（读封面图像素取主色），不引新库；
// 没有封面时用 WQ 主题的颜色兜底。
// 律动：播放时跟着真实音频电平走（AudioSpectrum 的低频）；拿不到电平时用
// 平滑的呼吸动画代替；暂停或减弱动态时回到平静。幅度都克制，不晃眼。

import SwiftUI

/// 脉动值 0...1：跟着音频低频走，拿不到电平时缓慢呼吸，暂停时归零。
@MainActor
final class CoverPulseModel: ObservableObject {
    @Published private(set) var pulse: Double = 0

    private var timer: Timer?
    private var startTime = Date()
    private var smoothed: Double = 0

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    deinit { timer?.invalidate() }

    private func tick() {
        guard !Platform.isReduceMotionEnabled else {
            smoothed = 0
            pulse = 0
            return
        }
        let playing = PlayerService.shared.isPlaying
        let target: Double
        if !playing {
            target = 0
        } else {
            let spectrum = AudioSpectrum.shared
            if spectrum.tapState == .tapped && spectrum.isLive {
                // 真实电平：低频段，0...1。
                target = Double(spectrum.level(at: 0))
            } else {
                // 拿不到电平：4 秒一个周期的缓慢呼吸。
                let t = Date().timeIntervalSince(startTime)
                target = 0.5 + 0.5 * sin(2 * .pi * t / 4.0)
            }
        }
        // 快攻慢放，平滑跟随。
        let rate = target > smoothed ? 0.35 : 0.08
        smoothed += (target - smoothed) * rate
        pulse = smoothed
    }
}

/// 播放页强调色：开着封面变色且有封面时用封面主色（往白里提一点，保证在
/// 深色播放页上够亮；脉动强时再亮一点点），否则用 WQ 主题强调色。
enum CoverReactiveAccent {
    static func color(colors: ArtworkColors, enabled: Bool, pulse: Double) -> Color {
        guard enabled, colors != .fallback else {
            return CodaThemeManager.shared.accent
        }
        let brighten = 0.20 + min(max(pulse, 0), 1) * 0.15
        return colors.primary.codaBlended(toward: .white, amount: brighten)
    }
}
