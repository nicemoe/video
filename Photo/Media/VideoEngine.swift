import SwiftUI
import AVFoundation
import KSPlayer
import VideoToolbox
import Libavformat

/// 统一由 FFmpeg 解封装；硬件与软件解码通过实例配置明确选择。
@MainActor
protocol VideoEngine: AnyObject {

    /// 渲染画面的视图。引擎自己建、自己管，外面只负责摆位置。
    var renderView: UIView { get }

    var duration: Double { get }
    var currentTime: Double { get }
    var volume: Float { get set }

    func play()
    func pause()
    func setRate(_ rate: Float)

    /// 从前一个关键帧解码到目标位置；同一时刻只执行一个跳转。
    func seek(to seconds: Double)

    /// 适应（留黑边）还是填充（裁掉溢出的部分）
    func setFill(_ on: Bool)

    func shutdown()

    /// 进度回调，约 0.2 秒一次
    var onProgress: ((Double) -> Void)? { get set }
    /// 时长探测出来了。有些封装要解析一会儿才知道。
    var onDuration: ((Double) -> Void)? { get set }
    /// 播完了
    var onFinish: (() -> Void)? { get set }
    /// 播放失败。自动模式由播放页决定是否改用软件解码。
    var onFailure: ((String) -> Void)? { get set }
}

// MARK: - 引擎的画面层

/// 把引擎的 renderView 塞进 SwiftUI。
///
/// 引擎换了就整个换掉里面的视图——SwiftUI 靠 id 区分，不会复用错。
struct EngineView: UIViewRepresentable {
    let engine: any VideoEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        // 画面本身不需要接触摸。开着的话它会先把触摸吃掉，
        // 外层的单击/双击就不一定收得到。
        container.isUserInteractionEnabled = false
        attach(to: container)
        return container
    }

    /// SwiftUI 有可能把容器复用给另一个引擎，每次更新都核对一下里面装的是谁
    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        let view = engine.renderView
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

// MARK: - KSPlayer / FFmpeg

@MainActor
final class FFmpegEngine: NSObject, VideoEngine {

    private let player: KSMEPlayer
    private let hardwareDecode: Bool
    private let options: KSOptions
    private let container = UIView()
    private var ticker: Timer?
    private var rate: Float = 1
    private var wantsPlay = false
    private var ready = false
    private var fill = false
    private var stopped = false
    private var seeking = false
    private var pendingSeek: Double?

    var onProgress: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var renderView: UIView { container }
    var duration: Double { player.duration }
    var currentTime: Double { player.currentPlaybackTime }
    var volume: Float {
        get { player.playbackVolume }
        set { player.playbackVolume = newValue }
    }

    init(url: URL, hardwareDecode: Bool) {
        self.hardwareDecode = hardwareDecode
        let options = ReferenceSafePlaybackOptions()
        self.options = options
        options.hardwareDecode = hardwareDecode
        options.asynchronousDecompression = false
        options.isAccurateSeek = true
        // KSPlayer 默认添加 FAST；禁用非标准加速和首个关键帧之前的输出。
        options.decoderOptions["flags2"] = "-fast-showall"
        options.decoderOptions["flags"] = "-output_corrupt"
        options.isSeekedAutoPlay = false
        options.registerRemoteControll = false
        player = KSMEPlayer(url: url, options: options)
        super.init()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        player.delegate = self
        player.prepareToPlay()

        // KSPlayer 没有 AVPlayer 那种周期回调，自己按 0.2 秒轮询一次。
        // 轮询一个内存里的数字，开销可以忽略。
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if !self.seeking, self.pendingSeek == nil {
                    self.onProgress?(self.player.currentPlaybackTime)
                }
                let d = self.player.duration
                if d > 0 { self.onDuration?(d) }
            }
        }
    }

    /// 画面视图要等解码器把首帧准备好才有，建好之后再挂进容器
    private func attachRenderViewIfNeeded() {
        guard ready, !stopped, let view = player.view, view.superview !== container else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        container.addSubview(view)
    }

    func play() {
        wantsPlay = true
        guard ready, !stopped, !seeking, pendingSeek == nil else { return }
        player.play()
        player.playbackRate = rate
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func setRate(_ value: Float) {
        rate = value
        player.playbackRate = value
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, !stopped else { return }
        pendingSeek = max(0, seconds)
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard ready, !stopped, !seeking, let target = pendingSeek else { return }
        pendingSeek = nil
        seeking = true
        player.pause()
        // 清理旧时间线的显示队列，但保留最后一帧，避免快进时黑闪。
        player.videoOutput?.displayLayer.flush()
        options.seekFlags = AVSEEK_FLAG_BACKWARD
        player.seek(time: target) { [weak self] succeeded in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.seeking = false
                guard succeeded else { self.onFailure?("无法跳转到指定位置"); return }
                self.player.videoOutput?.displayLayer.flush()
                if self.pendingSeek != nil { self.performPendingSeek() }
                else if self.wantsPlay { self.play() }
            }
        }
    }

    func setFill(_ on: Bool) {
        fill = on
        player.view?.contentMode = on ? .scaleAspectFill : .scaleAspectFit
    }

    func shutdown() {
        stopped = true
        ready = false
        wantsPlay = false
        pendingSeek = nil
        onProgress = nil
        onDuration = nil
        onFinish = nil
        onFailure = nil
        player.delegate = nil
        ticker?.invalidate()
        ticker = nil
        player.pause()
        player.shutdown()
    }
}

extension FFmpegEngine: MediaPlayerDelegate {

    func readyToPlay(player: some MediaPlayerProtocol) {
        guard !stopped else { return }
        if hardwareDecode {
            guard let track = player.tracks(mediaType: .video).first(where: { $0.isEnabled }) as? FFmpegAssetTrack,
                  let format = track.formatDescription else {
                onFailure?("无法确认视频编码的硬解支持情况")
                return
            }
            guard VTIsHardwareDecodeSupported(CMFormatDescriptionGetMediaSubType(format)) else {
                onFailure?("此设备不支持 \(track.codecName) 硬解")
                return
            }
        }
        ready = true
        attachRenderViewIfNeeded()
        if duration > 0 { onDuration?(duration) }
        if pendingSeek != nil { performPendingSeek() }
        else if wantsPlay { play() }
    }

    func changeLoadState(player: some MediaPlayerProtocol) {
        attachRenderViewIfNeeded()
    }

    func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}

    func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}

    func finish(player: some MediaPlayerProtocol, error: Error?) {
        guard !stopped else { return }
        wantsPlay = false
        if let error { onFailure?(error.localizedDescription) }
        else { onFinish?() }
    }
}
