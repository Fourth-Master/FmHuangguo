import Foundation
import UIKit

// MARK: - 双内核统一接口（mpv / AVPlayer 可切换）
//
// 控制层（PlayerScreenBody）只依赖此协议：
// current/duration/playing/buffering/speed/error/episode/everPlayed/
// lastLoadedURL/lastCdnHeaders/nextEpisode/prevEpisode + 播控方法。

protocol PlayerKernel: ObservableObject {
    /// 视频输出视图（mpv=GLES render API；AVPlayer=AVPlayerLayer）
    func makeVideoUIView() -> UIView

    var current: Double { get }
    var duration: Double { get }
    var playing: Bool { get }
    var buffering: Bool { get }
    var speed: Float { get }
    var speeds: [Float] { get }
    var error: String? { get }
    var controlsVisible: Bool { get set }
    var episode: Episode { get }
    var everPlayed: Bool { get }
    var lastLoadedURL: String { get }
    var lastCdnHeaders: [String: String] { get }
    var nextEpisode: Episode? { get }
    var prevEpisode: Episode? { get }

    /// 进入播放器后按起始集加载（含续播逻辑）
    func loadInitial(startEp: Int)
    func togglePlay()
    func seek(to t: Double)
    func setSpeed(_ s: Float)
    func playNext() async
    func playPrev() async
    func saveProgress(reset: Bool)
    /// 退出播放器时调用（必须停止播放/销毁内核）
    func stopPlayback()
    func setVolume(_ normalized: Float)
    func currentVolume() -> Float
}
