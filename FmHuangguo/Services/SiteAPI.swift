import Foundation

// MARK: - API 错误

enum APIError: LocalizedError {
    case badURL
    case badStatus(Int)
    case emptyData
    case noPlayURL

    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的线路地址"
        case .badStatus(let code): return "服务返回错误 (\(code))"
        case .emptyData: return "没有获取到数据"
        case .noPlayURL: return "未解析到可播放的视频地址"
        }
    }
}

// MARK: - 站点 API（跟随当前线路）

final class SiteAPI {
    static let shared = SiteAPI()

    /// 当前线路域名（无尾部斜杠），由 AppState.select 设置
    var base: String {
        get { storage ?? UserDefaults.standard.string(forKey: "last_route_url") ?? "https://huangguoai.com" }
        set {
            var v = newValue
            while v.hasSuffix("/") { v = String(v.dropLast()) }
            storage = v
            UserDefaults.standard.set(v, forKey: "last_route_url")
        }
    }
    private var storage: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: 通用请求

    private func request<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard var comps = URLComponents(string: base + path) else { throw APIError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.setValue(RouteService.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badStatus(-1) }
        guard http.statusCode == 200 else { throw APIError.badStatus(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: 列表（综合 / 分类 / 搜索）

    struct ListData: Decodable {
        let items: [DramaSummary]?
        let pagination: Pagination?
    }

    /// category 为空 → 综合列表；kw 非空 → 走真正的搜索接口 /api/search
    func list(category: String?, kw: String?, sort: String?, page: Int, size: Int = 21) async throws -> (items: [DramaSummary], pagination: Pagination?) {
        if let kw = kw, !kw.isEmpty {
            return try await search(kw: kw, page: page, size: size)
        }
        let path: String
        var q: [String: String] = ["page": String(page), "size": String(size)]
        if let category = category, !category.isEmpty {
            path = "/api/videos/category/\(category)"
        } else {
            path = "/api/videos"
        }
        if let sort = sort, !sort.isEmpty { q["sort"] = sort }
        let resp: APIResponse<ListData> = try await request(path, query: q)
        guard resp.status == 1, let d = resp.data else { throw APIError.emptyData }
        return (d.items ?? [], d.pagination)
    }

    // MARK: 搜索（/api/search?q=&type=video&page=）

    private func search(kw: String, page: Int, size: Int) async throws -> (items: [DramaSummary], pagination: Pagination?) {
        let resp: APIResponse<ListData> = try await request("/api/search",
                                                            query: ["q": kw, "type": "video", "page": String(page)])
        guard resp.status == 1, let d = resp.data else { throw APIError.emptyData }
        return (d.items ?? [], d.pagination)
    }

    // MARK: 详情

    func detail(id: Int) async throws -> DramaDetail {
        let resp: APIResponse<DramaDetail> = try await request("/api/videos/\(id)")
        guard resp.status == 1, let d = resp.data else { throw APIError.emptyData }
        return d
    }

    // MARK: 播放地址（每次实时获取，auth_key 有时效）

    func play(videoId: String) async throws -> PlayInfo {
        guard !videoId.isEmpty else { throw APIError.noPlayURL }
        let resp: APIResponse<PlayInfo> = try await request("/api/videos/\(videoId)/play")
        guard resp.status == 1, let d = resp.data, let url = d.videoUrl, !url.isEmpty else {
            throw APIError.noPlayURL
        }
        return d
    }
}
