import SwiftUI

// MARK: - 历史播放记录

struct HistoryView: View {
    @EnvironmentObject private var lib: LibraryStore
    @State private var openingId: Int?
    /// 待播放目标（detail + 集数），item 驱动 fullScreenCover
    @State private var playerTarget: PlayerTarget?
    @State private var openError: String?
    @State private var showOpenError = false
    @State private var checkedIds = Set<Int>()


    var body: some View {
        Group {
            if lib.history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "还没有播放记录\n去首页挑一部剧开始看吧")
            } else {
                historyList
            }
        }
        .navigationTitle("历史播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !lib.history.isEmpty {
                    Button {
                        lib.clearHistory()
                    } label: {
                        Text("清空").foregroundColor(.red)
                    }
                }
            }
        }
        .task {
            await refreshTotals()
        }
        .onReceive(lib.$history) { _ in
            Task { await refreshTotals() }
        }
        .fullScreenCover(item: $playerTarget) { target in
            PlayerScreen(detail: target.detail, startEp: target.epNum)
        }
        .alert("打开失败", isPresented: $showOpenError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .overlay {
            if openingId != nil {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView("正在打开…")
                    .padding(20)
                    .background(Color.white)
                    .cornerRadius(12)
            }
        }
    }

    private var historyList: some View {
        List {
            ForEach(lib.history) { rec in
                historyRowButton(rec)
            }
        }
        .listStyle(.plain)
    }

    private func historyRowButton(_ rec: PlayRecord) -> some View {
        Button {
            open(rec)
        } label: {
            row(rec)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                lib.removeHistory(dramaId: rec.dramaId)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 批量刷新历史剧集的最新总集数（优先用每日检测的共享缓存，缺的才逐条查）
    private func refreshTotals() async {
        for rec in lib.history {
            guard rec.seenTotalEpisodes > 0 else { continue }
            // 共享缓存已有结果直接用
            if let cached = lib.freshTotals[rec.dramaId] {
                if cached == rec.seenTotalEpisodes { continue }
                continue // 有缓存（无论是否有更新）不再重复请求
            }
            guard !checkedIds.contains(rec.dramaId) else { continue }
            do {
                let d = try await SiteAPI.shared.detail(id: rec.dramaId)
                let total = d.totalEpisodes ?? d.episodeCount ?? 0
                checkedIds.insert(rec.dramaId)
                if total > 0 {
                    lib.applyFreshTotal(dramaId: rec.dramaId, total: total)
                    lib.repairBaseline(dramaId: rec.dramaId, total: total)
                }
            } catch {
                // 静默：单条失败不影响列表
            }
        }
    }

    private func row(_ rec: PlayRecord) -> some View {
        HStack(spacing: 12) {
            NetImage(urlString: rec.cover)
                .frame(width: 62, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(rec.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                // 更新提示红字（在"看到 第X集"上方）
                if let current = lib.freshTotals[rec.dramaId],
                   lib.historyHasUpdate(rec, currentTotal: current) {
                    Text("已更新至\(current)集")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                }
                Text("看到 第\(rec.epNum)集 \(fmtTime(rec.position)) / \(fmtTime(rec.duration))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.secondarySystemBackground))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * progressFraction(rec))
                    }
                }
                .frame(height: 3)
            }
            Spacer(minLength: 4)
            Image(systemName: "play.circle")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
        }
        .padding(.vertical, 4)
    }

    private func progressFraction(_ rec: PlayRecord) -> CGFloat {
        guard rec.duration > 0 else { return 0 }
        return CGFloat(min(1, rec.position / rec.duration))
    }

    private func open(_ rec: PlayRecord) {
        guard openingId == nil else { return }
        openingId = rec.dramaId
        Task {
            do {
                let d = try await SiteAPI.shared.detail(id: rec.dramaId)
                openingId = nil
                playerTarget = PlayerTarget(detail: d, epNum: rec.epNum)
            } catch {
                openingId = nil
                openError = error.localizedDescription
                showOpenError = true
            }
        }
    }
}

/// 历史页播放器入口载体
private struct PlayerTarget: Identifiable {
    let detail: DramaDetail
    let epNum: Int
    var id: Int { detail.id * 10000 + epNum }
}

// MARK: - 我的收藏

struct FavoritesView: View {
    @EnvironmentObject private var lib: LibraryStore
    @State private var freshTotals: [Int: Int] = [:]
    @State private var checkedIds = Set<Int>()

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        Group {
            if lib.favorites.isEmpty {
                EmptyStateView(icon: "heart", text: "还没有收藏\n在剧集详情页点击 ♥ 收藏喜欢的短剧")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(lib.favorites) { fav in
                            NavigationLink {
                                DramaDetailView(dramaId: fav.dramaId)
                            } label: {
                                favCard(fav)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    lib.toggleFavorite(dramaId: fav.dramaId,
                                                       title: fav.title,
                                                       cover: fav.cover,
                                                       totalEpisodes: fav.totalEpisodes,
                                                       isFinished: fav.isFinished)
                                } label: {
                                    Label("取消收藏", systemImage: "heart.slash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshTotals()
        }
    }

    @ViewBuilder
    private func favCard(_ fav: FavoriteItem) -> some View {
        let hasNew = hasUpdate(fav)
        let record = lib.progress(dramaId: fav.dramaId)
        DramaCard(title: fav.title,
                  cover: fav.cover,
                  episodeLabel: favEpisodeLabel(fav),
                  bottomAccessory: watchAccessory(record))
            .overlay(alignment: .topTrailing) {
                if hasNew {
                    Text("NEW")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(6)
                }
            }
    }

    /// 观看信息附件（放进封面底部：进度条 + 看到第几集，不与标题重叠）
    private func watchAccessory(_ rec: PlayRecord?) -> AnyView? {
        guard let rec = rec else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.35))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * watchFraction(rec))
                    }
                }
                .frame(height: 3)
                Text("看到第\(rec.epNum)集 \(fmtTime(rec.position)) / \(fmtTime(rec.duration))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        )
    }

    private func watchFraction(_ rec: PlayRecord) -> CGFloat {
        guard rec.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, rec.position / rec.duration)))
    }

    private func hasUpdate(_ fav: FavoriteItem) -> Bool {
        guard let current = lib.freshTotals[fav.dramaId] else { return false }
        return lib.favoriteHasUpdate(fav, currentTotal: current)
    }

    /// 集数标签：优先用检测到的最新集数（收藏时存的是当时的集数）
    private func favEpisodeLabel(_ fav: FavoriteItem) -> String {
        if let current = lib.freshTotals[fav.dramaId], current > fav.totalEpisodes {
            return "更新至\(current)集"
        }
        if fav.isFinished { return "全\(fav.totalEpisodes)集" }
        if fav.totalEpisodes > 0 { return "更新至\(fav.totalEpisodes)集" }
        return ""
    }

    /// 批量刷新收藏剧集的最新总集数（优先用每日检测的共享缓存）
    private func refreshTotals() async {
        for fav in lib.favorites {
            guard !fav.isFinished else { continue }  // 已完结不会有更新
            if lib.freshTotals[fav.dramaId] != nil { continue } // 共享缓存已有
            guard !checkedIds.contains(fav.dramaId) else { continue }
            do {
                let d = try await SiteAPI.shared.detail(id: fav.dramaId)
                let total = d.totalEpisodes ?? d.episodeCount ?? 0
                checkedIds.insert(fav.dramaId)
                if total > 0 {
                    lib.applyFreshTotal(dramaId: fav.dramaId, total: total)
                    lib.repairBaseline(dramaId: fav.dramaId, total: total)
                }
            } catch {
                // 静默
            }
        }
    }
}
