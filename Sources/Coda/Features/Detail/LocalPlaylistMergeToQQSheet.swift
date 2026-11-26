import SwiftUI

/// Merges a local playlist into one of the user's own QQ playlists.
///
/// The user picks one of their own QQ playlists (or creates a new one), and
/// every song of the local playlist is resolved to a QQ song and added,
/// skipping songs that are already in the target. The local playlist itself
/// is not changed.
struct LocalPlaylistMergeToQQSheet: View {
    let playlist: LocalPlaylist
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var targets: [ProviderPlaylist] = []
    @State private var query = ""
    @State private var showsCreate = false
    @State private var newName: String
    @State private var statusText = ""
    @State private var progress = (done: 0, total: 0)
    @State private var result: QQPlaylistMerger.Outcome?
    @State private var errorMessage: String?
    @State private var mergeTask: Task<Void, Never>?

    private enum Phase {
        case loading, needsLogin, pick, merging, done, failed
    }

    init(playlist: LocalPlaylist) {
        self.playlist = playlist
        _newName = State(initialValue: playlist.name)
    }

    private var filteredTargets: [ProviderPlaylist] {
        query.isEmpty ? targets : targets.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        sheetContent
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
            .task { await loadTargets() }
            .onDisappear { mergeTask?.cancel() }
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            content.presentationBackground(Theme.barMaterial)
        } else {
            content.background(Theme.barMaterial)
        }
        #else
        content.background(Theme.barMaterial)
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.component) {
            header
            switch phase {
            case .loading:
                ProgressView("正在加载 QQ 歌单…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .needsLogin:
                Text("请先在「我的」里登录 QQ 音乐，再把本地歌单合并过去。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            case .pick:
                pickContent
            case .merging:
                mergingContent
            case .done:
                doneContent
            case .failed:
                VStack(alignment: .leading, spacing: Theme.Spacing.component) {
                    Text(errorMessage ?? "合并失败，请重试。")
                        .foregroundStyle(.secondary)
                    Button("返回") { phase = .pick }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, Theme.Spacing.component)
        .padding(.bottom, Theme.Spacing.small)
    }

    private var header: some View {
        HStack {
            Text("合并到 QQ 歌单")
                .font(Theme.Typography.sectionTitle.weight(.bold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("关闭")
            .disabled(phase == .merging)
        }
    }

    private var pickContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.component) {
            Text("选一个 QQ 歌单，把「\(playlist.name)」里的歌合并过去。已经在里面的歌会自动跳过。")
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Spacing.control) {
                Image(systemName: "magnifyingglass")
                TextField("搜索歌单", text: $query)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .submitLabel(.search)
                    #endif
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("清除搜索")
                }
            }
            .foregroundStyle(.secondary)
            .padding(Theme.Spacing.control)
            .background(.primary.opacity(0.08), in: Capsule())
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    Button { showsCreate.toggle() } label: {
                        HStack {
                            Image(systemName: "plus")
                            Text("新建 QQ 歌单")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, Theme.Spacing.small)
                    Divider()
                    ForEach(filteredTargets) { target in
                        Button { startMerge(into: target) } label: {
                            HStack {
                                Text(target.name)
                                Spacer()
                                Text("\(target.trackCount) 首")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, Theme.Spacing.small)
                        Divider()
                    }
                    if filteredTargets.isEmpty && !showsCreate {
                        Text(query.isEmpty ? "你还没有自建的 QQ 歌单" : "没有找到匹配的歌单")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
            }
            if showsCreate {
                HStack {
                    TextField("新歌单名字", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("创建并合并") { createAndMerge() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var mergingContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.component) {
            Text(statusText)
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                Text("正在合并 \(progress.done) / \(progress.total) 首")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Button("取消", role: .cancel) {
                mergeTask?.cancel()
                phase = .pick
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.component) {
            if let result {
                Text("已合并到「\(result.targetName)」")
                    .font(Theme.Typography.sectionTitle.weight(.bold))
                Text("已合并 \(result.added) 首，跳过 \(result.skippedDuplicate) 首重复，\(result.notFound.count) 首在 QQ 上找不到。")
                    .foregroundStyle(.secondary)
                if !result.notFound.isEmpty {
                    Text("在 QQ 上找不到的歌")
                        .font(Theme.Typography.secondary.weight(.semibold))
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.notFound.enumerated()), id: \.offset) { _, track in
                                Text("\(track.name) — \(track.artists.first?.name ?? "")")
                                    .font(Theme.Typography.secondary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func loadTargets() async {
        guard UnblockSessionPool.shared.hasAccount(.qq) else {
            phase = .needsLogin
            return
        }
        do {
            targets = try await QQPlaylistMerger.ownedQQPlaylists()
            phase = .pick
        } catch {
            errorMessage = Self.errorMessage(for: error)
            phase = .failed
        }
    }

    private func startMerge(into target: ProviderPlaylist) {
        phase = .merging
        statusText = "正在合并到「\(target.name)」…"
        progress = (0, playlist.tracks.count)
        mergeTask = Task {
            do {
                let outcome = try await QQPlaylistMerger.merge(playlist, into: target) { done, total in
                    progress = (done, total)
                }
                result = outcome
                phase = .done
            } catch is CancellationError {
                phase = .pick
            } catch {
                errorMessage = Self.errorMessage(for: error)
                phase = .failed
            }
        }
    }

    private func createAndMerge() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        phase = .merging
        statusText = "正在创建 QQ 歌单…"
        progress = (0, playlist.tracks.count)
        mergeTask = Task {
            do {
                let target = try await QQPlaylistMerger.createQQPlaylist(name: name)
                statusText = "正在合并到「\(target.name)」…"
                let outcome = try await QQPlaylistMerger.merge(playlist, into: target) { done, total in
                    progress = (done, total)
                }
                result = outcome
                phase = .done
            } catch is CancellationError {
                phase = .pick
            } catch {
                errorMessage = Self.errorMessage(for: error)
                phase = .failed
            }
        }
    }

    private static func errorMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
