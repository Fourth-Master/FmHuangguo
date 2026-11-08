import SwiftUI

// MARK: - 搜索

@MainActor
final class SearchModel: ObservableObject {
    @Published var items: [DramaSummary] = []
    @Published var loading = false
    @Published var searched = false
    @Published var error: String?

    func search(_ kw: String) async {
        let keyword = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        error = nil
        loading = true
        searched = true
        do {
            let r = try await SiteAPI.shared.list(category: nil, kw: keyword, sort: nil, page: 1, size: 42)
            await MainActor.run { items = r.items }
            self.error = nil
        } catch {
            await MainActor.run { items = [] }
            self.error = error.localizedDescription
        }
        self.loading = false
    }
}

struct SearchView: View {
    @StateObject private var model = SearchModel()
    @State private var text = ""
    @State private var history: [String] = UserDefaults.standard.stringArray(forKey: "search_history") ?? []

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                TextField("搜索短剧名称 / 关键词", text: $text)
                    .font(.system(size: 14))
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { go() }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(white: 0.75))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.94))
            .cornerRadius(18)

            Button {
                go()
            } label: {
                Text("搜索")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !model.searched {
            historySection
        } else if model.loading {
            VStack {
                Spacer()
                ProgressView("搜索中…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let err = model.error {
            ErrorRetryView(message: err) {
                Task { await model.search(text) }
            }
        } else if model.items.isEmpty {
            EmptyStateView(icon: "magnifyingglass", text: "没有找到相关短剧")
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
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !history.isEmpty {
                HStack {
                    Text("搜索历史")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        history = []
                        UserDefaults.standard.set([String](), forKey: "search_history")
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                FlowChips(items: history) { kw in
                    text = kw
                    go()
                }
                .padding(.horizontal, 14)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func go() {
        let kw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        if let idx = history.firstIndex(of: kw) {
            history.remove(at: idx)
        }
        history.insert(kw, at: 0)
        if history.count > 12 { history = Array(history.prefix(12)) }
        UserDefaults.standard.set(history, forKey: "search_history")
        Task { await model.search(kw) }
    }
}

// MARK: - 简易流式标签（搜索历史）

struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 80), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { kw in
                Button {
                    onTap(kw)
                } label: {
                    Text(kw)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(white: 0.94))
                        .foregroundColor(.primary)
                        .cornerRadius(14)
                }
            }
        }
    }
}
