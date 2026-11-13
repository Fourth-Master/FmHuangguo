final class AVPlayerViewModel: NSObject, ObservableObject, PlayerKernel {
    let player = AVPlayer()
    let detail: DramaDetail

    @Published var episode: Episode
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var buffering = false
    @Published var speed: Float = 1.0
    @Published var error: String?
    @Published var controlsVisible = true

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusSub: AnyCancellable?
    private var lastSaveAt = Date.distantPast
    /// seek 锁：锁住期间 tick 不覆盖 UI 时间（带时间戳，超时自动失效防死锁）
    var scrubbingTarget: Double?
    var scrubbingTargetAt: Date = .distantPast
    /// 最近一次加载的播放地址与 CDN 头（供缓存下载复用）
    @Published var lastLoadedURL: String = ""
    @Published var lastCdnHeaders: [String: String] = [:]

    let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(detail: DramaDetail, epNum: Int) {
        self.detail = detail
        let eps = detail.episodeList
        let ep = eps.first { $0.epNum == epNum } ?? eps.first
            ?? Episode(epNum: 1, videoId: "", title: "第1集", duration: 0)
        self.episode = ep

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 时间观察：更新进度 UI + 每 5 秒保存进度
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            DispatchQueue.main.async { self?.tick(time) }
        }

        // 播放结束：自动下一集
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            DispatchQueue.main.async {
                guard let self = self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.playFinished()
            }
        }

        // 播放状态观察
        statusSub = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.playing = (status == .playing)
                self.buffering = (status == .waitingToPlayAtSpecifiedRate)
                if status == .playing { self.everPlayed = true }
            }
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        statusSub?.cancel()
    }

    // MARK: 剧集切换

    var nextEpisode: Episode? { detail.episodeList.first { $0.epNum > episode.epNum } }
    var prevEpisode: Episode? { detail.episodeList.last { $0.epNum < episode.epNum } }

    func load(ep: Episode, resume: Double? = nil) async {
        episode = ep
        error = nil
        current = resume ?? 0
        duration = Double(ep.duration)

        do {
            let urlStr: String
            var headers: [String: String] = [
                "Referer": SiteAPI.shared.base + "/",
                "User-Agent": RouteService.ua,
            ]

            // 优先本地缓存：已缓存直接离线播放
            if let local = VideoCacheManager.shared.localM3U8URL(dramaId: detail.id, epNum: ep.epNum) {
                DebugLogger.shared.log("离线播放 ep=\(ep.epNum) \(local.lastPathComponent)")
                await MainActor.run {
                    let item = AVPlayerItem(url: local)
                    self.player.replaceCurrentItem(with: item)
                    if let r = resume, r > 10 {
                        self.player.seek(to: CMTime(seconds: r, preferredTimescale: 600))
                    }
                    self.player.play()
                    self.applySpeed(self.speed)
                }
                return
            }

            if ep.videoId.isEmpty && ep.epNum == 1, let fu = detail.firstPlayUrl, !fu.isEmpty {
                // 兜底：详情自带的直播地址
                urlStr = fu
                DebugLogger.shared.log("播放(兜底 detail.video_url) ep=\(ep.epNum)")
            } else {
                let pb = try await SiteAPI.shared.playback(dramaId: detail.id, ep: ep.epNum)
                urlStr = pb.url
                // CDN 鉴权头（m3u8/ts/key 都要带）
                for (k, v) in SiteAPI.shared.cdnHeaders(pb.cdn) {
                    headers[k] = v
                }
                // 记住本次 CDN 头（供缓存下载使用）
                await MainActor.run { self.lastCdnHeaders = headers }
                DebugLogger.shared.log("播放 playback ep=\(ep.epNum) videoId=\(ep.videoId) url=\(String(urlStr.prefix(110))) headers=\(SiteAPI.shared.cdnHeaders(pb.cdn).keys.joined(separator: ","))")
            }
            await MainActor.run { self.lastLoadedURL = urlStr }
            guard let url = URL(string: urlStr) else { throw APIError.noPlayURL }

            // AVURLAssetHTTPHeaderFieldsKey：m3u8 及其分片/密钥请求都会带上这些头
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)

            await MainActor.run {
                self.player.replaceCurrentItem(with: item)
                if let r = resume, r > 10 {
                    self.player.seek(to: CMTime(seconds: r, preferredTimescale: 600))
                }
                self.player.play()
                self.applySpeed(self.speed)
            }
            DebugLogger.shared.log("已挂载 AVPlayerItem ep=\(ep.epNum) resume=\(resume ?? 0)")
        } catch {
            DebugLogger.shared.log("播放失败 ep=\(ep.epNum): \(error.localizedDescription)")
            await MainActor.run { self.error = error.localizedDescription }
        }
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

    /// 进入播放器后按起始集加载（含续播逻辑）
    func loadInitial(startEp: Int) {
        let resume = LibraryStore.shared.progress(dramaId: detail.id)
        Task {
            if let ep = detail.episodeList.first(where: { $0.epNum == startEp }) ?? detail.episodeList.first {
                let pos = (resume?.epNum == ep.epNum) ? resume?.position : nil
                await load(ep: ep, resume: (pos ?? 0) > 10 ? pos : nil)
            }
        }
    }

    /// 视频输出视图（AVPlayerLayer 容器）
    func makeVideoUIView() -> UIView {
        AVPlayerContainerView(player: player)
    }

    /// 退出播放器：AVPlayer 暂停（音频会话 playback 下不暂停会后台续播）
    func stopPlayback() {
        player.pause()
        saveProgress()
        DebugLogger.shared.log("stopPlayback(AVPlayer) ep=\(episode.epNum)")
    }

    /// 音量 0~1（AVPlayer.volume 0~1）
    func setVolume(_ normalized: Float) {
        player.volume = max(0, min(1, normalized))
    }

    func currentVolume() -> Float {
        player.volume
    }

    // MARK: 播放控制

    func togglePlay() {
        if playing {
            player.pause()
            saveProgress()
        } else {
            player.play()
            applySpeed(speed)
        }
    }

    func seek(to t: Double) {
        let target = max(0, min(duration, t))
        current = target
        // seek 锁（带超时防死锁）：锁住期间 tick 不覆盖 UI 时间
        scrubbingTarget = target
        scrubbingTargetAt = Date()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // seek 完成后以播放器实际时间为准并解锁
                self.current = CMTimeGetSeconds(self.player.currentTime())
                self.scrubbingTarget = nil
            }
        }
        saveProgress()
    }

    func setSpeed(_ s: Float) {
        speed = s
        applySpeed(s)
    }

    private func applySpeed(_ s: Float) {
        if #available(iOS 16.0, *) {
            player.defaultRate = s
        }
        if playing { player.rate = s }
    }

    // MARK: 进度保存

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

    private func tick(_ time: CMTime) {
        let sec = CMTimeGetSeconds(time)
        // seek 锁：锁住期间不覆盖 UI 时间；超过 2 秒视为死锁自动解锁
        let lockExpired = Date().timeIntervalSince(scrubbingTargetAt) > 2.0
        if (scrubbingTarget == nil || lockExpired), sec.isFinite, sec >= 0 {
            current = sec
            if lockExpired { scrubbingTarget = nil }
        }
        if let item = player.currentItem, item.duration.isNumeric {
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite, d > 0 { duration = d }
        }
        if Date().timeIntervalSince(lastSaveAt) >= 5 {
            saveProgress()
            lastSaveAt = Date()
        }
    }
}

// MARK: - AVPlayerLayer 容器

final class AVPlayerContainerView: UIView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
