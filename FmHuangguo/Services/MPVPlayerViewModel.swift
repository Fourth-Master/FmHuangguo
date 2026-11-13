import Foundation
import SwiftUI
import UIKit
import AVFoundation
import GLKit
import OpenGLES
import Combine
import Libmpv

// MARK: - FFmpeg(mpv) 内核播放器视图模型（OpenGL ES 渲染）
//
// 渲染方式：vo=libmpv + mpv_render_context（OpenGL/GLES）
// —— 绕开 MoltenVK/Vulkan（该路径在部分设备上创建 swapchain 即崩溃）。
// mpv 的 speed 属性自带 scaletempo2 音频同步——高倍速与恢复后音画不失步。

// mpv 头文件的宏常量不导入 Swift，手动对应
private let kMPVRenderParamAPIType: Int32 = 1              // MPV_RENDER_PARAM_API_TYPE
private let kMPVRenderParamOpenGLInitParams: Int32 = 2     // MPV_RENDER_PARAM_OPENGL_INIT_PARAMS
private let kMPVRenderParamOpenGLFBO: Int32 = 3            // MPV_RENDER_PARAM_OPENGL_FBO
private let kMPVRenderParamFlipY: Int32 = 4                // MPV_RENDER_PARAM_FLIP_Y
private let kMPVRenderAPIOpenGL = "opengl"                 // MPV_RENDER_API_TYPE_OPENGL

final class MPVPlayerViewModel: NSObject, ObservableObject, PlayerKernel {
    var mpv: OpaquePointer?
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

    private var timeTimer: Timer?
    private var lastSaveAt = Date.distantPast
    private var pendingResume: Double?
    private var pendingURL: URL?
    private var mpvReady = false
    private var renderContext: OpaquePointer?
    private var eventsQueue = DispatchQueue(label: "fmhuangguo.mpv.events", qos: .userInitiated)

    let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(detail: DramaDetail, epNum: Int) {
        self.detail = detail
        let eps = detail.episodeList
        let ep = eps.first { $0.epNum == epNum } ?? eps.first
            ?? Episode(epNum: 1, videoId: "", title: "第1集", duration: 0)
        self.episode = ep
        super.init()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        DebugLogger.shared.log("mpv: 开始创建内核")
        mpv = mpv_create()
        guard mpv != nil else {
            DebugLogger.shared.log("mpv: mpv_create 失败")
            error = "mpv 内核创建失败"
            return
        }
        DebugLogger.shared.log("mpv: mpv_create OK")

        // 渲染交给 render API（GLKView GLES），内核不再直接持有窗口
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "cache", "yes")

        let initStatus = mpv_initialize(mpv)
        guard initStatus >= 0 else {
            DebugLogger.shared.log("mpv: mpv_initialize 失败 \(initStatus)")
            error = "mpv 内核初始化失败"
            return
        }
        DebugLogger.shared.log("mpv: mpv_initialize OK")

        // 诊断：info 级日志（demuxer/TLS/网络打开失败原因都会出现在这里）
        mpv_request_log_messages(mpv, "info")

