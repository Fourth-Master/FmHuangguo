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
    /// 已播放时站点显示的总集数（用于检测"已更新至X集"）
    var seenTotalEpisodes: Int
}

struct FavoriteItem: Codable, Identifiable {
    var id: Int { dramaId }
    let dramaId: Int
    var title: String
    var cover: String
    var totalEpisodes: Int
    var isFinished: Bool
    var addedAt: Date
    /// 收藏时站点显示的总集数（用于检测更新）
    var markedTotalEpisodes: Int
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
                             updatedAt: Date(), seenTotalEpisodes: 0)
        history.insert(rec, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        save()
    }

    /// 播放/进入详情时记录当时的总集数（作为更新检测基准）
    func markSeenEpisodeCount(dramaId: Int, totalEpisodes: Int) {
        guard let idx = history.firstIndex(where: { $0.dramaId == dramaId }) else { return }
        if history[idx].seenTotalEpisodes != totalEpisodes {
            history[idx].seenTotalEpisodes = totalEpisodes
            save()
        }
    }

    /// 历史条目是否有更新：基准集数 > 0 且当前集数更大
    func historyHasUpdate(_ rec: PlayRecord, currentTotal: Int) -> Bool {
        rec.seenTotalEpisodes > 0 && currentTotal > rec.seenTotalEpisodes
    }

    /// 收藏条目是否有更新
    func favoriteHasUpdate(_ fav: FavoriteItem, currentTotal: Int) -> Bool {
        fav.markedTotalEpisodes > 0 && currentTotal > fav.markedTotalEpisodes
    }

    /// 进入详情后清除更新标记：历史与收藏基准同步刷成当前集数（一方清除即双方清除）
    func clearUpdateBadge(dramaId: Int, currentTotalEpisodes: Int) {
        var changed = false
        if let idx = history.firstIndex(where: { $0.dramaId == dramaId }),
           history[idx].seenTotalEpisodes != currentTotalEpisodes {
            history[idx].seenTotalEpisodes = currentTotalEpisodes
            changed = true
        }
        if let idx = favorites.firstIndex(where: { $0.dramaId == dramaId }),
           favorites[idx].markedTotalEpisodes != currentTotalEpisodes {
            favorites[idx].markedTotalEpisodes = currentTotalEpisodes
            changed = true
        }
        if changed { save() }
    }

    // MARK: 更新检测缓存（每日启动检测 / 页面刷新共用）

    /// 各剧集最新总集数（dramaId -> total），由每日检测与页面刷新共同维护
    @Published private(set) var freshTotals: [Int: Int] = [:]

    func cachedTotal(dramaId: Int) -> Int? {
        freshTotals[dramaId]
    }

    /// 写入最新总集数（检测结果）
    func applyFreshTotal(dramaId: Int, total: Int) {
        guard total > 0 else { return }
        freshTotals[dramaId] = total
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
                                addedAt: Date(), markedTotalEpisodes: totalEpisodes)
        favorites.insert(item, at: 0)
        save()
        return true
    }
}
