import SwiftUI
import UIKit

// MARK: - 视频输出视图（mpv GLES render API）

struct KernelVideoView: UIViewRepresentable {
    let vm: MPVPlayerViewModel

    func makeUIView(context: Context) -> UIView {
        vm.makeVideoUIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 播放器入口（mpv 单内核）

struct PlayerScreen: View {
    let detail: DramaDetail
    let startEp: Int
    @StateObject private var vm: MPVPlayerViewModel

    init(detail: DramaDetail, startEp: Int) {
        self.detail = detail
        self.startEp = startEp
        _vm = StateObject(wrappedValue: MPVPlayerViewModel(detail: detail, epNum: startEp))
    }

    var body: some View {
        PlayerScreenBody(vm: vm, detail: detail, startEp: startEp)
    }
}

// MARK: - 播放器主体（控制层/手势/HUD/缓存/选集）

struct PlayerScreenBody: View {
    @ObservedObject var vm: MPVPlayerViewModel
    let detail: DramaDetail
    let startEp: Int

    @EnvironmentObject private var speedPrefs: SpeedPrefs
    @EnvironmentObject private var cacheManager: VideoCacheManager
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    /// 默认按比例完整显示（fit）；双击切换填充/完整
    @State private var fillMode = false
    @State private var showEpisodeSheet = false
    @State private var hideTask: Task<Void, Never>?

    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var hudText = ""
    @State private var hudVisible = false

    // 拖动手势状态（亮度/音量/快进）
    @State private var dragMode: DragMode = .none
    @State private var dragStartVolume: Float = 0
    @State private var dragStartBrightness: CGFloat = 0
    @State private var dragStartTime: Double = 0

    enum DragMode: Equatable {
        case none, brightness, volume, seek
        /// 长按会话中上下滑：微调倍速（0.1 步进）
        case speedTune
        /// 长按会话进行中（左右滑）：本次触摸忽略
        case lockedByLongPress
    }

    // 长按倍速（@GestureState 保证任何结束路径都会回滚速度）
    @GestureState private var longPressActive: Bool = false
    @State private var speedBeforeLongPress: Float = 1.0
    @State private var longPressEngaged = false
    /// 长按上下滑微调的基准倍速（= 进入长按时应用的倍速）
    @State private var speedTuneBase: Float = 2.0
    /// 长按后上下滑微调倍速的基准（= 设置的长按倍速）
    @State private var lpDragBaseSpeed: Float = 2.0
    /// HUD 进度条数值（0~1，nil 隐藏）
    @State private var hudProgress: Double?

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
            vm.loadInitial(startEp: startEp)
        }
        .onDisappear {
            DebugLogger.shared.log("onDisappear: 停止播放")
            // 退出播放器必须停止内核（否则音频会话残留，返回后仍在后台播放）
            vm.stopPlayback()
            if longPressEngaged {
                longPressEngaged = false
                vm.setSpeed(speedBeforeLongPress)
                hudVisible = false
            }
            vm.saveProgress(reset: false)
            UIApplication.shared.isIdleTimerDisabled = false
            AppDelegate.orientationLock = .portrait
            UIViewController.attemptRotationToDeviceOrientation()
        }
        .sheet(isPresented: $showEpisodeSheet) {
            episodeSheet
        }
    }

    // MARK: 播放区