        // 观察关键属性（事件驱动，配合 0.5s 轮询）
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)

        // 唤醒回调：读属性变化事件
        mpv_set_wakeup_callback(mpv, { ctx in
            let vm = unsafeBitCast(ctx, to: MPVPlayerViewModel.self)
            vm.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        // 0.5s 轮询进度（属性读取线程安全）
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        DebugLogger.shared.log("mpv: 内核就绪")
    }

    deinit {
        timeTimer?.invalidate()
        if let mpv = mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: 视频输出视图（GLKView + GLES render context）

    func makeVideoUIView() -> UIView {
        let view = MPVGLView(frame: .zero)
        view.onRenderReady = { [weak self] in
            self?.mpvReady = true
            // 视图先于播放命令挂载时，补发挂起的加载
            if let url = self?.pendingURL {
                self?.issueLoad(url: url, headers: self?.lastCdnHeaders ?? [:], resume: self?.pendingResume)
            }
        }
        // render context 创建（mpv 已在 init 里 initialize）
        view.attach(mpv: mpv)
        return view
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

    /// 通过 loadfile 装载。请求头走 http-header-fields 属性——
    /// 不能拼进 loadfile 选项串：新版 mpv 的 loadfile 第三个位置参数是 index，
    /// 选项串会被误解析导致静默加载失败。
    private func issueLoad(url: URL, headers: [String: String], resume: Double?) {
        pendingURL = url
        pendingResume = resume
        guard mpvReady, mpv != nil else {
            DebugLogger.shared.log("mpv 未就绪，挂起加载 ep=\(episode.epNum)")
            return
        }
        if !headers.isEmpty {
            // http-header-fields 是逗号分隔列表，条目格式 "Name: value"
            let headerList = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            var data = headerList
            mpv_set_property_string(mpv, "http-header-fields", &data)
            DebugLogger.shared.log("mpv 设置请求头 \(headers.keys.joined(separator: ","))")
        }
        command("loadfile", args: [url.absoluteString, "replace"])
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

    // MARK: 剧集切换

    var nextEpisode: Episode? { detail.episodeList.first { $0.epNum > episode.epNum } }
    var prevEpisode: Episode? { detail.episodeList.last { $0.epNum < episode.epNum } }

    func playNext() async {
        if let n = nextEpisode { await load(ep: n) }
    }

    func playPrev() async {
        if let p = prevEpisode { await load(ep: p) }
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

    /// 音量 0~1（mpv volume 属性 0~100）
    func setVolume(_ normalized: Float) {
        setDouble("volume", Double(max(0, min(1, normalized))) * 100.0)
    }

    func currentVolume() -> Float {
        Float(getDouble("volume") / 100.0)
    }

    // MARK: 属性访问（mpv C API 封装）

    private func setDouble(_ name: String, _ value: Double) {
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
        var data: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data != 0
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
                        // MPV_FORMAT_FLAG 观察的数据是 Int32
                        let flag = UnsafePointer<Int32>(OpaquePointer(prop.data))?.pointee ?? 0
                        DispatchQueue.main.async {
                            switch name {
                            case "paused-for-cache":
                                self.buffering = (flag != 0)
                                self.everPlayed = self.everPlayed || (flag == 0)
                            case "pause":
                                self.playing = (flag == 0)
                            case "eof-reached":
                                if flag != 0 { self.playFinished() }
                            default:
                                break
                            }
                        }
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event!.pointee.data))!
                        .pointee
                    let prefix = String(cString: msg.prefix)
                    let level = String(cString: msg.level)
                    let text = String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    DebugLogger.shared.log("[mpv/\(level)] \(prefix): \(text)")
                    mpv_free(UnsafeMutableRawPointer(mutating: msg.text))
                    mpv_free(UnsafeMutableRawPointer(mutating: msg.prefix))
                    mpv_free(UnsafeMutableRawPointer(mutating: msg.level))
                case MPV_EVENT_START_FILE:
                    DebugLogger.shared.log("mpv START_FILE ep=\(self.episode.epNum)")
                case MPV_EVENT_END_FILE:
                    // reason: 0=EOF 1=STOP 2=QUIT 3=REDIRECT 4=ERROR
                    if let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(event!.pointee.data))?.pointee {
                        let reason = endFile.reason.rawValue
                        DebugLogger.shared.log("mpv END_FILE reason=\(reason) ep=\(self.episode.epNum)")
                        if reason == 0 {
                            DispatchQueue.main.async { self.playFinished() }
                        } else if reason == 4 {
                            DispatchQueue.main.async {
                                self.error = "播放失败：mpv 打开文件出错（详见日志）"
                            }
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    DebugLogger.shared.log("mpv SHUTDOWN")
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
        let status = mpv_command(mpv, &cargs)
        if status < 0 {
            DebugLogger.shared.log("mpv command '\(command)' 失败(\(status)): \(String(cString: mpv_error_string(status)))")
        }
        for ptr in cargs where ptr != nil {
            free(UnsafeMutablePointer(mutating: ptr))
        }
    }
}

// MARK: - mpv OpenGL ES 渲染视图

// mpv 头文件的宏常量不导入 Swift，手动对应（原始 Int32 值）
private enum MPVRenderParam {
    static let apiType: UInt32 = 1                 // MPV_RENDER_PARAM_API_TYPE
    static let openGLInitParams: UInt32 = 2        // MPV_RENDER_PARAM_OPENGL_INIT_PARAMS
    static let openGLFBO: UInt32 = 3               // MPV_RENDER_PARAM_OPENGL_FBO
    static let flipY: UInt32 = 4                   // MPV_RENDER_PARAM_FLIP_Y
}


final class MPVGLView: GLKView {
    private(set) var mpv: OpaquePointer?
    private(set) var renderContext: OpaquePointer?
    private let eaglContext: EAGLContext
    private var renderReady = false
    var onRenderReady: (() -> Void)?

    override init(frame: CGRect) {
        eaglContext = EAGLContext(api: .openGLES3)!
        super.init(frame: frame, context: eaglContext)
        enableSetNeedsDisplay = true
        backgroundColor = UIColor.black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// mpv 句柄注入（mpv_initialize 之后调用，创建 GLES render context）
    func attach(mpv handle: OpaquePointer) {
        guard renderContext == nil else { return }
        mpv = handle
        EAGLContext.setCurrent(eaglContext)

        // mpv_opengl_init_params：get_proc_address 用 dlsym 解析 GLES 符号
        var glInit = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name = name else { return nil }
                return dlsym(nil, name)
            },
            get_proc_address_ctx: nil
        )

        var params: [mpv_render_param] = [
            mpv_render_param(
                type: mpv_render_param_type(MPVRenderParam.apiType),
                data: UnsafeMutableRawPointer(mutating: (kMPVRenderAPIOpenGL as NSString).utf8String)
            ),
            mpv_render_param(
                type: mpv_render_param_type(MPVRenderParam.openGLInitParams),
                data: &glInit
            ),
            mpv_render_param(),
        ]

        var ctx: OpaquePointer?
        let status = mpv_render_context_create(&ctx, mpv, &params)
        guard status >= 0, let created = ctx else {
            DebugLogger.shared.log("mpv render context 创建失败(\(status))")
            return
        }
        renderContext = created
        renderReady = true

        // mpv 通知有新帧 → 触发 GLKView 重绘
        mpv_render_context_set_update_callback(created, { ctx in
            let view = unsafeBitCast(ctx, to: MPVGLView.self)
            DispatchQueue.main.async {
                view.setNeedsDisplay()
            }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        DebugLogger.shared.log("mpv GLES render context OK")
        onRenderReady?()
    }

    // MARK: 绘制（GLKView 驱动，每帧把 mpv 解码画面画进 FBO）

    override func draw(_ rect: CGRect) {
        guard renderReady, let rc = renderContext else { return }
        EAGLContext.setCurrent(eaglContext)

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        let w = Int32(drawableWidth)
        let h = Int32(drawableHeight)

        var glFBO = mpv_opengl_fbo(fbo: fbo, w: w, h: h, internal_format: 0)
        var flip: Int32 = 1
        var params: [mpv_render_param] = [
            mpv_render_param(
                type: mpv_render_param_type(MPVRenderParam.openGLFBO),
                data: &glFBO
            ),
            mpv_render_param(
                type: mpv_render_param_type(MPVRenderParam.flipY),
                data: &flip
            ),
            mpv_render_param(),
        ]
        mpv_render_context_render(rc, &params)
    }
}
