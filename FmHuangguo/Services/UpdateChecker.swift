import Foundation

// MARK: - 更新检测：每天首次启动后台跑一遍历史+收藏，结果写回 LibraryStore

enum UpdateChecker {
    private static let dayKey = "update_check_day"

    /// 启动时调用：当天未检测过才执行（静默，逐条限速避免打爆站点）
    static func checkIfNeeded(lib: LibraryStore) async {
        let today = todayString()
        guard UserDefaults.standard.string(forKey: dayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: dayKey)
        DebugLogger.shared.log("每日更新检测开始")

        await checkHistory(lib: lib)
        await checkFavorites(lib: lib)
        DebugLogger.shared.log("每日更新检测完成")
    }

    private static func checkHistory(lib: LibraryStore) async {
        let records = lib.history
        for rec in records {
            // 只查有基准集数的（真正看过的）；与缓存一致则跳过
            guard rec.seenTotalEpisodes > 0 else { continue }
            if let cached = lib.cachedTotal(dramaId: rec.dramaId), cached == rec.seenTotalEpisodes {
                continue
            }
            if let total = await fetchTotal(dramaId: rec.dramaId) {
                await MainActor.run {
                    lib.applyFreshTotal(dramaId: rec.dramaId, total: total)
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func checkFavorites(lib: LibraryStore) async {
        let favorites = lib.favorites
        for fav in favorites {
            guard !fav.isFinished else { continue }
            if let cached = lib.cachedTotal(dramaId: fav.dramaId), cached > fav.markedTotalEpisodes {
                continue // 已知有更新，无需再查
            }
            if let total = await fetchTotal(dramaId: fav.dramaId) {
                await MainActor.run {
                    lib.applyFreshTotal(dramaId: fav.dramaId, total: total)
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func fetchTotal(dramaId: Int) async -> Int? {
        do {
            let d = try await SiteAPI.shared.detail(id: dramaId)
            let total = d.totalEpisodes ?? d.episodeCount ?? 0
            return total > 0 ? total : nil
        } catch {
            DebugLogger.shared.log("更新检测失败 id=\(dramaId): \(error.localizedDescription)")
            return nil
        }
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