    private func playerArea(width: CGFloat, height: CGFloat, landscape: Bool) -> some View {
        ZStack {
            Color.black
            KernelVideoView(vm: vm)
                .allowsHitTesting(false)

            // 加载转圈：仅初始加载/切集时显示（播放中途 re-buffer 不打扰）
            if vm.buffering && !vm.everPlayed && vm.error == nil {
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

    // MARK: 手势（单击呼出控制/双击暂停/长按倍速/拖动 亮度-音量-快进）
    //
    // 挂在整个播放区最外层（.simultaneousGesture），不占 hit-test 层级，
    // 控制层 Button 命中时系统直接交给 Button。
    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded { handleDoubleTap() }
    }

    private var singleTapGesture: some Gesture {
        TapGesture().onEnded { flashControls() }
    }

    private func gestureLayer(width: CGFloat) -> some Gesture {
        let taps = SimultaneousGesture(doubleTapGesture, singleTapGesture)
        let core = SimultaneousGesture(longPressGesture, dragGesture(width: width))
        return SimultaneousGesture(taps, core)
    }

    // MARK: 控制层

    private func controlsOverlay(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            // 顶部
            HStack(spacing: 12) {
                Button {
                    vm.saveProgress(reset: false)
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
            .allowsHitTesting(showControls)

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
            .allowsHitTesting(showControls && vm.error == nil)
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
            .allowsHitTesting(showControls)
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
                    vm.saveProgress(reset: false)
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

    private var episodeGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 84), spacing: 8)]
    }

    private func episodeChip(_ ep: Episode) -> some View {
        let isCurrent = ep.epNum == vm.episode.epNum
        return Button {
            Task { await vm.load(ep: ep, resume: nil) }
            showEpisodeSheet = false
        } label: {
            Text("第\(ep.epNum)集")
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isCurrent ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(isCurrent ? .white : .primary)
                .cornerRadius(10)
        }
    }

    private var episodeGrid: some View {
        LazyVGrid(columns: episodeGridColumns, spacing: 8) {
            ForEach(detail.episodeList) { ep in
                episodeChip(ep)
            }
        }
        .padding(12)
    }

    private var episodeSheet: some View {
        NavigationView {
            ScrollView {
                episodeGrid
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

    /// 长按：临时应用设置的倍速（默认 2x，松开恢复）
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($longPressActive) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onChanged { value in
                if case .second(true, _) = value {
                    if !longPressEngaged {
                        longPressEngaged = true
                        speedBeforeLongPress = vm.speed
                        let cfg = Float(UserDefaults.standard.double(forKey: "long_press_speed"))
                        speedTuneBase = cfg
                        vm.setSpeed(cfg)
                        hudText = String(format: "%.1f", cfg) + " 倍速播放中"
                        hudProgress = nil
                        hudVisible = true
                        haptic(.medium)
                    }
                }
            }
            .onEnded { _ in
                if longPressEngaged {
                    longPressEngaged = false
                    vm.setSpeed(speedBeforeLongPress)
                    hudVisible = false
                }
            }
    }

    /// 双击：暂停/播放
    private func handleDoubleTap() {
        vm.togglePlay()
        flashControls()
    }

    private func hideHudAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            hudVisible = false
        }
    }

    // MARK: 拖动手势（亮度/音量/快进；长按会话期间锁定让位倍速）

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if dragMode == .none {
                    // 长按倍速会话进行中：上下滑=微调倍速（0.1 步进），左右滑忽略
                    if longPressEngaged {
                        if abs(v.translation.height) > abs(v.translation.width) {
                            dragMode = .speedTune
                            speedTuneBase = vm.speed
                        } else {
                            dragMode = .lockedByLongPress
                        }
                        return
                    }
                    let vertical = abs(v.translation.height) > abs(v.translation.width)
                    if vertical {
                        if v.startLocation.x < width / 2 {
                            dragMode = .brightness
                            dragStartBrightness = UIScreen.main.brightness
                        } else {
                            dragMode = .volume
                            dragStartVolume = vm.currentVolume()
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
                    let delta = Float(-v.translation.height / 320)
                    let vol = min(1, max(0, dragStartVolume + delta))
                    vm.setVolume(vol)
                    hudText = "音量 \(Int(vol * 100))%"
                    hudProgress = Double(vol)
                case .seek:
                    let delta = Double(v.translation.width) / Double(max(width, 1)) * 120
                    let target = max(0, min(vm.duration, dragStartTime + delta))
                    hudText = "\(fmtTime(target)) / \(fmtTime(vm.duration))"
                    hudProgress = vm.duration > 0 ? target / vm.duration : nil
                    scrubValue = target
                    scrubbing = true
                case .speedTune:
                    // 长按上下滑微调：每 30pt ±0.1，范围 0.5~5.0，量化到一位小数
                    let delta = Float(-v.translation.height) / 30.0 * 0.1
                    let s = max(0.5, min(5.0, speedTuneBase + delta))
                    let q = (s * 10).rounded() / 10
                    vm.setSpeed(q)
                    hudText = String(format: "%.1f", q) + " 倍速播放中"
                    hudProgress = nil
                case .none, .lockedByLongPress:
                    break
                }
                if dragMode != .none {
                    hudVisible = true
                }
            }
            .onEnded { _ in
                // 锁定态（长按倍速会话）绝不执行 seek——否则调倍速会被当成快进跳播
                if dragMode == .seek, !longPressEngaged {
                    let target = scrubValue
                    Task { await vm.seek(to: target) }
                }
                dragMode = .none
                hudVisible = false
                hudProgress = nil
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
        String(format: "%.1fx", s)
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
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, w * progress), height: 4)
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
