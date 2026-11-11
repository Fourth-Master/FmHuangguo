import SwiftUI
import AVFoundation
import UIKit
import Combine

// MARK: - 播放器视图模型

final class PlayerViewModel: ObservableObject {
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
    /// seek 未完成期间锁住 tick 对 current 的覆盖（修复滑动快进后时间卡住/回跳）
    var scrubbingTarget: Double?
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
        scrubbingTarget = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // seek 完成后以播放器实际时间为准，并允许 tick 恢复更新
                self.current = CMTimeGetSeconds(self.player.currentTime())
                if self.scrubbingTarget == target { self.scrubbingTarget = nil }
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
        // seek 进行中不覆盖 UI 时间，避免卡住/回跳
        if scrubbingTarget == nil, sec.isFinite, sec >= 0 {
            current = sec
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

final class PlayerContainerView: UIView {
    var playerLayer: AVPlayerLayer? {
        layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fillMode: Bool

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        let layer = AVPlayerLayer()
        layer.player = player
        layer.videoGravity = fillMode ? AVLayerVideoGravity.resizeAspectFill : AVLayerVideoGravity.resizeAspect
        v.layer.addSublayer(layer)
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer?.videoGravity = fillMode ? AVLayerVideoGravity.resizeAspectFill : AVLayerVideoGravity.resizeAspect
        // 尺寸变化（旋转/布局）时立即同步 layer frame
        uiView.setNeedsLayout()
    }
}

// MARK: - 播放器整屏

struct PlayerScreen: View {
    let detail: DramaDetail
    let startEp: Int

    @EnvironmentObject private var lib: LibraryStore
    @EnvironmentObject private var prefs: GesturePrefs
    @EnvironmentObject private var cacheManager: VideoCacheManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PlayerViewModel

    @State private var showControls = true
    /// 默认按比例完整显示（fit）；双击切换填充/完整
    @State private var fillMode = false
    @State private var showEpisodeSheet = false
    @State private var hideTask: Task<Void, Never>?

    // 手势状态
    @State private var dragMode: DragMode = .none
    @State private var dragStartVolume: Float = 0
    @State private var dragStartBrightness: CGFloat = 0
    @State private var dragStartTime: Double = 0
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var hudText = ""
    @State private var hudVisible = false

    enum DragMode: Equatable {
        case none, brightness, volume, seek
        /// 长按已激活（倍速会话）：本次触摸屏蔽亮度/音量/快进分类
        case lockedByLongPress
    }

    // 长按倍速（@GestureState 保证任何结束路径都会回滚速度）
    @GestureState private var longPressActive: Bool = false
    @State private var speedBeforeLongPress: Float = 1.0
    @State private var longPressEngaged = false
    /// 长按后上下滑微调倍速（0.5x~3x 步进 0.25）
    @State private var lpDragBaseSpeed: Float = 1.0
    /// HUD 进度条数值（0~1，nil 隐藏），用于亮度/音量/快进
    @State private var hudProgress: Double?

    init(detail: DramaDetail, startEp: Int) {
        self.detail = detail
        self.startEp = startEp
        _vm = StateObject(wrappedValue: PlayerViewModel(detail: detail, epNum: startEp))
    }

    var body: some View {
        GeometryReader { geo in
            playerArea(width: geo.size.width, height: geo.size.height,
                       landscape: geo.size.width > geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBar(hidden: true)
        .onAppear {
            AppDelegate.orientationLock = .allButUpsideDown
            UIViewController.attemptRotationToDeviceOrientation()
            UIApplication.shared.isIdleTimerDisabled = true
            let resume = lib.progress(dramaId: detail.id)
            Task {
                if let ep = detail.episodeList.first(where: { $0.epNum == startEp }) ?? detail.episodeList.first {
                    let pos = (resume?.epNum == ep.epNum) ? resume?.position : nil
                    await vm.load(ep: ep, resume: (pos ?? 0) > 10 ? pos : nil)
                }
            }
        }
        .onDisappear {
            // 保险：退出播放器时若倍速还挂着，强制恢复
            if longPressEngaged {
                longPressEngaged = false
                vm.setSpeed(speedBeforeLongPress)
                hudVisible = false
            }
            vm.saveProgress()
            UIApplication.shared.isIdleTimerDisabled = false
            AppDelegate.orientationLock = .portrait
            UIViewController.attemptRotationToDeviceOrientation()
        }
        .sheet(isPresented: $showEpisodeSheet) {
            episodeSheet
        }
        .onReceive(vm.$playing) { playing in
            if !playing { flashControls() }
        }
    }

    // MARK: 播放区

    private func playerArea(width: CGFloat, height: CGFloat, landscape: Bool) -> some View {
        ZStack {
            Color.black
            PlayerLayerView(player: vm.player, fillMode: fillMode)
                .allowsHitTesting(false)

            if vm.buffering && vm.error == nil {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if let err = vm.error {
                errorOverlay(err)
            }

            // HUD：顶部居中（长按倍速/亮度/音量/快进提示）
            if hudVisible {
                VStack(spacing: 8) {
                    Text(hudText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    if hudProgress != nil {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.25))
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: geo.size.width * (hudProgress ?? 0))
                            }
                        }
                        .frame(width: 120, height: 4)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.72)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 56) // 避开顶部返回栏
                .allowsHitTesting(false)
            }

            controlsOverlay(landscape: landscape)
        }
        .frame(height: landscape ? nil : height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(gestureLayer(width: width))
    }

    // MARK: 手势层
    //
    // 挂在整个播放区最外层（.simultaneousGesture），不放在 ZStack 子视图里。
    // simultaneous 不会阻断 Button 的点击：Button 正常响应，空白区域则由这组
    // 手势处理单击/双击/长按/拖动。之前放在 ZStack 中间层时，与上层 Button
    // 存在 tap 竞态，导致右下角横屏/选集按钮偶尔无效。
    private func gestureLayer(width: CGFloat) -> some Gesture {
        SimultaneousGesture(
            TapGesture(count: 2).onEnded { handleDoubleTap() },
            SimultaneousGesture(
                TapGesture().onEnded { flashControls() },
                SimultaneousGesture(longPressGesture, dragGesture(width: width))
            )
        )
    }

    // MARK: 控制层

    private func controlsOverlay(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            // 顶部
            HStack(spacing: 12) {
                Button {
                    vm.saveProgress()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(vm.episode.title)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(
                LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .opacity(showControls ? 1 : 0)

            Spacer()

            // 控制按钮组：紧贴进度条上方（原居中，移至底部）
            HStack(spacing: 38) {
                Button {
                    haptic()
                    Task { await vm.playPrev() }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.white.opacity(vm.prevEpisode != nil ? 0.14 : 0.05)))
                        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                }
                .disabled(vm.prevEpisode == nil)

                Button {
                    haptic(.medium)
                    vm.togglePlay()
                    flashControls()
                } label: {
                    Image(systemName: vm.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
                }

                Button {
                    haptic()
                    Task { await vm.playNext() }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.white.opacity(vm.nextEpisode != nil ? 0.14 : 0.05)))
                        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                }
                .disabled(vm.nextEpisode == nil)
            }
            .opacity(showControls && vm.error == nil ? 1 : 0)
            .padding(.bottom, 6)

            // 底部
            HStack(spacing: 10) {
                Text(fmtTime(displayTime))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .monospacedDigit()

                // 自定义进度条：支持点击跳转 + 拖动（Slider 与外层手势有竞态）
                SeekBar(current: displayTime,
                        duration: max(vm.duration, 0.001),
                        onSeek: { target in
                            Task { await vm.seek(to: target) }
                            flashControls()
                        },
                        onScrub: { scrubbingValue in
                            if let v = scrubbingValue {
                                scrubValue = v
                                scrubbing = true
                            } else {
                                scrubbing = false
                            }
                        })
                    .frame(height: 28)

                Text(fmtTime(vm.duration))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .monospacedDigit()

                Menu {
                    Picker("倍速", selection: Binding(
                        get: { vm.speed },
                        set: { newValue in
                            vm.setSpeed(newValue)
                            flashControls()
                        }
                    )) {
                        ForEach(vm.speeds, id: \.self) { s in
                            Text(speedLabel(s)).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(speedLabel(vm.speed))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }

                Button {
                    showEpisodeSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                }

                // 缓存当前集
                Button {
                    cacheCurrentEpisode()
                } label: {
                    Image(systemName: cacheStateIcon)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                }

                Button {
                    rotate()
                } label: {
                    Image(systemName: landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .opacity(showControls ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    private var displayTime: Double {
        scrubbing ? scrubValue : vm.current
    }

    // MARK: 缓存当前集

    private var cacheStateIcon: String {
        if let st = cacheManager.state(dramaId: detail.id, epNum: vm.episode.epNum) {
            if st.done { return "checkmark.circle.fill" }
            if st.progress < 0 { return "exclamationmark.circle" }
            return "arrow.down.circle.fill"
        }
        return "arrow.down.circle"
    }

    private func cacheCurrentEpisode() {
        guard let urlStr = vm.lastLoadedURL.isEmpty ? nil : vm.lastLoadedURL,
              let url = URL(string: urlStr) else {
            hudText = "请先播放后再缓存"
            hudProgress = nil
            hudVisible = true
            hideHudAfterDelay()
            return
        }
        if VideoCacheManager.shared.isCached(dramaId: detail.id, epNum: vm.episode.epNum) {
            hudText = "本集已缓存"
            hudProgress = nil
            hudVisible = true
            hideHudAfterDelay()
            return
        }
        VideoCacheManager.shared.download(dramaId: detail.id, epNum: vm.episode.epNum,
                                          title: detail.title,
                                          m3u8URL: url,
                                          headers: vm.lastCdnHeaders)
        hudText = "开始缓存本集"
        hudProgress = nil
        hudVisible = true
        hideHudAfterDelay()
        haptic(.medium)
    }

    private func errorOverlay(_ err: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.85))
            Text(err)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    Task {
                        await vm.load(ep: vm.episode, resume: vm.current > 0 ? vm.current : nil)
                    }
                } label: {
                    Text("重试")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 7)
                        .background(Color.white)
                        .foregroundColor(.black)
                        .cornerRadius(16)
                }
                Button {
                    vm.saveProgress()
                    dismiss()
                } label: {
                    Text("返回")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Color.white.opacity(0.25))
                        .foregroundColor(.white)
                        .cornerRadius(16)
                }
            }
        }
        .padding(24)
        .background(Color.black.opacity(0.75))
        .cornerRadius(16)
    }

    // MARK: 选集 Sheet（底部"选集"按钮唤出）

    private var episodeSheet: some View {
        NavigationView {
            ScrollView {
                let gridColumns = [GridItem(.adaptive(minimum: 84), spacing: 8)]
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(detail.episodeList) { ep in
                        Button {
                            Task { await vm.load(ep: ep) }
                            showEpisodeSheet = false
                        } label: {
                            Text("第\(ep.epNum)集")
                                .font(.system(size: 13, weight: ep.epNum == vm.episode.epNum ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(ep.epNum == vm.episode.epNum ? Color.accentColor : Color(white: 0.93))
                                .foregroundColor(ep.epNum == vm.episode.epNum ? .white : .primary)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { showEpisodeSheet = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 手势

    /// 长按：按偏好执行（默认临时 2x；上下滑按偏好执行，默认调倍速）
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($longPressActive) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                if case .second(true, let drag) = value {
                    if !longPressEngaged {
                        longPressEngaged = true
                        speedBeforeLongPress = vm.speed
                        lpDragBaseSpeed = vm.speed
                        // 长按激活：取消本次触摸可能已进入的亮度/音量/快进模式
                        // （把系统亮度/音量不动，仅放弃本次 drag 会话，HUD 交给倍速）
                        dragMode = .lockedByLongPress
                        scrubbing = false
                        switch prefs.longPress {
                        case .speedUpLongPress:
                            vm.setSpeed(2.0)
                            hudText = "2x 倍速播放中"
                            hudProgress = nil
                        case .togglePlay:
                            vm.togglePlay()
                        case .fillToggle:
                            fillMode.toggle()
                        case .speedDrag, .none:
                            hudText = "上下滑动调节倍速"
                            hudProgress = nil
                        }
                        hudVisible = true
                        haptic(.medium)
                    } else if prefs.longPress == .speedDrag || prefs.longPressVerticalDrag == .speedDrag {
                        // 长按后上下滑：每 45pt 调 0.25x（上增下减，0.5x~3x）
                        let dy = drag?.translation.height ?? 0
                        let steps = Int(-dy / 45)
                        let target = max(0.5, min(3.0, lpDragBaseSpeed + Float(steps) * 0.25))
                        if abs(target - vm.speed) >= 0.001 {
                            vm.setSpeed(target)
                            hudText = "倍速 \(speedLabel(target))"
                            hudProgress = Double((target - 0.5) / 2.5)
                        }
                    }
                }
            }
            .onEnded { _ in
                if longPressEngaged {
                    longPressEngaged = false
                    if prefs.longPress == .speedUpLongPress {
                        vm.setSpeed(speedBeforeLongPress)
                    }
                    hudVisible = false
                }
            }
    }

    /// 双击：按偏好执行
    private func handleDoubleTap() {
        switch prefs.doubleTap {
        case .togglePlay:
            vm.togglePlay()
            flashControls()
        case .fillToggle:
            fillMode.toggle()
        case .speedUpLongPress:
            vm.setSpeed(vm.speed >= 2.0 ? 1.0 : 2.0)
            hudText = "倍速 \(speedLabel(vm.speed))"
            hudVisible = true
            hideHudAfterDelay()
        case .speedDrag, .none:
            break
        }
    }

    private func hideHudAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            hudVisible = false
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if dragMode == .none {
                    // 长按倍速会话进行中：本次触摸锁定，不再进入亮度/音量/快进
                    if longPressEngaged {
                        dragMode = .lockedByLongPress
                        return
                    }
                    let vertical = abs(v.translation.height) > abs(v.translation.width)
                    if vertical {
                        if v.startLocation.x < width / 2 {
                            dragMode = .brightness
                            dragStartBrightness = UIScreen.main.brightness
                        } else {
                            dragMode = .volume
                            dragStartVolume = vm.player.volume
                        }
                    } else {
                        dragMode = .seek
                        dragStartTime = vm.current
                    }
                }
                // 长按锁定期间完全让给倍速手势（倍速 HUD 由 longPressGesture 自己更新）
                guard dragMode != .lockedByLongPress else { return }
                switch dragMode {
                case .brightness:
                    let delta = -v.translation.height / 320
                    let b = min(1, max(0.01, dragStartBrightness + delta))
                    UIScreen.main.brightness = b
                    hudText = "亮度 \(Int(b * 100))%"
                    hudProgress = b
                case .volume:
                    let delta = Float(-v.translation.height) / 320
                    let vol = min(1, max(0, dragStartVolume + delta))
                    vm.player.volume = vol
                    hudText = "音量 \(Int(vol * 100))%"
                    hudProgress = Double(vol)
                case .seek:
                    let delta = Double(v.translation.width) / Double(max(width, 1)) * 120
                    let target = max(0, min(vm.duration, dragStartTime + delta))
                    hudText = "\(fmtTime(target)) / \(fmtTime(vm.duration))"
                    hudProgress = vm.duration > 0 ? target / vm.duration : nil
                    scrubValue = target
                    scrubbing = true
                case .none:
                    break
                }
                if dragMode != .none {
                    hudVisible = true
                }
            }
            .onEnded { _ in
                if dragMode == .seek {
                    let target = scrubValue
                    Task { await vm.seek(to: target) }
                }
                dragMode = .none
                hudVisible = false
                hudProgress = nil
                // 手势结束后立刻退出 scrub 状态，恢复跟随播放器实时时间
                scrubbing = false
            }
    }

    // MARK: 工具

    private func flashControls() {
        withAnimation { showControls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    if vm.playing {
                        withAnimation { showControls = false }
                    }
                }
            }
        }
    }

    private func rotate() {
        if UIDevice.current.orientation.isLandscape {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }

    private func speedLabel(_ s: Float) -> String {
        if s == floorf(s) { return "\(Int(s))x" }
        return "\(s)x"
    }
}

// MARK: - 自定义进度条（点击跳转 + 拖动 seek，替代 Slider 的手势竞态问题）

struct SeekBar: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onScrub: (Double?) -> Void

    @State private var dragValue: Double?

    private var progress: Double {
        if let dv = dragValue { return min(1, max(0, dv / max(duration, 0.001))) }
        return min(1, max(0, current / max(duration, 0.001)))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 4)
                // 已播
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, w * progress), height: 4)
                // 手柄
                Circle()
                    .fill(Color.white)
                    .frame(width: progress > 0 ? 12 : 0, height: 12)
                    .offset(x: max(0, w * progress - 6))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = min(max(0, v.location.x / max(w, 1)), 1) * duration
                        dragValue = t
                        onScrub(t)
                    }
                    .onEnded { _ in
                        let t = dragValue ?? 0
                        dragValue = nil
                        onScrub(nil)
                        onSeek(t)
                    }
            )
        }
    }
}
