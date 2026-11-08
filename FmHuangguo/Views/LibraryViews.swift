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

    var body: some View {
        Group {
            if lib.history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "还没有播放记录\n去首页挑一部剧开始看吧")
            } else {
                List {
                    ForEach(lib.history) { rec in
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
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("历史播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !lib.history.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        lib.clearHistory()
                    } label: {
                        Text("清空").foregroundColor(.red)
                    }
                }
            }
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

    private func row(_ rec: PlayRecord) -> some View {
        HStack(spacing: 12) {
            NetImage(urlString: rec.cover)
                .frame(width: 62, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(rec.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
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
                                DramaCard(title: fav.title,
                                          cover: fav.cover,
                                          episodeLabel: fav.isFinished ? "全\(fav.totalEpisodes)集" : (fav.totalEpisodes > 0 ? "更新至\(fav.totalEpisodes)集" : ""))
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
    }
}
