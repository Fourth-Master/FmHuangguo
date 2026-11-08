import Foundation

// MARK: - 线路候选

struct RouteCandidate: Identifiable, Hashable {
    var id: String { url }
    let name: String
    let url: String
    var latencyMs: Int?
    var tested: Bool

    init(name: String, url: String, latencyMs: Int? = nil, tested: Bool = false) {
        self.name = name
        self.url = url
        self.latencyMs = latencyMs
        self.tested = tested
    }

    var ok: Bool { latencyMs != nil }
    var host: String { URL(string: url)?.host ?? url }
}

// MARK: - 线路发现 + 测速

final class RouteService {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 14
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: 发现候选线路（hgai2.com 三条线路 + pages.dev 最新地址 + 永久域名兜底）

    static func discoverCandidates() async -> [RouteCandidate] {
        async let fromHgai2 = fetchHgai2Lines()
        async let fromPages = fetchPagesLatest()
        var list = await fromHgai2 + fromPages
        if list.isEmpty { list = fallbackCandidates() }

        var seen = Set<String>()
        var out: [RouteCandidate] = []
        for c in list where !seen.contains(c.url) {
            seen.insert(c.url)
            out.append(c)
        }
        return out
    }

    static func fallbackCandidates() -> [RouteCandidate] {
        var list: [RouteCandidate] = []
        let forever = ["https://huangguoai.com", "https://huangguoai.ai"]
        for (i, u) in forever.enumerated() {
            list.append(RouteCandidate(name: "永久域名 \(i + 1)", url: u))
        }
        return list
    }

    /// hgai2.com 地址发布页：<article class="route-card ..." data-url="https://xxx">
    private static func fetchHgai2Lines() async -> [RouteCandidate] {
        guard let html = await getString("https://hgai2.com/") else { return [] }
        let urls = matches(in: html, pattern: #"data-url="(https?://[^"]+)""#)
        return urls.prefix(4).enumerated().map { i, u in
            RouteCandidate(name: String(format: "线路 %02d", i + 1), url: normalize(u))
        }
    }

    /// pages.dev 发布页：解析 publish.js 中的 urls=[...] 与 foreverUrls=[...]
    private static func fetchPagesLatest() async -> [RouteCandidate] {
        guard let html = await getString("https://huangguoai.pages.dev/") else { return [] }
        guard let jsPath = matches(in: html, pattern: #"(?:https?:)?//[^"'\s]*publish\.js[^"'\s]*|/publish\.js[^"'\s]*"#).first else { return [] }
        var jsURL = jsPath
        if jsURL.hasPrefix("//") { jsURL = "https:" + jsURL }
        else if jsURL.hasPrefix("/") { jsURL = "https://huangguoai.pages.dev" + jsURL }
        else if !jsURL.hasPrefix("http") { jsURL = "https://huangguoai.pages.dev/" + jsURL }

        guard let js = await getString(jsURL) else { return [] }

        var out: [RouteCandidate] = []
        // 最新地址（可能多个域名，每个域名再带优选子域变体）
        let latestDomains = arrayStrings(js, variable: "urls").prefix(3)
        for (i, raw) in latestDomains.enumerated() {
            let d = stripDomain(raw)
            guard !d.isEmpty else { continue }
            let label = latestDomains.count > 1 ? "最新地址 \(i + 1)" : "最新地址"
            out.append(RouteCandidate(name: label, url: "https://\(d)"))
            for sub in ["thu", "pku"] {
                out.append(RouteCandidate(name: "最新地址·优选", url: "https://\(sub).\(d)"))
            }
        }
        // 永久域名
        for (i, raw) in arrayStrings(js, variable: "foreverUrls").prefix(3).enumerated() {
            let d = stripDomain(raw)
            guard !d.isEmpty else { continue }
            out.append(RouteCandidate(name: "永久域名 \(i + 1)", url: "https://\(d)"))
        }
        return out
    }

    // MARK: 测速：请求一次真实 API，验证可用性并计时

    static func probe(_ c: RouteCandidate) async -> RouteCandidate {
        var r = c
        r.tested = true
        guard let u = URL(string: c.url + "/api/videos/category/ai-duanju?size=1") else { return r }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let body = String(data: data.prefix(2048), encoding: .utf8),
               body.contains("\"items\"") {
                r.latencyMs = ms
            }
        } catch {
            // 保持 failed
        }
        return r
    }

    static func testAll(_ candidates: [RouteCandidate]) async -> [RouteCandidate] {
        let results = await withTaskGroup(of: RouteCandidate.self) { group -> [RouteCandidate] in
            for c in candidates {
                group.addTask { await RouteService.probe(c) }
            }
            var out: [RouteCandidate] = []
            for await r in group { out.append(r) }
            return out
        }
        return results.sorted { a, b in
            switch (a.ok, b.ok) {
            case (true, true): return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
            case (true, false): return true
            case (false, true): return false
            default: return a.name < b.name
            }
        }
    }

    // MARK: - 工具

    private static func getString(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 返回正则第 1 捕获组全部匹配
    static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        let results = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return results.compactMap { m -> String? in
            guard m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }

    /// 从 JS 片段提取 variable = [ ... ] 里的字符串
    private static func arrayStrings(_ js: String, variable: String) -> [String] {
        let block = matches(in: js, pattern: variable + #"\s*=\s*\[([^\]]*)\]"#).first ?? ""
        return matches(in: block, pattern: #""([^"]+)""#) + matches(in: block, pattern: #"'([^']+)'"#)
    }

    private static func stripDomain(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.hasPrefix("http://") { d = String(d.dropFirst(7)) }
        else if d.hasPrefix("https://") { d = String(d.dropFirst(8)) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        return d.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }

    private static func normalize(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.hasPrefix("http") { u = "https://" + u }
        while u.hasSuffix("/") { u = String(u.dropLast()) }
        return u
    }
}
