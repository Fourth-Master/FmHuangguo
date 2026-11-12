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
        let t0 = CFAbsoluteTimeGetCurrent()
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badStatus(-1) }
        guard http.statusCode == 200 else {
            DebugLogger.shared.log("API失败 \(path) HTTP=\(http.statusCode)")
            throw APIError.badStatus(http.statusCode)
        }
        DebugLogger.shared.log("API \(path) \(query.isEmpty ? "" : "?" + query.map { "\($0.key)=\($0.value)" }.joined(separator: "&")) \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(data.count)B")
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

    // MARK: 热门标签内容（/api/videos/tag/{标签名}?page=&size=&sort=）

    func tagList(tag: String, page: Int, size: Int = 21, sort: String?) async throws -> (items: [DramaSummary], pagination: Pagination?) {
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        var q: [String: String] = ["page": String(page), "size": String(size)]
        if let sort = sort, !sort.isEmpty { q["sort"] = sort }
        let resp: APIResponse<ListData> = try await request("/api/videos/tag/\(encoded)", query: q)
        guard resp.status == 1, let d = resp.data else { throw APIError.emptyData }
        return (d.items ?? [], d.pagination)
    }

    // MARK: 热门标签（/api/search/tags/hot?type=video）

    func hotTags() async throws -> [String] {
        let resp: APIResponse<HotTagsData> = try await request("/api/search/tags/hot", query: ["type": "video"])
        guard resp.status == 1, let d = resp.data else { return [] }
        return (d.items ?? []).map(\.name)
    }

    struct HotTagItem: Decodable {
        let name: String
        let heat: Int?
    }

    struct HotTagsData: Decodable {
        let items: [HotTagItem]?
    }

    // MARK: 详情

    func detail(id: Int) async throws -> DramaDetail {
        let resp: APIResponse<DramaDetail> = try await request("/api/videos/\(id)")
        guard resp.status == 1, let d = resp.data else { throw APIError.emptyData }
        return d
    }

    // MARK: 播放地址（POST /playback 新接口，旧 /play 已废弃返回空）

    struct PlaybackCDN: Decodable {
        let m3u8Enabled: Bool?
        let otherEnabled: Bool?
        let authKey: String?
        let authValue: String?
        let app: String?
    }

    struct PlaybackData: Decodable {
        let streams: PlaybackStreams?
        let cdn: PlaybackCDN?
        let ep: Int?
        enum CodingKeys: String, CodingKey {
            case streams, cdn, ep
        }
    }

    struct PlaybackStreams: Decodable {
        let main: String?
        let hevc: String?
    }

    struct PlaybackResponse: Decodable {
        let status: Int?
        let msg: String?
        let data: PlaybackData?
    }

    /// 按剧集取播放地址：POST /api/videos/{剧id}/episodes/{集数}/playback
    /// 注意 URL 里是剧的 id（dramaId），不是每集的 videoId；集号用 ep 区分
    func playback(dramaId: Int, ep: Int) async throws -> (url: String, cdn: PlaybackCDN?) {
        var req = URLRequest(url: URL(string: base + "/api/videos/\(dramaId)/episodes/\(ep)/playback")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.setValue(RouteService.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        let t0 = CFAbsoluteTimeGetCurrent()
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(PlaybackResponse.self, from: data)
        guard decoded.status == 1, let d = decoded.data,
              let url = d.streams?.main, !url.isEmpty else {
            DebugLogger.shared.log("playback 失败 dramaId=\(dramaId) ep=\(ep) status=\(decoded.status ?? -1) msg=\(decoded.msg ?? "") body=\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            throw APIError.noPlayURL
        }
        DebugLogger.shared.log("playback OK dramaId=\(dramaId) ep=\(ep) \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms url=\(String(url.prefix(110)))")
        return (url, d.cdn)
    }

    /// CDN 鉴权请求头（x-cdn-auth / x-cdn-app，m3u8 与 ts/key 分片都要带）
    func cdnHeaders(_ cdn: PlaybackCDN?) -> [String: String] {
        guard let c = cdn, let key = c.authKey, let val = c.authValue, !key.isEmpty, !val.isEmpty else {
            return [:]
        }
        var h = [key: val]
        if let app = c.app, !app.isEmpty { h["x-cdn-app"] = app }
        return h
    }
}
