import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Libmpv

// MARK: - FFmpeg(mpv) 内核播放器视图模型
//
// 集成方式照 MPVKit Demo：CAMetalLayer 通过 wid 交给 mpv，
// vo=gpu-next + gpu-context=moltenvk 由 mpv 内部渲染（无需手写渲染循环）。
// mpv 的 speed 属性自带 scaletempo2 音频同步——高倍速与恢复后音画不失步。

final class MPVPlayerViewModel: NSObject, ObservableObject {
    var mpv: OpaquePointer!
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

    let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private var timeTimer: Timer?
    private var lastSaveAt = Date.distantPast
    private var pendingResume: Double?
    private var pendingURL: URL?
    private var mpvReady = false
    private var eventsQueue = DispatchQueue(label: "fmhuangguo.mpv.events", qos: .userInitiated)

    init(detail: DramaDetail, epNum: Int) {
        self.detail = detail
        let eps = detail.episodeList
        let ep = eps.first { $0.epNum == epNum } ?? eps.first
            ?? Episode(epNum: 1, videoId: "", title: "第1集", duration: 0)
        self.episode = ep
        super.init()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 0.5s 轮询进度/状态（属性读取线程安全）
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    deinit {
        timeTimer?.invalidate()
        if let mpv = mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: 视图挂载后初始化 mpv（wid 需要已就绪的 CAMetalLayer）

    func attachMetalLayer(_ layer: CAMetalLayer) {
        guard mpv == nil else { return }
        DebugLogger.shared.log("mpv: 开始创建内核")

        mpv = mpv_create()
        guard mpv != nil else {
            DebugLogger.shared.log("mpv: mpv_create 失败")
            error = "mpv 内核创建失败"
            return
        }
        DebugLogger.shared.log("mpv: mpv_create OK")

        mpv_set_option_string(mpv, "vo", "gpu-next")
        mpv_set_option_string(mpv, "gpu-api", "vulkan")
        mpv_set_option_string(mpv, "gpu-context", "moltenvk")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "video-rotate", "no")
        var metalLayer: CAMetalLayer = layer
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer)
        mpv_request_log_messages(mpv, "warn")

        let initStatus = mpv_initialize(mpv)
        guard initStatus >= 0 else {
            DebugLogger.shared.log("mpv: mpv_initialize 失败 \(initStatus)")
            error = "mpv 内核初始化失败"
            return
        }
        DebugLogger.shared.log("mpv: mpv_initialize OK")

        // 唤醒回调：读属性变化事件（paused-for-cache / END_FILE）
        mpv_set_wakeup_callback(mpv, { ctx in
            let vm = unsafeBitCast(ctx, to: MPVPlayerViewModel.self)
            vm.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        mpvReady = true
        DebugLogger.shared.log("mpv: 内核就绪")
        // 视图先于 onAppear 挂载时，补发挂起的加载
        if let url = pendingURL {
            issueLoad(url: url, headers: lastCdnHeaders, resume: pendingResume)
        }
    }

    // MARK: 加载

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

            // 优先本地缓存：已缓存直接离线播放（本地文件无需请求头）
            if let local = VideoCacheManager.shared.localM3U8URL(dramaId: detail.id, epNum: ep.epNum) {
                DebugLogger.shared.log("离线播放(mpv) ep=\(ep.epNum) \(local.lastPathComponent)")
                await MainActor.run {
                    self.lastLoadedURL = local.absoluteString
                    self.issueLoad(url: local, headers: [:], resume: resume)
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
                DebugLogger.shared.log("播放(mpv) ep=\(ep.epNum) url=\(String(urlStr.prefix(110)))")
            }
            await MainActor.run { self.lastLoadedURL = urlStr }
            guard let url = URL(string: urlStr) else { throw APIError.noPlayURL }

            await MainActor.run {
                self.issueLoad(url: url, headers: headers, resume: resume)
            }
        } catch {
            DebugLogger.shared.log("播放失败 ep=\(ep.epNum): \(error.localizedDescription)")
            await MainActor.run { self.error = error.localizedDescription }
        }
    }

    /// 通过 loadfile 命令装载（请求头走 loadfile 的每文件选项）
    private func issueLoad(url: URL, headers: [String: String], resume: Double?) {
        pendingURL = url
        pendingResume = resume
        guard mpvReady, mpv != nil else {
            DebugLogger.shared.log("mpv 未就绪，挂起加载 ep=\(episode.epNum)")
            return
        }
        var args = [url.absoluteString, "replace"]
        if !headers.isEmpty {
            let headerStr = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            args.append("http-header-fields=\(headerStr)")
        }
        command("loadfile", args: args)
        if let r = resume, r > 10 {
            // 缓冲后 seek 到续播点
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.mpv != nil else { return }
                self.setDouble("time-pos", r)
                DebugLogger.shared.log("mpv 续播 seek=\(r)")
            }
        }
        setSpeed(speed)
        DebugLogger.shared.log("mpv loadfile 完成 ep=\(episode.epNum) resume=\(resume ?? 0)")
    }

