import Foundation
import AVFoundation

// MARK: - 视频离线缓存（HLS 下载 → 本地 m3u8 + 分片 + 密钥 → 离线播放）
//
// 原理：拉取 m3u8（master/media），把其中的分片 URL 与 AES-128 key 下载到本地，
// 生成本地 m3u8（分片路径改为相对路径），AVPlayer 直接 load 本地文件即可离线播放。
// 密钥 URI 改写为本地 key 文件（AVPlayer 会自动完成 AES-128 解密）。

final class VideoCacheManager: ObservableObject {
    static let shared = VideoCacheManager()

    /// 一部剧缓存一条记录（dramaId -> 集合状态）
    @Published private(set) var cachedEpisodes: [String: CachedEpisodeState] = [:]  // key: "\(dramaId)_\(epNum)"

    struct CachedEpisodeState: Codable {
        var dramaId: Int
        var epNum: Int
        var title: String
        var progress: Double      // 0~1
        var done: Bool
        var localDir: String
        var totalBytes: Int64
    }

    private let session: URLSession
    private var tasks: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    private var baseDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("VideoCache", isDirectory: true)
    }

    private var indexFile: URL {
        baseDir.appendingPathComponent("index.json")
    }

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        loadIndex()
    }

    func isCached(dramaId: Int, epNum: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedEpisodes["\(dramaId)_\(epNum)"]?.done == true
    }

    func state(dramaId: Int, epNum: Int) -> CachedEpisodeState? {
        lock.lock(); defer { lock.unlock() }
        return cachedEpisodes["\(dramaId)_\(epNum)"]
    }

    func localM3U8URL(dramaId: Int, epNum: Int) -> URL? {
        guard let st = state(dramaId: dramaId, epNum: epNum), st.done else { return nil }
        let dir = URL(fileURLWithPath: st.localDir)
        return dir.appendingPathComponent("local.m3u8")
    }

    // MARK: 下载

    func download(dramaId: Int, epNum: Int, title: String, m3u8URL: URL, headers: [String: String]) {
        let key = "\(dramaId)_\(epNum)"
        lock.lock()
        if tasks[key] != nil { lock.unlock(); return }
        lock.unlock()

        let dir = baseDir.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        updateState(key: key) { st in
            st = CachedEpisodeState(dramaId: dramaId, epNum: epNum, title: title,
                                    progress: 0, done: false, localDir: dir.path, totalBytes: 0)
        }

        let task = Task {
            do {
                try await self.fetchAndBuild(m3u8URL: m3u8URL, dir: dir, headers: headers, key: key)
                self.updateState(key: key) { st in
                    st.done = true
                    st.progress = 1
                }
                DebugLogger.shared.log("缓存完成 \(key)")
            } catch {
                DebugLogger.shared.log("缓存失败 \(key): \(error.localizedDescription)")
                self.updateState(key: key) { st in st.progress = -1 } // -1 表示失败
            }
            self.lock.lock()
            self.tasks[key] = nil
            self.lock.unlock()
        }
        lock.lock()
        tasks[key] = task
        lock.unlock()
    }

    func cancel(dramaId: Int, epNum: Int) {
        let key = "\(dramaId)_\(epNum)"
        lock.lock()
        tasks[key]?.cancel()
        tasks[key] = nil
        lock.unlock()
    }

    func delete(dramaId: Int, epNum: Int) {
        let key = "\(dramaId)_\(epNum)"
        cancel(dramaId: dramaId, epNum: epNum)
        lock.lock()
        cachedEpisodes[key] = nil
        let snapshot = cachedEpisodes
        lock.unlock()
        persistIndex(snapshot)
        if let st = state(dramaId: dramaId, epNum: epNum) {
            try? FileManager.default.removeItem(atPath: st.localDir)
        }
        let dir = baseDir.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 核心下载逻辑

    private func fetchAndBuild(m3u8URL: URL, dir: URL, headers: [String: String], key: String) async throws {
        let playlist = try await fetchText(url: m3u8URL, headers: headers)
        var lines = playlist.components(separatedBy: .newlines)
        var segIndex = 0
        var totalSegs = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }.count
        if totalSegs == 0 { totalSegs = 1 }
        var totalBytes: Int64 = 0

        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                // EXT-X-KEY：下载密钥并改写 URI 为本地文件
                if line.contains("EXT-X-KEY"), let uriRange = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                    let uriPart = String(line[uriRange])
                    let remote = String(uriPart[uriPart.index(uriPart.startIndex, offsetBy: 5)..<uriPart.index(before: uriPart.endIndex)])
                    if let keyURL = URL(string: remote, relativeTo: m3u8URL)?.absoluteURL {
                        let keyData = try await fetchData(url: keyURL, headers: headers)
                        let keyName = "key_\(i).bin"
                        try keyData.write(to: dir.appendingPathComponent(keyName), options: .atomic)
                        totalBytes += Int64(keyData.count)
                        lines[i] = line.replacingOccurrences(of: uriPart, with: #"URI="\#(keyName)""#)
                    }
                }
                continue
            }
            // 分片行
            if let segURL = URL(string: line, relativeTo: m3u8URL)?.absoluteURL {
                let segName = String(format: "seg_%04d.ts", segIndex)
                let data = try await fetchData(url: segURL, headers: headers)
                try data.write(to: dir.appendingPathComponent(segName), options: .atomic)
                totalBytes += Int64(data.count)
                lines[i] = segName
                segIndex += 1
                let p = Double(segIndex) / Double(max(totalSegs, 1))
                updateState(key: key) { st in
                    st.progress = min(0.99, p)
                    st.totalBytes = totalBytes
                }
                // 分片请求限速，避免 CDN 429
                try? await Task.sleep(nanoseconds: 60_000_000)
                try Task.checkCancellation()
            }
        }

        let local = lines.joined(separator: "\n")
        try local.write(to: dir.appendingPathComponent("local.m3u8"), atomically: true, encoding: .utf8)
        updateState(key: key) { st in st.totalBytes = totalBytes }
        persistIndex(currentIndexSnapshot())
    }

    // MARK: 工具

    private func fetchText(url: URL, headers: [String: String]) async throws -> String {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fetchData(url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, _) = try await session.data(for: req)
        return data
    }

    private func updateState(key: String, mutate: (inout CachedEpisodeState) -> Void) {
        lock.lock()
        var st = cachedEpisodes[key] ?? CachedEpisodeState(dramaId: 0, epNum: 0, title: "", progress: 0, done: false, localDir: "", totalBytes: 0)
        mutate(&st)
        cachedEpisodes[key] = st
        let snapshot = cachedEpisodes
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        persistIndex(snapshot)
    }

    // MARK: 索引持久化

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile) else { return }
        let dec = JSONDecoder()
        if let idx = try? dec.decode([String: CachedEpisodeState].self, from: data) {
            cachedEpisodes = idx
        }
    }

    private func persistIndex(_ snapshot: [String: CachedEpisodeState]) {
        let enc = JSONEncoder()
        if let data = try? enc.encode(snapshot) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    private func currentIndexSnapshot() -> [String: CachedEpisodeState] {
        lock.lock(); defer { lock.unlock() }
        return cachedEpisodes
    }

    /// 缓存总大小
    func totalSize() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return cachedEpisodes.values.reduce(0) { $0 + $1.totalBytes }
    }
}
