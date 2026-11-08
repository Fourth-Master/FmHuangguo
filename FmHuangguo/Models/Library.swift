import Foundation

// MARK: - 播放记录 / 收藏 数据模型

struct PlayRecord: Codable, Identifiable {
    var id: Int { dramaId }
    let dramaId: Int
    var title: String
    var cover: String
    var epNum: Int
    var epVideoId: String
    var position: Double
    var duration: Double
    var updatedAt: Date
}

struct FavoriteItem: Codable, Identifiable {
    var id: Int { dramaId }
    let dramaId: Int
    var title: String
    var cover: String
    var totalEpisodes: Int
    var isFinished: Bool
    var addedAt: Date
}

struct LibraryData: Codable {
    var history: [PlayRecord] = []
    var favorites: [FavoriteItem] = []
}

// MARK: - 本地持久化（Documents/library.json）

final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var history: [PlayRecord] = []
    @Published private(set) var favorites: [FavoriteItem] = []

    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("library.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let lib = try? decoder.decode(LibraryData.self, from: data) {
            history = lib.history
            favorites = lib.favorites
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(LibraryData(history: history, favorites: favorites)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: 播放进度 / 历史

    func progress(dramaId: Int) -> PlayRecord? {
        history.first { $0.dramaId == dramaId }
    }

    func upsertProgress(dramaId: Int, title: String, cover: String,
                        epNum: Int, epVideoId: String,
                        position: Double, duration: Double) {
        history.removeAll { $0.dramaId == dramaId }
        let rec = PlayRecord(dramaId: dramaId, title: title, cover: cover,
                             epNum: epNum, epVideoId: epVideoId,
                             position: max(0, position), duration: max(0, duration),
                             updatedAt: Date())
        history.insert(rec, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        save()
    }

    func removeHistory(dramaId: Int) {
        history.removeAll { $0.dramaId == dramaId }
        save()
    }

    func clearHistory() {
        history = []
        save()
    }

    // MARK: 收藏

    func isFavorite(_ dramaId: Int) -> Bool {
        favorites.contains { $0.dramaId == dramaId }
    }

    @discardableResult
    func toggleFavorite(dramaId: Int, title: String, cover: String,
                        totalEpisodes: Int, isFinished: Bool) -> Bool {
        if let idx = favorites.firstIndex(where: { $0.dramaId == dramaId }) {
            favorites.remove(at: idx)
            save()
            return false
        }
        let item = FavoriteItem(dramaId: dramaId, title: title, cover: cover,
                                totalEpisodes: totalEpisodes, isFinished: isFinished,
                                addedAt: Date())
        favorites.insert(item, at: 0)
        save()
        return true
    }
}
