import SwiftUI

// MARK: - 历史播放记录

struct HistoryView: View {
    @EnvironmentObject private var lib: LibraryStore
    @State private var openingId: Int?
    @State private var playerDetail: DramaDetail?
    @State private var startEp = 1
    @State private var showPlayer = false
    @State private var openError: String?
    @State private var showOpenError = false
    /// 当前各剧集最新总集数（dramaId -> total），用于"已更新至X集"红字
    @State private var freshTotals: [Int: Int] = [:]
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
        .fullScreenCover(isPresented: $showPlayer) {
            if let d = playerDetail {
                PlayerScreen(detail: d, startEp: startEp)
            }
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

    /// 批量刷新历史剧集的最新总集数（只查尚未检查过、且可能有更新的条目）
    private func refreshTotals() async {
        for rec in lib.history {
            guard !checkedIds.contains(rec.dramaId), rec.seenTotalEpisodes > 0 else { continue }
            // 已是最新（缓存值与基准一致）不再请求
            if let cached = freshTotals[rec.dramaId], cached == rec.seenTotalEpisodes { continue }
            do {
                let d = try await SiteAPI.shared.detail(id: rec.dramaId)
                let total = d.totalEpisodes ?? d.episodeCount ?? 0
                checkedIds.insert(rec.dramaId)
                if total > 0 {
                    freshTotals[rec.dramaId] = total
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
                if let current = freshTotals[rec.dramaId],
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
                        Capsule().fill(Color(white: 0.92))
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
                playerDetail = d
                startEp = rec.epNum
                openingId = nil
                showPlayer = true
            } catch {
                openingId = nil
                openError = error.localizedDescription
                showOpenError = true
            }
        }
    }
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
        DramaCard(title: fav.title,
                  cover: fav.cover,
                  episodeLabel: fav.isFinished ? "全\(fav.totalEpisodes)集" : (fav.totalEpisodes > 0 ? "更新至\(fav.totalEpisodes)集" : ""))
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

    private func hasUpdate(_ fav: FavoriteItem) -> Bool {
        guard let current = freshTotals[fav.dramaId] else { return false }
        return lib.favoriteHasUpdate(fav, currentTotal: current)
    }

    private func refreshTotals() async {
        for fav in lib.favorites {
            guard !checkedIds.contains(fav.dramaId) else { continue }
            guard !fav.isFinished else { continue }  // 已完结不会有更新
            do {
                let d = try await SiteAPI.shared.detail(id: fav.dramaId)
                let total = d.totalEpisodes ?? d.episodeCount ?? 0
                checkedIds.insert(fav.dramaId)
                if total > 0 {
                    freshTotals[fav.dramaId] = total
                }
            } catch {
                // 静默
            }
        }
    }
}
