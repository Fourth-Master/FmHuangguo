import SwiftUI

// MARK: - 标签内容页（/api/videos/tag/{标签名}）

@MainActor
final class TagModel: ObservableObject {
    @Published var items: [DramaSummary] = []
    @Published var loading = false
    @Published var error: String?

    let tag: String
    private var nextPage = 1
    private var totalPages = 1
    private var loadingMore = false

    init(tag: String) {
        self.tag = tag
    }

    func reload() async {
        error = nil
        loading = true
        do {
            let r = try await SiteAPI.shared.tagList(tag: tag, page: 1, sort: nil)
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
            let r = try await SiteAPI.shared.tagList(tag: tag, page: nextPage, sort: nil)
            await MainActor.run {
                let existing = Set(self.items.map(\.id))
                self.items += r.items.filter { !existing.contains($0.id) }
                self.totalPages = r.pagination?.pages ?? self.totalPages
                self.nextPage += 1
            }
        } catch {
            // 加载更多失败静默
        }
    }
}

struct TagView: View {
    @StateObject private var model: TagModel

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    init(tagName: String) {
        _model = StateObject(wrappedValue: TagModel(tag: tagName))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .navigationTitle("#\(model.tag)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.items.isEmpty { await model.reload() }
        }
        .refreshable {
            await model.reload()
        }
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
            ErrorRetryView(message: err) {
                Task { await model.reload() }
            }
        } else if model.items.isEmpty {
            EmptyStateView(icon: "tag", text: "该标签下暂无内容")
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
