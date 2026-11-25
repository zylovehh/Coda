import SwiftUI
import CoreImage.CIFilterBuiltins

struct PlatformLoginSheet: View {
    let provider: MusicProvider
    /// Adds the scanned account to the list instead of switching to it.
    var addsAccount = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: PlatformImage?
    @State private var qqChannel = QQMusicLoginChannel.qq
    @State private var status = "正在获取二维码…"
    @State private var isSaving = false
    @StateObject private var qishuiAuth = QishuiMusicAPI(diagnostics: true)
    @StateObject private var qqAuth = QQMusicAuth(persistsSession: false)
    /// The running login task, so returning from the music app can tell whether
    /// polling is still alive. A single failed poll must not end the login:
    /// the request in flight when the user leaves to scan is routinely cut off.
    @State private var loginTask: Task<Void, Never>?
    /// The QR session being polled, kept so polling can resume with the same
    /// code instead of showing a dead screen or a fresh code.
    @State private var kugouKey = ""
    @State private var qishuiToken = ""
    /// Consecutive poll failures tolerated before giving up (about 18 seconds).
    private static let maxConsecutivePollErrors = 6

    private enum PollOutcome {
        case waiting(String)
        case scanned(String)
        case expired
        case failed(String)
        case success([String: String], String)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.section) {
            Text(addsAccount ? "添加\(provider.name)账号" : "登录\(provider.name)").font(Theme.Typography.sectionTitle)
                .padding(.top, Theme.Spacing.section)
            if provider == .qq {
                Picker("扫码方式", selection: $qqChannel) {
                    ForEach(QQMusicLoginChannel.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(isSaving)
                .onChange(of: qqChannel) { _ in startLogin() }
            }
            Text(provider == .qishui ? "请使用已登录的汽水音乐 App 扫码并确认登录" : provider == .qq ? "请使用\(qqChannel.name)扫描二维码并确认登录" : "请使用酷狗音乐扫描二维码并确认登录")
                .font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LoginQRCodeFrame(image: image) { EmptyView() }
            Text(status).font(Theme.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("刷新二维码") { startLogin() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                .disabled(isSaving)
            Button("取消") { dismiss() }
                .buttonStyle(.plain).font(Theme.Typography.caption).foregroundStyle(.secondary)
                .padding(.bottom, Theme.Spacing.section).disabled(isSaving)
        }
        .frame(width: 320)
        .interactiveDismissDisabled(isSaving)
        .onAppear { startLogin() }
        .onDisappear {
            loginTask?.cancel()
            if provider == .qishui { qishuiAuth.cancelLogin() }
        }
        // Coming back from the music app: if polling died while the app was in
        // the background, pick it up with the same QR code the user scanned.
        .onChange(of: scenePhase) { _ in
            guard scenePhase == .active, !isSaving, image != nil,
                  loginTask == nil || loginTask?.isCancelled == true else { return }
            if provider == .qishui || provider == .kugou || (provider == .qq && qqChannel == .qq) {
                loginTask = Task { await pollLoop() }
            } else {
                startLogin()
            }
        }
        .sheet(isPresented: Binding(get: { qishuiAuth.verificationWebView != nil }, set: { if !$0 { qishuiAuth.cancelVerification() } })) {
            if let web = qishuiAuth.verificationWebView {
                QishuiSecurityVerificationView(webView: web, onCancel: { qishuiAuth.cancelVerification() })
            }
        }
    }

    /// Starts a fresh QR code (used on appear, on refresh and on channel switch).
    private func startLogin() {
        loginTask?.cancel()
        kugouKey = ""
        qishuiToken = ""
        loginTask = Task { await runLogin() }
    }

    private func runLogin() async {
        image = nil
        status = "正在获取二维码…"
        do {
            if provider == .qishui {
                let qr = try await qishuiAuth.qrCode()
                try Task.checkCancellation()
                qishuiToken = qr.token
                guard let decoded = Self.qrImage(qr.scanURL.absoluteString) else { throw QishuiError.invalidResponse }
                image = decoded
                status = "等待使用汽水音乐扫码"
                await pollLoop()
                return
            }
            if provider == .qq, qqChannel != .qq {
                let channel = qqChannel
                let result = try await QQMusicAdditionalLogin.signIn(channel, onImage: { data in
                    image = PlatformImage(data: data)
                    status = "等待使用\(channel.name)扫码"
                }, onScanned: {
                    status = "已扫码，请在\(channel.name)中确认"
                })
                try Task.checkCancellation()
                await finish(credentials: result.credentials, nickname: result.nickname)
                return
            }
            if provider == .qq {
                let data = try await qqAuth.fetchQRCode()
                try Task.checkCancellation()
                image = PlatformImage(data: data)
            } else {
                let qr = try await KugouMusicAPI.shared.qrKey()
                try Task.checkCancellation()
                kugouKey = qr.key
                image = Self.qrImage(qr.url)
            }
            status = "等待扫码"
            await pollLoop()
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { status = error.localizedDescription } }
    }

    /// Polls the QR state until it succeeds, expires or fails for good.
    /// Transient failures (the usual one is the request cut off when the app
    /// goes to the background while the user scans) are retried instead of
    /// leaving the login stuck on the QR screen.
    private func pollLoop() async {
        var consecutiveErrors = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if Task.isCancelled { return }
            do {
                let outcome = try await pollOnce()
                consecutiveErrors = 0
                switch outcome {
                case .waiting(let text): status = text
                case .scanned(let text): status = text
                case .expired: status = "二维码已过期，请刷新"; return
                case .failed(let message): status = message; return
                case .success(let credentials, let nickname):
                    await finish(credentials: credentials, nickname: nickname)
                    return
                }
            } catch is CancellationError { return }
            catch {
                consecutiveErrors += 1
                if consecutiveErrors >= Self.maxConsecutivePollErrors {
                    status = error.localizedDescription
                    return
                }
            }
        }
    }

    /// One poll round against the QR code fetched by runLogin.
    private func pollOnce() async throws -> PollOutcome {
        if provider == .qishui {
            if qishuiAuth.isQRCodeExpired(token: qishuiToken) { return .expired }
            switch try await qishuiAuth.pollQRCode(token: qishuiToken) {
            case .waiting: return .waiting("等待使用汽水音乐扫码")
            case .scanned: return .scanned("已扫码，请在汽水音乐中确认")
            case .processing: return .waiting("正在等待平台完成登录，请稍候…")
            case .expired: return .expired
            case .confirmed(let credentials):
                return .success(credentials, credentials["nickname"] ?? "汽水音乐用户")
            }
        }
        if provider == .qq {
            switch try await qqAuth.poll() {
            case .waiting: return .waiting("等待扫码")
            case .scanned: return .scanned("已扫码，请在 QQ 中确认")
            case .expired: return .expired
            case .error(let message): return .failed(message)
            case .success(let nickname): return .success(qqAuth.exportedCredentials, nickname)
            }
        }
        switch try await KugouMusicAPI.shared.pollQR(key: kugouKey) {
        case .waiting: return .waiting("等待扫码")
        case .scanned: return .scanned("已扫码，请在酷狗音乐中确认")
        case .expired: return .expired
        case .error(let message): return .failed(message)
        case .success(let credentials): return .success(credentials, credentials["nickname"] ?? "酷狗音乐用户")
        }
    }

    private func finish(credentials: [String: String], nickname: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            if addsAccount {
                let item = try await MusicAccountManager.shared.addAccount(provider: provider, credentials: credentials, nickname: nickname)
                ToastCenter.shared.show(MusicAccountManager.shared.addedMessage(for: item))
            } else {
                try await MusicAccountManager.shared.saveAndActivate(provider: provider, credentials: credentials, nickname: nickname)
            }
            dismiss()
        } catch { status = error.localizedDescription }
    }
    private static func qrImage(_ value: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
