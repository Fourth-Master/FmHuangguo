import Foundation

// MARK: - 全局应用状态：线路测速 → 选择最快 → 进入主界面

enum AppPhase {
    case boot      // 未开始
    case routing   // 获取候选 + 测速中
    case ready     // 已选定线路，进入主界面
    case failed    // 全部线路不可用
}

final class AppState: ObservableObject {
    @Published private(set) var phase: AppPhase = .boot
    @Published private(set) var routes: [RouteCandidate] = []
    @Published private(set) var current: RouteCandidate?

    private static let dayKey = "route_day"
    private static let dayRouteUrlKey = "route_day_url"
    private static let dayRouteLatencyKey = "route_day_latency"

    /// 启动流程：当天首次启动才测速选线，其余直接复用当天缓存线路（秒进主界面）
    func startRouting(force: Bool = false) async {
        await MainActor.run { phase = .routing }

        let today = Self.todayString()
        let savedDay = UserDefaults.standard.string(forKey: Self.dayKey)
        let savedURL = UserDefaults.standard.string(forKey: Self.dayRouteUrlKey)

        // 当天已测过且缓存线路可用：直接使用，跳过测速（设置页 force=true 强制完整测速）
        if !force, savedDay == today, let url = savedURL, !url.isEmpty {
            let route = RouteCandidate(name: "今日优选", url: url,
                                       latencyMs: UserDefaults.standard.integer(forKey: Self.dayRouteLatencyKey))
            // 后台快速校验该线路仍可用（失败则回退完整测速）
            let probed = await RouteService.probe(route)
            if probed.ok {
                DebugLogger.shared.log("复用今日线路 \(url) (\(probed.latencyMs ?? 0)ms)")
                await MainActor.run {
                    routes = [probed]
                    select(probed)
                }
                return
            }
            DebugLogger.shared.log("今日线路 \(url) 已失效，重新测速")
        }

        await fullRouting(today: today)
    }

    /// 完整流程：发现候选线路 → 并发测速 → 自动选最快并缓存当天结果
    private func fullRouting(today: String) async {
        var candidates = await RouteService.discoverCandidates()
        if candidates.isEmpty { candidates = RouteService.fallbackCandidates() }
        await MainActor.run { routes = candidates }
        DebugLogger.shared.log("线路候选 \(candidates.count) 条: \(candidates.map { "\($0.name)=\($0.host)" }.joined(separator: " | "))")

        let tested = await RouteService.testAll(candidates)
        DebugLogger.shared.log("测速完成: " + tested.map { "\($0.name)=\($0.ok ? "\($0.latencyMs!)ms" : "fail")" }.joined(separator: " | "))

        await MainActor.run {
            routes = tested
            if let best = tested.first(where: { $0.ok }) {
                select(best)
                // 缓存当天最快线路
                UserDefaults.standard.set(today, forKey: Self.dayKey)
                UserDefaults.standard.set(best.url, forKey: Self.dayRouteUrlKey)
                if let ms = best.latencyMs {
                    UserDefaults.standard.set(ms, forKey: Self.dayRouteLatencyKey)
                }
            } else {
                phase = .failed
            }
        }
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 选择线路（自动选最快 / 设置里手动切换）
    func select(_ route: RouteCandidate) {
        current = route
        SiteAPI.shared.base = route.url
        phase = .ready
    }
}
