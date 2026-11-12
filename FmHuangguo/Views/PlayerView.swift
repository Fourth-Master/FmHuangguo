import SwiftUI
import AVFoundation
import UIKit
import Combine
import Libmpv

// MARK: - 播放器视图模型（FFmpeg/VLC 内核，见 VLCPlayerViewModel.swift）
//
// PlayerViewModel 保留为 VLCPlayerViewModel 的类型别名，控制层代码全部通用：
// current/duration/playing/buffering/speed/error、seek/setSpeed/load 语义一致。

typealias PlayerViewModel = MPVPlayerViewModel

// MARK: - mpv 视频输出容器（FFmpeg 内核渲染：CAMetalLayer 经 wid 交给 mpv）

struct PlayerLayerView: UIViewRepresentable {
    let vm: PlayerViewModel

    func makeUIView(context: Context) -> MPVMetalContainerView {
        let v = MPVMetalContainerView()
        v.onLayerReady = { layer in
            vm.attachMetalLayer(layer)
        }
        return v
    }

    func updateUIView(_ uiView: MPVMetalContainerView, context: Context) {}
}

// MARK: - 播放器整屏

struct PlayerScreen: View {
    let detail: DramaDetail
    let startEp: Int

    @EnvironmentObject private var lib: LibraryStore
    @EnvironmentObject private var prefs: SpeedPrefs
    @EnvironmentObject private var cacheManager: VideoCacheManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PlayerViewModel

    @State private var showControls = true
    /// 默认按比例完整显示（fit）；双击切换填充/完整
    @State private var fillMode = false
    @State private var showEpisodeSheet = false
    @State private var hideTask: Task<Void, Never>?

    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var hudText = ""
    @State private var hudVisible = false

    // 长按倍速（@GestureState 保证任何结束路径都会回滚速度）
    @GestureState private var longPressActive: Bool = false
    @State private var speedBeforeLongPress: Float = 1.0
    @State private var longPressEngaged = false
    /// HUD 进度条数值（0~1，nil 隐藏）
    @State private var hudProgress: Double?

    init(detail: DramaDetail, startEp: Int) {
        self.detail = detail
        self.startEp = startEp
        DebugLogger.shared.log("PlayerScreen init ep=\(startEp)")
        _vm = StateObject(wrappedValue: PlayerViewModel(detail: detail, epNum: startEp))
        DebugLogger.shared.log("PlayerScreen init 完成 ep=\(startEp)")
    }

    var body: some View {
        GeometryReader { geo in
            playerArea(width: geo.size.width, height: geo.size.height,
                       landscape: geo.size.width > geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBar(hidden: true)
        .onAppear {
            DebugLogger.shared.log("onAppear 开始")
            AppDelegate.orientationLock = .allButUpsideDown
            UIViewController.attemptRotationToDeviceOrientation()
            UIApplication.shared.isIdleTimerDisabled = true
            let resume = lib.progress(dramaId: detail.id)
            Task {
                DebugLogger.shared.log("onAppear: 准备 load ep=\(startEp)")
                if let ep = detail.episodeList.first(where: { $0.epNum == startEp }) ?? detail.episodeList.first {
                    let pos = (resume?.epNum == ep.epNum) ? resume?.position : nil
                    await vm.load(ep: ep, resume: (pos ?? 0) > 10 ? pos : nil)
                }
            }
        }
        .onDisappear {
            DebugLogger.shared.log("onDisappear: 停止播放")
            // 退出播放器必须停止 VLC（否则音频会话残留，返回后仍在后台播放）
            vm.stopPlayback()
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
            PlayerLayerView(vm: vm)
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
        .simultaneousGesture(gestureLayer())
    }

    // MARK: 手势（已按需求精简：仅保留 单击呼出控制/双击暂停/长按倍速）
    //
    // 挂在整个播放区最外层（.simultaneousGesture），不占 hit-test 层级，
    // 控制层 Button 命中时系统直接交给 Button。
    private func gestureLayer() -> some Gesture {
        SimultaneousGesture(
            TapGesture(count: 2).onEnded { handleDoubleTap() },
            SimultaneousGesture(
                TapGesture().onEnded { flashControls() },
                longPressGesture
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
                                .background(ep.epNum == vm.episode.epNum ? Color.accentColor : Color(.secondarySystemBackground))
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
                        vm.setSpeed(Float(speedPrefs.longPressSpeed))
                        hudText = String(format: "%.2f", speedPrefs.longPressSpeed) + " 倍速播放中"
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
