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
    @State private var showPlayer = false
    @State private var startEp = 1
    @State private var descExpanded = false

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
        .fullScreenCover(isPresented: $showPlayer) {
            if let d = model.detail {
                PlayerScreen(detail: d, startEp: startEp)
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
                        startEp = canResume ? (progress?.epNum ?? 1) : (eps.first?.epNum ?? 1)
                        if let d = model.detail {
                            // 播放时刷新历史基准集数（供下次更新检测）
                            lib.markSeenEpisodeCount(dramaId: d.id,
                                                     totalEpisodes: d.totalEpisodes ?? d.episodeCount ?? 0)
                        }
                        showPlayer = true
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
                            .background(Color(white: 0.94))
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
                    let gridColumns = [GridItem(.adaptive(minimum: 74), spacing: 8)]
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(eps) { ep in
                    Button {
                        startEp = ep.epNum
                        if let d = model.detail {
                            lib.markSeenEpisodeCount(dramaId: d.id,
                                                     totalEpisodes: d.totalEpisodes ?? d.episodeCount ?? 0)
                        }
                        showPlayer = true
                    } label: {
                                VStack(spacing: 2) {
                                    Text(ep.title)
                                        .font(.system(size: 12, weight: ep.epNum == progress?.epNum ? .semibold : .regular))
                                        .lineLimit(1)
                                    if ep.duration > 0 {
                                        Text(fmtTime(Double(ep.duration)))
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.75))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(chipColor(ep, progress: progress))
                                .foregroundColor(chipForeground(ep, progress: progress))
                                .cornerRadius(10)
                            }
                        }
                    }
                }
                }
            }
        }
    }

    private func chipColor(_ ep: Episode, progress: PlayRecord?) -> Color {
        if ep.epNum == progress?.epNum { return Color.accentColor }
        return Color(white: 0.94)
    }

    private func chipForeground(_ ep: Episode, progress: PlayRecord?) -> Color {
        if ep.epNum == progress?.epNum { return .white }
        return .primary
    }
}
