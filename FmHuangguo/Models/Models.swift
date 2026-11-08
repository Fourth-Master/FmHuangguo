import Foundation

// MARK: - API 通用响应

struct APIResponse<T: Decodable>: Decodable {
    let status: Int?
    let msg: String?
    let data: T?
}

struct Pagination: Decodable {
    let page: Int?
    let pages: Int?
    let size: Int?
    let total: Int?
}

// MARK: - 剧集列表条目

struct DramaSummary: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let cover: String?
    let description: String?
    let score: Double?
    let episodeCount: Int?
    let totalEpisodes: Int?
    let isFinished: Bool?
    let tags: [String]?
    let hot: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, cover, description, score, tags, hot
        case episodeCount = "episode_count"
        case totalEpisodes = "total_episodes"
        case isFinished = "is_finished"
    }

    var episodeLabel: String {
        if isFinished == true { return "全\(totalEpisodes ?? episodeCount ?? 0)集" }
        if let c = episodeCount, c > 0 { return "更新至\(c)集" }
        if let c = totalEpisodes, c > 0 { return "全\(c)集" }
        return ""
    }

    var hotLabel: String {
        guard let h = hot, h > 0 else { return "" }
        if h >= 100_000_000 { return String(format: "%.1f亿", Double(h) / 100_000_000) }
        if h >= 10_000 { return String(format: "%.1f万", Double(h) / 10_000) }
        return "\(h)"
    }
}

// MARK: - 详情 / 剧集

struct Episode: Identifiable, Hashable {
    var id: Int { epNum }
    let epNum: Int
    let videoId: String
    let title: String
    let duration: Int
}

struct TrackEpisode: Decodable {
    let videoId: String?
    let episode: Int?
    let duration: Int?
    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case episode
        case duration
    }
}

struct EpisodeMeta: Decodable {
    let epNum: Int?
    let title: String?
    let duration: Int?
    enum CodingKeys: String, CodingKey {
        case epNum = "ep_num"
        case title
        case duration
    }
}

struct DramaDetail: Decodable, Identifiable {
    let id: Int
    let title: String
    let cover: String?
    let description: String?
    let score: Double?
    let tags: [String]?
    let episodeCount: Int?
    let totalEpisodes: Int?
    let isFinished: Bool?
    let episodes: [EpisodeMeta]?
    let trackingEpisodes: [String: TrackEpisode]?
    let firstPlayUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, title, cover, description, score, tags, episodes
        case trackingEpisodes = "tracking_episodes"
        case firstPlayUrl = "video_url"
        case episodeCount = "episode_count"
        case totalEpisodes = "total_episodes"
        case isFinished = "is_finished"
    }

    /// 合并 episodes（标题/时长）与 tracking_episodes（每集 video_id）
    var episodeList: [Episode] {
        var out: [Episode] = []
        if let tracks = trackingEpisodes, !tracks.isEmpty {
            var entries: [(Int, TrackEpisode)] = []
            for (key, val) in tracks {
                let n = Int(key) ?? val.episode
                if let n = n { entries.append((n, val)) }
            }
            entries.sort { $0.0 < $1.0 }
            let metas = episodes ?? []
            for (n, t) in entries {
                let meta = metas.first { $0.epNum == n }
                out.append(Episode(epNum: n,
                                   videoId: t.videoId ?? "",
                                   title: meta?.title ?? "第\(n)集",
                                   duration: meta?.duration ?? t.duration ?? 0))
            }
        } else if let metas = episodes {
            for m in metas {
                guard let n = m.epNum else { continue }
                out.append(Episode(epNum: n, videoId: "", title: m.title ?? "第\(n)集", duration: m.duration ?? 0))
            }
        }
        return out.sorted { $0.epNum < $1.epNum }
    }
}

// MARK: - 播放地址

struct PlayInfo: Decodable {
    let videoUrl: String?
    let hevcUrl: String?
    let duration: Int?
    let title: String?
    let epNum: Int?
    enum CodingKeys: String, CodingKey {
        case videoUrl = "video_url"
        case hevcUrl = "video_url_hevc"
        case duration
        case title
        case epNum = "ep_num"
    }
}
