import Foundation
import SwiftUI
import AVFoundation
import MobileVLCKit

// MARK: - FFmpeg(VLC) 内核播放器视图模型
//
// 替换 AVPlayer 的原因：
// - AVPlayer iOS 15 无 defaultRate，高倍速下缓冲恢复后 rate 回落 1x，造成进度反复横跳
// - VLC(FFmpeg) 的 rate 状态由播放器内部持久保持，缓冲后不回落
// - VLC 原生处理 AES-128 HLS、HTTP 头注入更直接

final class VLCPlayerViewModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    /// VLCMediaPlayer 在 super.init() 后创建（Swift 初始化顺序要求 let 属性
    /// 先于 super.init 赋值，但 VLC 创建需要日志夹在中间，故用 var 一次性赋值）
    private(set) var player: VLCMediaPlayer!
    let detail: DramaDetail

    @Published var episode: Episode
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var buffering = false
    @Published var speed: Float = 1.0
    @Published var error: String?
    @Published var controlsVisible = true
    /// 本集是否已实际开始播放过（控制初始加载转圈的显示）
    @Published var everPlayed = false
    /// 最近一次加载的播放地址与 CDN 头（供缓存下载复用）
    @Published var lastLoadedURL: String = ""
    @Published var lastCdnHeaders: [String: String] = [:]
    /// VLC 无音量读接口，自记录（0~1）
    private var audioVolumeStored: Float = 1.0

    private var timeTimer: Timer?
    private var lastSaveAt = Date.distantPast
    private var pendingResume: Double?
    private var didStartObserving = false

    let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(detail: DramaDetail, epNum: Int) {
        self.detail = detail
        let eps = detail.episodeList
        let ep = eps.first { $0.epNum == epNum } ?? eps.first
            ?? Episode(epNum: 1, videoId: "", title: "第1集", duration: 0)
        self.episode = ep
        super.init()
        DebugLogger.shared.log("VM init: 开始创建 VLC 内核")
        // 显式初始化 VLC 库（保证 libvlc_new 在主线程、早于 player 创建）
        _ = VLCLibrary.shared()
        DebugLogger.shared.log("VM init: VLCLibrary OK")
        player = VLCMediaPlayer(options: [
            "--network-caching=5000",       // 5s 网络缓冲，减少播放中频繁 re-buffer
            "--no-drop-late-frames",
            "--no-skip-frames",
        ])
        DebugLogger.shared.log("VM init: VLCMediaPlayer OK")
        player.delegate = self
        DebugLogger.shared.log("VM init: delegate OK")

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        DebugLogger.shared.log("VM init: audio session OK")

        // 0.5s 轮询进度（VLC 没有 AVPlayer 的 periodic observer）
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        DebugLogger.shared.log("VM init: 完成")
    }

    deinit {
        timeTimer?.invalidate()
        player.stop()
    }

    // MARK: VLC 状态回调

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // VLC 3.x delegate 传 Notification；时间更新由 0.5s Timer tick 覆盖
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async {
            let st = self.player.state
            self.playing = (st == .playing)
            self.buffering = (st == .buffering || st == .opening)
            if st == .playing { self.everPlayed = true }
            switch st {
            case .ended:
                self.playFinished()
            case .error:
                self.error = "FFmpeg 解码播放出错"
                DebugLogger.shared.log("VLC error state ep=\(self.episode.epNum)")
            case .playing:
                // 播放开始后应用挂起的续播
                if let r = self.pendingResume, r > 10 {
                    self.pendingResume = nil
                    self.player.time = VLCTime(int: Int32(r * 1000))
                }
            default:
                break
            }
        }
    }

    // MARK: 剧集切换

    var nextEpisode: Episode? { detail.episodeList.first { $0.epNum > episode.epNum } }
    var prevEpisode: Episode? { detail.episodeList.last { $0.epNum < episode.epNum } }

    func load(ep: Episode, resume: Double? = nil) async {
        episode = ep
        error = nil
        current = resume ?? 0
        duration = Double(ep.duration)
        pendingResume = resume
        everPlayed = false
        DebugLogger.shared.log("load 开始 ep=\(ep.epNum) videoId=\(ep.videoId)")

        do {
            let urlStr: String
            var headers: [String: String] = [
                "Referer": SiteAPI.shared.base + "/",
                "User-Agent": RouteService.ua,
            ]

            // 优先本地缓存：已缓存直接离线播放（本地 m3u8 无需任何头）
            if let local = VideoCacheManager.shared.localM3U8URL(dramaId: detail.id, epNum: ep.epNum) {
                DebugLogger.shared.log("离线播放(FFmpeg) ep=\(ep.epNum) \(local.lastPathComponent)")
                await MainActor.run {
                    self.player.media = VLCMedia(url: local)
                    self.startPlayback()
                }
                return
            }

            if ep.videoId.isEmpty && ep.epNum == 1, let fu = detail.firstPlayUrl, !fu.isEmpty {
                urlStr = fu
                DebugLogger.shared.log("播放(兜底 detail.video_url) ep=\(ep.epNum)")
            } else {
                let pb = try await SiteAPI.shared.playback(dramaId: detail.id, ep: ep.epNum)
                urlStr = pb.url
                for (k, v) in SiteAPI.shared.cdnHeaders(pb.cdn) {
                    headers[k] = v
                }
                await MainActor.run { self.lastCdnHeaders = headers }
                DebugLogger.shared.log("播放(FFmpeg) ep=\(ep.epNum) url=\(String(urlStr.prefix(110)))")
            }
            await MainActor.run { self.lastLoadedURL = urlStr }
            guard let url = URL(string: urlStr) else { throw APIError.noPlayURL }

            let media = VLCMedia(url: url)
            // 请求头注入（m3u8 与分片请求都会带上）：VLC 选项形如 --http-xxx
            var opts: [AnyHashable: Any] = [:]
            for (k, v) in headers {
                opts[":http-\(k.lowercased())"] = v
            }
            media.addOptions(opts)
            await MainActor.run {
                self.player.media = media
                self.startPlayback()
            }
        } catch {
            DebugLogger.shared.log("播放失败 ep=\(ep.epNum): \(error.localizedDescription)")
            await MainActor.run { self.error = error.localizedDescription }
        }
    }

    private func startPlayback() {
        player.play()
        // VLC rate 在 play 之后设置才生效
        if speed != 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.player.rate = Float(self?.speed ?? 1.0)
            }
        }
        DebugLogger.shared.log("FFmpeg 已开始播放 ep=\(episode.epNum) resume=\(pendingResume ?? 0)")
    }

    func playNext() async {
        if let n = nextEpisode { await load(ep: n) }
    }

    func playPrev() async {
        if let p = prevEpisode { await load(ep: p) }
    }

    private func playFinished() {
        saveProgress(reset: true)
        if let n = nextEpisode {
            Task { await self.load(ep: n) }
        } else {
            playing = false
            controlsVisible = true
        }
    }

    // MARK: 播放控制

    /// 音量 0~1（VLC：player.audio.volume 0~256，VLCAudio.volume）
    func setVolume(_ normalized: Float) {
        let v = max(0, min(1, normalized))
        audioVolumeStored = v
        player.audio?.volume = Int32(v * 256.0)
    }

    func currentVolume() -> Float {
        audioVolumeStored
    }

    func togglePlay() {
        if playing {
            player.pause()
            saveProgress()
        } else {
            player.play()
            if speed != 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.player.rate = Float(self?.speed ?? 1.0)
                }
            }
        }
    }

    func seek(to t: Double) {
        let target = max(0, min(duration, t))
        current = target
        player.time = VLCTime(int: Int32(target * 1000))
        saveProgress()
    }

    func setSpeed(_ s: Float) {
        speed = s
        // VLC：播放中直接改 rate 即可，缓冲恢复不会回落
        player.rate = s
    }

    // MARK: 进度保存

    /// 退出播放器：停止播放（否则 VLC 音频会话残留，返回后仍在后台播放）
    func stopPlayback() {
        player.stop()
        DebugLogger.shared.log("stopPlayback ep=\(episode.epNum)")
    }

    func saveProgress(reset: Bool = false) {
        guard duration > 0 else { return }
        LibraryStore.shared.upsertProgress(
            dramaId: detail.id,
            title: detail.title,
            cover: detail.cover ?? "",
            epNum: episode.epNum,
            epVideoId: episode.videoId,
            position: reset ? 0 : current,
            duration: duration
        )
    }

    // MARK: 内部

    private func tick() {
        let t = player.time.intValue
        if t > 0 {
            let sec = Double(t) / 1000.0
            if sec.isFinite, sec >= 0 { current = sec }
        }
        let d = player.media?.length.intValue ?? 0
        if d > 0 {
            let sec = Double(d) / 1000.0
            if sec.isFinite, sec > 0 { duration = sec }
        }
        if Date().timeIntervalSince(lastSaveAt) >= 5 {
            saveProgress()
            lastSaveAt = Date()
        }
    }
}

// MARK: - VLC 视频输出容器

final class VLCPlayerContainerView: UIView {
    var mediaPlayer: VLCMediaPlayer?
}

struct VLCPlayerLayerView: UIViewRepresentable {
    let vm: VLCPlayerViewModel
    let fillMode: Bool

    func makeUIView(context: Context) -> VLCPlayerContainerView {
        let v = VLCPlayerContainerView()
        DebugLogger.shared.log("makeUIView: 挂载 drawable")
        vm.player.drawable = v
        DebugLogger.shared.log("makeUIView: drawable OK")
        v.mediaPlayer = vm.player
        return v
    }

    func updateUIView(_ uiView: VLCPlayerContainerView, context: Context) {
        // fit/fill 由 VLC 默认比例显示处理，属性级 crop 各版本 API 有差异，不直接操作
    }
}
