const fs = require('fs');
let s = fs.readFileSync('../FmHuangguo/Views/PlayerView.swift', 'utf8');

// 1) 删 typealias
s = s.split('typealias PlayerViewModel = MPVPlayerViewModel\n\n').join('');

// 2) PlayerLayerView（mpv Metal 容器）→ KernelVideoView 泛型
const plvStart = s.indexOf('// MARK: - mpv 视频输出容器（FFmpeg 内核渲染：CAMetalLayer 经 wid 交给 mpv）');
const plvEnd = s.indexOf('// MARK: - 播放器整屏');
if (plvStart < 0 || plvEnd < plvStart) throw new Error('marker not found');
const kernelVideoView = [
    '// MARK: - 视频输出视图（内核各自实现）',
    '',
    'struct KernelVideoView<Kernel: PlayerKernel>: UIViewRepresentable {',
    '    let vm: Kernel',
    '',
    '    func makeUIView(context: Context) -> UIView {',
    '        vm.makeVideoUIView()',
    '    }',
    '',
    '    func updateUIView(_ uiView: UIView, context: Context) {}',
    '}',
    '',
    '// MARK: - 播放器入口（按设置的内核分发）',
    '',
    'struct PlayerScreen: View {',
    '    let detail: DramaDetail',
    '    let startEp: Int',
    '',
    '    var body: some View {',
    '        if (UserDefaults.standard.string(forKey: "player_kernel") ?? "mpv") == "avplayer" {',
    '            AVScreen(detail: detail, startEp: startEp)',
    '        } else {',
    '            MPVScreen(detail: detail, startEp: startEp)',
    '        }',
    '    }',
    '}',
    '',
    '// MARK: - mpv（FFmpeg）内核壳',
    '',
    'struct MPVScreen: View {',
    '    let detail: DramaDetail',
    '    let startEp: Int',
    '    @StateObject private var vm: MPVPlayerViewModel',
    '',
    '    init(detail: DramaDetail, startEp: Int) {',
    '        self.detail = detail',
    '        self.startEp = startEp',
    '        _vm = StateObject(wrappedValue: MPVPlayerViewModel(detail: detail, epNum: startEp))',
    '    }',
    '',
    '    var body: some View {',
    '        PlayerScreenBody(vm: vm, detail: detail, startEp: startEp)',
    '    }',
    '}',
    '',
    '// MARK: - AVPlayer 内核壳',
    '',
    'struct AVScreen: View {',
    '    let detail: DramaDetail',
    '    let startEp: Int',
    '    @StateObject private var vm: AVPlayerViewModel',
    '',
    '    init(detail: DramaDetail, startEp: Int) {',
    '        self.detail = detail',
    '        self.startEp = startEp',
    '        _vm = StateObject(wrappedValue: AVPlayerViewModel(detail: detail, epNum: startEp))',
    '    }',
    '',
    '    var body: some View {',
    '        PlayerScreenBody(vm: vm, detail: detail, startEp: startEp)',
    '    }',
    '}',
    '',
    '// MARK: - 播放器主体（双内核通用）',
    '',
    'struct PlayerScreenBody<Kernel: PlayerKernel>: View {',
    '    @ObservedObject var vm: Kernel',
    '    let detail: DramaDetail',
    '    let startEp: Int',
    '',
].join('\n');
s = s.slice(0, plvStart) + kernelVideoView + s.slice(plvEnd);

// 3) PlayerScreenBody 内部调整
// 3a) vm 类型（原 @StateObject vm: PlayerViewModel 行删除——已在上面新结构里）
s = s.split('    @StateObject private var vm: PlayerViewModel\n\n').join('\n');
s = s.split('    @StateObject private var vm: PlayerViewModel').join('');
// 3b) onAppear 里的 resume/load Task → loadInitial
const onAppearOld = '            let resume = lib.progress(dramaId: detail.id)\n            Task {\n                DebugLogger.shared.log("onAppear: 准备 load ep=\\(startEp)")\n                if let ep = detail.episodeList.first(where: { $0.epNum == startEp }) ?? detail.episodeList.first {\n                    let pos = (resume?.epNum == ep.epNum) ? resume?.position : nil\n                    await vm.load(ep: ep, resume: (pos ?? 0) > 10 ? pos : nil)\n                }\n            }\n';
s = s.split(onAppearOld).join('            vm.loadInitial(startEp: startEp)\n');
// 3c) 删 lib EnvironmentObject
s = s.split('    @EnvironmentObject private var lib: LibraryStore\n').join('');
// 3d) PlayerLayerView → KernelVideoView
s = s.split('            PlayerLayerView(vm: vm)').join('            KernelVideoView(vm: vm)');
// 3e) 删 onReceive(vm.$playing) 块
const onReceiveOld = '        .onReceive(vm.$playing) { playing in\n            if !playing { flashControls() }\n        }\n';
s = s.split(onReceiveOld).join('');

fs.writeFileSync('../FmHuangguo/Views/PlayerView.swift', s);
console.log('patched, braces:', (s.match(/\{/g) || []).length - (s.match(/\}/g) || []).length);
console.log('remaining lib refs:', (s.match(/lib\./g) || []).length);
console.log('remaining $playing:', (s.match(/\$playing/g) || []).length);
