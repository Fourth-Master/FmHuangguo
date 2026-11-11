import SwiftUI

// MARK: - 缓存管理页（下载中/已缓存，支持离线播放与删除）

struct DownloadsView: View {
    @EnvironmentObject private var cache: VideoCacheManager
    @State private var playerTarget: OfflinePlayerTarget?

    var body: some View {
        Group {
            if cache.cachedEpisodes.isEmpty {
                EmptyStateView(icon: "arrow.down.circle", text: "还没有缓存视频\n播放时点击底部 ⬇ 按钮缓存当前集")
            } else {
                List {
                    ForEach(sortedStates, id: \.key) { item in
                        row(item.key, state: item.state)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("我的缓存")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playerTarget) { target in
            PlayerScreen(detail: target.detail, startEp: target.epNum)
        }
    }

    private var sortedStates: [(key: String, state: VideoCacheManager.CachedEpisodeState)] {
        cache.cachedEpisodes
            .map { (key: $0.key, state: $0.value) }
            .sorted { $0.key > $1.key }  // 新缓存的 key 大（dramaId_epNum 数值拼接）
    }

    @ViewBuilder
    private func row(_ key: String, state: VideoCacheManager.CachedEpisodeState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state.done ? "checkmark.circle.fill" : (state.progress < 0 ? "exclamationmark.circle.fill" : "arrow.down.circle.fill"))
                .font(.system(size: 22))
                .foregroundColor(state.done ? .green : (state.progress < 0 ? .red : .accentColor))
            VStack(alignment: .leading, spacing: 5) {
                Text("\(state.title) 第\(state.epNum)集")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if state.done {
                    Text(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else if state.progress < 0 {
                    Text("缓存失败")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.secondarySystemBackground))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(max(0, min(1, state.progress))))
                        }
                    }
                    .frame(height: 4)
                }
            }
            Spacer()
            if state.done {
                Button {
                    openOffline(state)
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 26))
                        .foregroundColor(.accentColor)
                }
            }
            Button(role: .destructive) {
                cache.delete(dramaId: state.dramaId, epNum: state.epNum)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundColor(.red)
            }
            .padding(.leading, 4)
        }
        .padding(.vertical, 4)
    }

    private func openOffline(_ state: VideoCacheManager.CachedEpisodeState) {
        Task {
            do {
                let d = try await SiteAPI.shared.detail(id: state.dramaId)
                playerTarget = OfflinePlayerTarget(detail: d, epNum: state.epNum)
            } catch {
                DebugLogger.shared.log("离线打开详情失败: \(error.localizedDescription)")
            }
        }
    }

    @State private var openingLock = true
}

/// 离线播放入口载体
struct OfflinePlayerTarget: Identifiable {
    let detail: DramaDetail
    let epNum: Int
    var id: Int { detail.id * 10000 + epNum }
}
