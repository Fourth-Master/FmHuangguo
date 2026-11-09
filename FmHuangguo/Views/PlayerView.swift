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
            var urlStr = ""
            if ep.videoId.isEmpty {
                if ep.epNum == 1, let fu = detail.firstPlayUrl, !fu.isEmpty {
                    urlStr = fu
                } else {
                    throw APIError.noPlayURL
                }
            } else {
                let info = try await SiteAPI.shared.play(videoId: ep.videoId)
                urlStr = info.videoUrl ?? ""
                if urlStr.isEmpty, ep.epNum == 1, let fu = detail.firstPlayUrl { urlStr = fu }
                if let d = info.duration, d > 0 { duration = Double(d) }
            }
            guard let url = URL(string: urlStr) else { throw APIError.noPlayURL }

            let headers: [String: String] = [
                "Referer": SiteAPI.shared.base + "/",
                "User-Agent": RouteService.ua,
            ]
            // AVURLAssetHTTPHeaderFieldsKey：设置请求头（ Referer / UA 防盗链 ）
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
        } catch {
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
        layer.frame = UIScreen.main.bounds
        v.layer.addSublayer(layer)
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer?.videoGravity = fillMode ? AVLayerVideoGravity.resizeAspectFill : AVLayerVideoGravity.resizeAspect
    }
}

// MARK: - 播放器整屏

struct PlayerScreen: View {
    let detail: DramaDetail
    let startEp: Int

    @EnvironmentObject private var lib: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PlayerViewModel

    @State private var showControls = true
    @State private var fillMode = true
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
    }

    // 长按倍速
    @State private var longPressActive = false
    @State private var speedBeforeLongPress: Float = 1.0
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

            // 手势层：在控制层之下，控制按钮/进度条优先接收触摸，
            // 空白区域落到这一层处理 拖动快进/亮度/音量/长按倍速/单击/双击
            gestureLayer(width: width)

            if vm.buffering && vm.error == nil {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if let err = vm.error {
                errorOverlay(err)
            }

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
            }

            controlsOverlay(landscape: landscape)
        }
        .frame(height: landscape ? nil : height)
        .frame(maxWidth: .infinity)
    }

    // MARK: 手势层（位于控制层之下；控制按钮与进度条在上层优先拿触摸）

    private func gestureLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                fillMode.toggle()
            }
            .onTapGesture(count: 1) {
                flashControls()
            }
            .simultaneousGesture(longPressGesture)
            .simultaneousGesture(dragGesture(width: width))
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
            .background(
                LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .opacity(showControls ? 1 : 0)

            Spacer()

            // 中央控制按钮
            HStack(spacing: 46) {
                Button {
                    haptic()
                    Task { await vm.playPrev() }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.white.opacity(vm.prevEpisode != nil ? 0.16 : 0.06)))
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }
                .disabled(vm.prevEpisode == nil)

                Button {
                    haptic(.medium)
                    vm.togglePlay()
                    flashControls()
                } label: {
                    Image(systemName: vm.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.black)
                        .frame(width: 74, height: 74)
                        .background(Circle().fill(Color.white.opacity(0.92)))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                }

                Button {
                    haptic()
                    Task { await vm.playNext() }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.white.opacity(vm.nextEpisode != nil ? 0.16 : 0.06)))
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }
                .disabled(vm.nextEpisode == nil)
            }
            .opacity(showControls && vm.error == nil ? 1 : 0)

            Spacer()

            // 底部
            HStack(spacing: 10) {
                Text(fmtTime(displayTime))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { min(max(0, displayTime), max(vm.duration, 0.001)) },
                        set: { newValue in
                            scrubValue = newValue
                            scrubbing = true
                        }
                    ),
                    in: 0...max(vm.duration, 0.001)
                ) { editing in
                    if editing {
                        scrubbing = true
                        scrubValue = vm.current
                    } else {
                        scrubbing = false
                        let target = scrubValue
                        Task { await vm.seek(to: target) }
                        flashControls()
                    }
                }                .accentColor(.white)

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

    /// 长按 2x 倍速播放（松开恢复原速）
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.6)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !longPressActive {
                        longPressActive = true
                        speedBeforeLongPress = vm.speed
                        vm.setSpeed(2.0)
                        hudText = "2x 倍速播放中"
                        hudProgress = nil
                        hudVisible = true
                    }
                case .second(true, _):
                    break
                default:
                    break
                }
            }
            .onEnded { _ in
                if longPressActive {
                    longPressActive = false
                    vm.setSpeed(speedBeforeLongPress)
                    hudVisible = false
                }
            }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if dragMode == .none {
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
