import SwiftUI

/// Paste an Apple Music playlist link, pick a signed-in platform, and the
/// playlist is recreated there as a new playlist named "Apple".
struct AppleMusicImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @StateObject private var importer = AppleMusicPlaylistImporter()

    @State private var link = ""
    @State private var selectedProvider: MusicProvider?
    @State private var phase: Phase = .input
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var result: AppleMusicPlaylistImporter.Outcome?
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?

    private enum Phase { case input, importing, done }

    private var providers: [MusicProvider] { importer.loggedInProviders() }

    var body: some View {
        VStack(spacing: Theme.Spacing.section) {
            Text("导入 Apple Music 歌单")
                .font(Theme.Typography.sectionTitle)
                .padding(.top, Theme.Spacing.section)

            switch phase {
            case .input: inputSection
            case .importing: importingSection
            case .done: doneSection
            }

            if phase != .importing {
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Theme.Spacing.section)
            }
        }
        .frame(width: 360)
        .onAppear {
            if selectedProvider == nil {
                let current = account.provider
                selectedProvider = providers.contains(current) ? current : providers.first
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: Theme.Spacing.section) {
            Text("粘贴 Apple Music 歌单链接，歌单会新建在你选的平台上，名字叫「Apple」")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Layout.contentInset)

            TextField("https://music.apple.com/…/playlist/…", text: $link)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Theme.Layout.contentInset)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif

            if providers.isEmpty {
                Text("还没有登录任何音乐平台，请先登录网易云音乐、QQ 音乐、酷狗音乐或汽水音乐，再来导入。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Layout.contentInset)
            } else {
                Picker("导入到", selection: $selectedProvider) {
                    ForEach(providers) { provider in
                        Text(provider.name).tag(Optional(provider))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Layout.contentInset)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Layout.contentInset)
            }

            Button("开始导入") { startImport() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(providers.isEmpty || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Importing

    private var importingSection: some View {
        VStack(spacing: Theme.Spacing.section) {
            ProgressView()
            if progressTotal > 0 {
                Text("正在匹配第 \(progressDone) / \(progressTotal) 首…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("正在读取 Apple Music 歌单…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Button("取消") {
                importTask?.cancel()
                phase = .input
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    // MARK: - Done

    private var doneSection: some View {
        VStack(spacing: Theme.Spacing.section) {
            if let result {
                Text("已导入 \(result.imported) 首到「Apple」（\(result.provider.name)）")
                    .font(Theme.Typography.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Layout.contentInset)
                if !result.playlistTitle.isEmpty {
                    Text("原歌单：\(result.playlistTitle)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.missing.isEmpty {
                    Text("以下 \(result.missing.count) 首在\(result.provider.name)上没找到：")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Layout.contentInset)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.missing, id: \.self) { song in
                                Text("\(song.title)\(song.artist.isEmpty ? "" : " - \(song.artist)")")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }
                    .frame(maxHeight: 220)
                }
                Text("新歌单已出现在你的歌单列表里。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Import

    private func startImport() {
        guard let provider = selectedProvider,
              let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "链接不对，请粘贴 music.apple.com 的歌单链接"
            return
        }
        errorMessage = nil
        progressDone = 0
        progressTotal = 0
        phase = .importing
        importTask?.cancel()
        importTask = Task {
            do {
                let outcome = try await importer.importPlaylist(from: url, to: provider) { done, total in
                    progressDone = done
                    progressTotal = total
                }
                try Task.checkCancellation()
                result = outcome
                phase = .done
                await account.refreshLibrary()
                ToastCenter.shared.show("已导入 \(outcome.imported) 首到「Apple」")
            } catch is CancellationError {
                phase = .input
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    phase = .input
                }
            }
        }
    }
}
