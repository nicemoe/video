import Foundation
import KSPlayer

/// 音画同步只丢已经解码的显示帧，保留后续解码所需的参考数据。
final class ReferenceSafePlaybackOptions: KSOptions {
    override func videoClockSync(main: KSClock, nextVideoTime: TimeInterval,
                                 fps: Double, frameCount: Int) -> (Double, ClockProcessType) {
        let (difference, action) = super.videoClockSync(
            main: main, nextVideoTime: nextVideoTime, fps: fps, frameCount: frameCount)
        switch action {
        case .dropNextPacket, .dropGOPPacket:
            // KSPlayer 2.3.4 以 !isKeyFrame 丢压缩包，但 P 帧也可能是参考帧。
            // 队列暂时为空时丢 GOP 会停在中途，后续 P 帧会缺少参考图像。
            return (difference, .dropNextFrame)
        default:
            return (difference, action)
        }
    }
}
