import SwiftUI

// MARK: - 剧集卡片

struct DramaCard: View {
    let title: String
    let cover: String?
    let episodeLabel: String
    var scoreText: String = ""
    var tagText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            NetImage(urlString: cover)
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottom) {
                    // 底部渐变遮罩，衬托角标
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    if !episodeLabel.isEmpty {
                        Text(episodeLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.black.opacity(0.62))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !scoreText.isEmpty {
                        Text(scoreText)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(
                                LinearGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.11),
                                                        Color(red: 0.98, green: 0.42, blue: 0.11)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.10), radius: 5, y: 3)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !tagText.isEmpty {
                Text(tagText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension DramaSummary {
    var cardView: DramaCard {
        DramaCard(title: title,
                  cover: cover,
                  episodeLabel: episodeLabel,
                  scoreText: (score != nil && score! > 0) ? String(format: "%.1f分", score!) : "",
                  tagText: (tags?.prefix(2) ?? []).joined(separator: " "))
    }
}

// MARK: - 分类定义

struct Category: Identifiable, Hashable {
    let id: String     // slug，空 = 综合
    let name: String
}

let AppCategories: [Category] = [
    Category(id: "", name: "综合"),
    Category(id: "ai-duanju", name: "AI短剧"),
    Category(id: "ai-manju", name: "AI漫剧"),
    Category(id: "ai-huanlian", name: "AI换脸"),
    Category(id: "ai-mogai", name: "AI魔改"),
    Category(id: "chigua", name: "吃瓜"),
]

let AppSorts: [(id: String, name: String)] = [
    ("", "最新"),
    ("hot_window", "最热"),
    ("random", "随机"),
]

// MARK: - 首页

@MainActor
final class HomeModel: ObservableObject {
    @Published var items: [DramaSummary] = []
    @Published var category: String = ""
    @Published var sort: String = ""
    @Published var loading = false
    @Published var error: String?

    private var nextPage = 1
    private var totalPages = 1
    private var loadingMore = false

    func reload() async {
        error = nil
        loading = true
        nextPage = 1
        totalPages = 1
        do {
            let r = try await SiteAPI.shared.list(category: category.isEmpty ? nil : category,
                                                  kw: nil,
                                                  sort: sort.isEmpty ? nil : sort,
                                                  page: 1)
            await MainActor.run {
                items = r.items
                totalPages = r.pagination?.pages ?? 1
                nextPage = 2
            }
            self.error = nil
        } catch {
            await MainActor.run { items = [] }
            self.error = error.localizedDescription
        }
        self.loading = false
    }

    func loadMore() async {
        guard !loadingMore, nextPage <= totalPages, error == nil else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let r = try await SiteAPI.shared.list(category: category.isEmpty ? nil : category,
                                                  kw: nil,
                                                  sort: sort.isEmpty ? nil : sort,
                                                  page: nextPage)
            await MainActor.run {
                let existing = Set(self.items.map(\.id))
                self.items += r.items.filter { !existing.contains($0.id) }
                self.totalPages = r.pagination?.pages ?? self.totalPages
                self.nextPage += 1
            }
        } catch {
            // 加载更多失败静默处理，可再次下拉或滚动重试
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model = HomeModel()
    @State private var hotTags: [String] = []
    @State private var showSearch = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            chipsRow
            hotTagsRow
            content
        }
        .navigationTitle("Fm黄果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationView { SearchView() }
                .navigationViewStyle(.stack)
        }
        .task(id: "\(model.category)|\(model.sort)") {
            await model.reload()
        }
        .task {
            if hotTags.isEmpty { await loadHotTags() }
        }
        .refreshable {
            await model.reload()
            await loadHotTags()
        }
    }

    private func loadHotTags() async {
        do {
            let tags = try await SiteAPI.shared.hotTags()
            await MainActor.run { hotTags = Array(tags.prefix(8)) }
        } catch {
            // 静默：热门标签获取失败不影响列表
        }
    }

    /// 热门标签行（🔥 前缀 + 标签 chips，点击进搜索页搜该词）
    @ViewBuilder
    private var hotTagsRow: some View {
        if !hotTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    ForEach(hotTags, id: \.self) { tag in
                        NavigationLink {
                            SearchView(initialKeyword: tag)
                        } label: {
                            Text(tag)
                                .font(.system(size: 12))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Color.orange.opacity(0.10))
                                .foregroundColor(.orange)
                                .cornerRadius(13)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 6)
        }
    }

    private var chipsRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppCategories) { c in
                        Button {
                            model.category = c.id
                        } label: {
                            Text(c.name)
                                .font(.system(size: 13, weight: model.category == c.id ? .semibold : .regular))
                                .padding(.horizontal, 13).padding(.vertical, 6)
                                .background(model.category == c.id ? Color.accentColor : Color(white: 0.94))
                                .foregroundColor(model.category == c.id ? .white : .primary)
                                .cornerRadius(15)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            Menu {
                Picker("排序", selection: $model.sort) {
                    ForEach(AppSorts, id: \.id) { s in
                        Text(s.name).tag(s.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundColor(model.sort.isEmpty ? .secondary : .accentColor)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.items.isEmpty {
            VStack {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let err = model.error, model.items.isEmpty {
            ErrorRetryView(message: err, extraActionTitle: "换线路") {
                Task { await app.startRouting(force: true) }
            } onRetry: {
                Task { await model.reload() }
            }
        } else if model.items.isEmpty {
            EmptyStateView(icon: "film", text: "暂无内容")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.items) { item in
                        NavigationLink {
                            DramaDetailView(dramaId: item.id)
                        } label: {
                            item.cardView
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await model.loadMore() }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }
}
