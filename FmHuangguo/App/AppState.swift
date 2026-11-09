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

    /// 启动流程：发现候选线路 → 并发测速 → 自动选最快
    func startRouting() async {
        await MainActor.run { phase = .routing }
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
            } else {
                phase = .failed
            }
        }
    }

    /// 选择线路（自动选最快 / 设置里手动切换）
    func select(_ route: RouteCandidate) {
        current = route
        SiteAPI.shared.base = route.url
        phase = .ready
    }
}