    private func startPlayback() {}

    // MARK: 剧集切换

    var nextEpisode: Episode? { detail.episodeList.first { $0.epNum > episode.epNum } }
    var prevEpisode: Episode? { detail.episodeList.last { $0.epNum < episode.epNum } }

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

    func togglePlay() {
        let paused = getFlag("pause")
        setFlag("pause", !paused)
        if paused {
            // 恢复播放时重申倍速（mpv 恢复后 speed 属性会保持，这里兜底）
            setDouble("speed", Double(speed))
        } else {
            saveProgress()
        }
    }

    func seek(to t: Double) {
        let target = max(0, min(duration, t))
        current = target
        command("seek", args: [String(target), "absolute"])
        saveProgress()
    }

    func setSpeed(_ s: Float) {
        speed = s
        setDouble("speed", Double(s))
    }

    func setDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data: Int64 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
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

    /// 退出播放器：终止 mpv（音频会话随内核销毁，返回后绝无后台播放）
    func stopPlayback() {
        guard mpv != nil else { return }
        saveProgress()
        DebugLogger.shared.log("stopPlayback ep=\(episode.epNum)")
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
        mpv = nil
        mpvReady = false
        playing = false
        buffering = false
    }

    // MARK: 内部

    private func tick() {
        guard mpv != nil, mpvReady else { return }
        let t = getDouble("time-pos")
        if t.isFinite, t > 0 { current = t }
        let d = getDouble("duration")
        if d.isFinite, d > 0 { duration = d }
        playing = !getFlag("pause") && !buffering
        if Date().timeIntervalSince(lastSaveAt) >= 5 {
            saveProgress()
            lastSaveAt = Date()
        }
    }

    // MARK: mpv 事件（wakeup 回调驱动）

    private func readEvents() {
        eventsQueue.async { [weak self] in
            guard let self = self, let mpv = self.mpv else { return }
            while self.mpv != nil {
                let event = mpv_wait_event(mpv, 0)
                let eventId = event!.pointee.event_id
                if eventId == MPV_EVENT_NONE { break }

                switch eventId {
                case MPV_EVENT_PROPERTY_CHANGE:
                    let propPtr = OpaquePointer(event!.pointee.data)
                    if let prop = UnsafePointer<mpv_event_property>(propPtr)?.pointee {
                        let name = String(cString: prop.name)
                        if name == "paused-for-cache" {
                            let buffering = UnsafePointer<Bool>(OpaquePointer(prop.data))?.pointee ?? false
                            DispatchQueue.main.async {
                                self.buffering = buffering
                                self.everPlayed = self.everPlayed || !buffering
                            }
                        }
                    }
                case MPV_EVENT_END_FILE:
                    // reason == 0 (EOF) 才算自然播完
                    if let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(event!.pointee.data))?.pointee,
                       endFile.reason.rawValue == 0 {
                        DispatchQueue.main.async { self.playFinished() }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
        }
    }

    // MARK: 命令封装

    func command(_ command: String, args: [String] = []) {
        guard mpv != nil else { return }
        var cargs: [UnsafePointer<CChar>?] = ([command] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        mpv_command(mpv, &cargs)
        for ptr in cargs where ptr != nil {
            free(UnsafeMutablePointer(mutating: ptr))
        }
    }
}

// MARK: - Metal 视图容器（CAMetalLayer 提供给 mpv 的 wid）

final class MPVMetalContainerView: UIView {
    let metalLayer: MetalLayer
    var onLayerReady: ((CAMetalLayer) -> Void)?

    override init(frame: CGRect) {
        metalLayer = MetalLayer()
        super.init(frame: frame)
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onLayerReady?(metalLayer)
        }
    }
}

/// MoltenVK 会把 drawableSize 置 1x1 强制完成呈现，导致闪烁/停留 1x1
/// https://github.com/mpv-player/mpv/pull/13651
final class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
