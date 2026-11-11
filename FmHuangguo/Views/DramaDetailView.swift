import SwiftUI

// MARK: - 剧集详情

@MainActor
final class DetailModel: ObservableObject {
    @Published var detail: DramaDetail?
    @Published var loading = true
    @Published var error: String?
    let dramaId: Int

    init(dramaId: Int) {
        self.dramaId = dramaId
    }

    func load() async {
        loading = true
        do {
            let d = try await SiteAPI.shared.detail(id: dramaId)
            await MainActor.run { detail = d }
            self.error = nil
        } catch {
            await MainActor.run { detail = nil }
            self.error = error.localizedDescription
        }
        self.loading = false
    }
}

struct DramaDetailView: View {
    let dramaId: Int
    @StateObject private var model: DetailModel
    @EnvironmentObject private var lib: LibraryStore
    @State private var playerEpisode: EpisodeTarget?
    @State private var descExpanded = false

    /// 当前要播放的目标集（nil = 关闭播放器）。item 驱动避免 iOS 15 fullScreenCover 内容取到旧状态。
    struct EpisodeTarget: Identifiable {
        let epNum: Int
        var id: Int { epNum }
    }

    init(dramaId: Int) {
        self.dramaId = dramaId
        _model = StateObject(wrappedValue: DetailModel(dramaId: dramaId))
    }

    var body: some View {
        Group {
            if let d = model.detail {
                content(d)
            } else if model.loading {
                VStack {
                    Spacer()
                    ProgressView("加载中…")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ErrorRetryView(message: model.error ?? "加载失败") {
                    Task { await model.load() }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.detail == nil {
                await model.load()
            }
        }
        .onChange(of: model.detail?.totalEpisodes) { total in
            // 进入详情即清除更新提示（历史红字与收藏 NEW 双向同步清除）
            if let d = model.detail, let total = total, total > 0 {
                lib.clearUpdateBadge(dramaId: d.id, currentTotalEpisodes: total)
            }
        }
        .fullScreenCover(item: $playerEpisode) { target in
            if let d = model.detail {
                PlayerScreen(detail: d, startEp: target.epNum)
            }
        }
    }

    private func content(_ d: DramaDetail) -> some View {
        let eps = d.episodeList
        let progress = lib.progress(dramaId: d.id)
        let canResume = progress != nil && eps.contains { $0.epNum == progress?.epNum }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Hero 头部：封面模糊背景 + 前景信息
                ZStack(alignment: .bottomLeading) {
                    NetImage(urlString: d.cover)
                        .frame(height: 210)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(VisualEffectBlur(style: .systemUltraThinMaterialDark))
                        .overlay(LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.62)],
                                                startPoint: .top, endPoint: .bottom))
                    HStack(alignment: .bottom, spacing: 12) {
                        NetImage(urlString: d.cover)
                            .frame(width: 108)
                            .aspectRatio(0.72, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(3)
                                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            HStack(spacing: 8) {
                                if let s = d.score, s > 0 {
                                    Text(String(format: "%.1f分", s))
                                        .font(.system(size: 12, weight: .heavy))
                                        .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.20))
                                }
                                Text(d.episodeCount.map { "\($0)集" } ?? "")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.85))
                                if d.isFinished == true {
                                    Text("已完结")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.green.opacity(0.85))
                                        .foregroundColor(.white)
                                        .cornerRadius(4)
                                }
                            }
                            HStack(spacing: 6) {
                                ForEach((d.tags ?? []).prefix(3), id: \.self) { t in
                                    Text(t)
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.white.opacity(0.18))
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 0))

                VStack(alignment: .leading, spacing: 16) {
                // 操作按钮
                HStack(spacing: 12) {
                    Button {
                        haptic(.medium)
                        let target = canResume ? (progress?.epNum ?? 1) : (eps.first?.epNum ?? 1)
                        if let d = model.detail {
                            // 播放时刷新历史基准集数（供下次更新检测）
                            lib.markSeenEpisodeCount(dramaId: d.id,
                                                     totalEpisodes: d.totalEpisodes ?? d.episodeCount ?? 0)
                        }
                        playerEpisode = EpisodeTarget(epNum: target)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text(canResume ? "继续播放 第\(progress?.epNum ?? 1)集" : "立即播放")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Color(red: 0.98, green: 0.27, blue: 0.57),
                                                            Color(red: 0.85, green: 0.15, blue: 0.45)],
                                                   startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(24)
                        .shadow(color: Color(red: 0.98, green: 0.27, blue: 0.57).opacity(0.35), radius: 8, y: 3)
                    }
                    Button {
                        haptic()
                        lib.toggleFavorite(dramaId: d.id,
                                           title: d.title,
                                           cover: d.cover ?? "",
                                           totalEpisodes: d.totalEpisodes ?? d.episodeCount ?? 0,
                                           isFinished: d.isFinished ?? false)
                    } label: {
                        Image(systemName: lib.isFavorite(d.id) ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundColor(lib.isFavorite(d.id) ? .pink : .secondary)
                            .frame(width: 48, height: 48)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(24)
                    }
                }

                // 简介
                if let desc = d.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介")
                            .font(.system(size: 15, weight: .semibold))
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(descExpanded ? nil : 3)
                        Button {
                            descExpanded.toggle()
                        } label: {
                            Text(descExpanded ? "收起" : "展开全部")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                // 选集
                if !eps.isEmpty {
                    HStack {
                        Text("选集")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("共\(eps.count)集")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    let gridColumns = [GridItem(.adaptive(minimum: 78), spacing: 8)]
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(eps) { ep in
                            episodeChip(ep, progress: progress)
                        }
                    }
                }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    /// 选集 chip：统一「第N集」+ 时长；当前集高亮，已看集右上角小圆点
    private func episodeChip(_ ep: Episode, progress: PlayRecord?) -> some View {
        let isCurrent = ep.epNum == progress?.epNum
        let isWatched = (progress?.epNum ?? 0) > ep.epNum
        return Button {
            haptic()
            if let d = model.detail {
                lib.markSeenEpisodeCount(dramaId: d.id,
                                         totalEpisodes: d.totalEpisodes ?? d.episodeCount ?? 0)
            }
            playerEpisode = EpisodeTarget(epNum: ep.epNum)
        } label: {
            VStack(spacing: 3) {
                Text("第\(ep.epNum)集")
                    .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(fmtTime(Double(ep.duration)))
                    .font(.system(size: 10))
                    .foregroundColor(isCurrent ? .white.opacity(0.92) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .overlay(alignment: .topTrailing) {
                if isWatched && !isCurrent {
                    Circle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
