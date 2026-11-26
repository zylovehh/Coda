// SPDX-License-Identifier: GPL-3.0-only
// Adapted from MeloX ArtworkAccentColorProvider.swift and PlaylistDetailContent.swift
// at 9c2f87b57b54ddbab76a4a53736f4840719a0947 (GPL-3.0-only).
// Copyright MeloX contributors. See ThirdPartyNotices/MeloX.md.
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// Keep async results reference-backed and scalar-aligned. SIMD3<Double> in
// the SwiftUI task result triggers a task-allocation abort on device runtimes.
final class DetailArtworkAssets: @unchecked Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let isDark: Bool
    let blurredImage: CGImage?

    init(red: Double, green: Double, blue: Double, isDark: Bool, blurredImage: CGImage?) {
        self.red = red
        self.green = green
        self.blue = blue
        self.isDark = isDark
        self.blurredImage = blurredImage
    }

    static func fallback(dark: Bool) -> DetailArtworkAssets {
        let value = dark ? 0.16 : 0.88
        return DetailArtworkAssets(red: value, green: value, blue: value,
                                       isDark: dark, blurredImage: nil)
    }

    var background: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

actor DetailArtworkProvider {
    static let shared = DetailArtworkProvider()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private final class Box: NSObject {
        let assets: DetailArtworkAssets
        init(_ assets: DetailArtworkAssets) { self.assets = assets }
    }
    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 80
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    func cachedAssets(for url: URL) -> DetailArtworkAssets? {
        cache.object(forKey: url as NSURL)?.assets
    }

    func assets(for url: URL) async -> DetailArtworkAssets? {
        if let cached = cache.object(forKey: url as NSURL) { return cached.assets }
        do {
            var requestURL = url
            if url.host?.hasSuffix(".music.126.net") == true,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var items = components.queryItems ?? []
                items.removeAll { $0.name.caseInsensitiveCompare("param") == .orderedSame }
                items.append(URLQueryItem(name: "param", value: "160y160"))
                components.queryItems = items
                requestURL = components.url ?? url
            }
            let (data, _) = try await URLSession.shared.data(from: requestURL)
            try Task.checkCancellation()
            guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                return nil
            }
            let dimension = max(image.extent.width, image.extent.height)
            if dimension > 160 {
                let scale = CIFilter.lanczosScaleTransform()
                scale.inputImage = image
                scale.scale = Float(160 / dimension)
                scale.aspectRatio = 1
                image = scale.outputImage ?? image
            }
            let average = CIFilter.areaAverage()
            average.inputImage = image
            average.extent = image.extent
            var pixel = [UInt8](repeating: 0, count: 4)
            guard let averageImage = average.outputImage else { return nil }
            context.render(averageImage, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: colorSpace)
            let red = Double(pixel[0]) / 255
            let green = Double(pixel[1]) / 255
            let blue = Double(pixel[2]) / 255
            let isDark = red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.52
            let sourceWeight = isDark ? 0.38 : 0.30
            let neutral = isDark ? 0.055 * 0.62 : 0.94 * 0.70
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = 18
            let blurred = blur.outputImage.flatMap {
                context.createCGImage($0.cropped(to: image.extent.integral), from: image.extent.integral,
                                      format: .RGBA8, colorSpace: colorSpace)
            }
            let assets = DetailArtworkAssets(red: red * sourceWeight + neutral,
                                                   green: green * sourceWeight + neutral,
                                                   blue: blue * sourceWeight + neutral,
                                                   isDark: isDark, blurredImage: blurred)
            cache.setObject(Box(assets), forKey: url as NSURL,
                            cost: blurred.map { $0.width * $0.height * 4 } ?? 0)
            return assets
        } catch {
            return nil
        }
    }
}

struct DetailArtworkBackground: ViewModifier {
    let artworkURL: String?
    var enabled = true
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var assets: DetailArtworkAssets?
    @State private var backgroundID = 0
    @State private var foregroundScheme: ColorScheme?

    private var palette: DetailArtworkAssets {
        assets ?? .fallback(dark: systemScheme == .dark)
    }

    var phoneLayout = PhonePageLayout()
    private var usesArtworkBackground: Bool {
        enabled && phoneLayout.isEnabled
    }

    func body(content: Content) -> some View {
        content
            .background {
                if usesArtworkBackground {
                    GeometryReader { geometry in
                        ZStack {
                            // Keep the base opaque while complete background layers dissolve.
                            DetailArtworkAssets.fallback(dark: systemScheme == .dark).background
                            artworkLayer(palette, size: geometry.size)
                                .id(backgroundID)
                                // Keep outgoing layers opaque until the incoming layer
                                // covers them, avoiding a gray dip halfway through a dissolve.
                                .transition(reduceMotion ? .identity : .asymmetric(
                                    insertion: .opacity,
                                    removal: .opacity.animation(.linear(duration: 0.001).delay(0.55))))
                                .zIndex(Double(backgroundID))
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                    .ignoresSafeArea().accessibilityHidden(true)
                }
                // No artwork background: paint nothing here — the window's
                // theme background shows through instead of the old plain color.
            }
            .preference(key: AppPageBackgroundKey.self,
                        value: usesArtworkBackground ? palette.background : nil)
            .environment(\.colorScheme, usesArtworkBackground ? (foregroundScheme ?? systemScheme) : systemScheme)
            #if os(iOS)
            .toolbarColorScheme(usesArtworkBackground ? (foregroundScheme ?? systemScheme) : systemScheme, for: .navigationBar, .tabBar)
            #endif
            .task(id: "\(artworkURL ?? ""):\(usesArtworkBackground)") {
                guard usesArtworkBackground,
                      let url = artworkURL.flatMap(URL.init(string:)) else { return }
                let provider = DetailArtworkProvider.shared
                let cached = await provider.cachedAssets(for: url)
                let loaded: DetailArtworkAssets?
                if let cached { loaded = cached }
                else { loaded = await provider.assets(for: url) }
                guard !Task.isCancelled, let loaded else { return }
                // A cache hit on first presentation needs no delayed reveal.
                let duration = assets == nil ? 0.4 : 0.55
                let animation: Animation? = reduceMotion || (assets == nil && cached != nil)
                    // Gentle onset followed by a longer settling phase, without
                    // the pronounced middle acceleration of the standard easeInOut.
                    ? nil : .timingCurve(0.25, 0, 0.2, 1, duration: duration)
                withAnimation(animation) {
                    assets = loaded
                    backgroundID += 1
                }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    foregroundScheme = loaded.isDark ? .dark : .light
                }
            }
    }

    private func artworkLayer(_ palette: DetailArtworkAssets, size: CGSize) -> some View {
        ZStack {
            palette.background
            if let image = palette.blurredImage {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .opacity(0.22)
            }
            LinearGradient(colors: palette.isDark
                ? [.black.opacity(0.08), .black.opacity(0.24), .black.opacity(0.40)]
                : [.white.opacity(0.06), .white.opacity(0.16), .white.opacity(0.30)],
                startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
