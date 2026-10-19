// The runner inserts the current production methods at the markers below.
// Audio/display devices and demux completion are controlled to test event order.
import AVFoundation

/* PRODUCTION_CAPACITY_TYPES */

enum MediaLoadState { case idle, loading, playable }
enum MediaPlaybackState { case idle, seeking, playing, paused, finished }
enum SourceState { case reading, paused, seeking }
var events: [String] = []
func runOnMainThread(_ body: () -> Void) { body() }
func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

open class TestOptions {
    var preferredForwardBufferDuration = 3.0
    var maxBufferDuration = 30.0
    var isSeekReadyOnFrames = true
    var syncDecodeVideo = false
    var syncDecodeAudio = false
    var isSecondOpen = false
    var isLoopPlay = false
    func liveAdaptivePlaybackRate(loadingState: LoadingState) -> Float? { nil }
    /* PRODUCTION_PLAYABLE */
}

struct Capacity: CapacityProtocol {
    let mediaType: AVMediaType
    var frameCount: Int
    var packetCount: Int = 120
    var fps: Float = 30
    var frameMaxCount: Int = 8
    var isEndOfFile = false
}

final class AudioDevice {
    var running = false
    var flushes = 0
    func play() { running = true; events.append("audio") }
    func pause() { running = false }
    func flush() { flushes += 1 }
}
final class DisplayLayer {
    var controlTimebase: CMTimebase?
    init() {
        expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase) == noErr,
            "Cannot create test timebase")
    }
}
final class VideoDevice {
    let displayLayer = DisplayLayer()
    var pixelBuffer: Int? = 1
    var previews = 0
    var running = false
    func play() { running = true }
    func pause() { running = false }
    func readNextFrame() { previews += 1; events.append("video") }
}
final class Delegate {
    func changeLoadState(player: TestPlayer) {}
    func finish(player: TestPlayer, error: Error?) {}
}

final class TestItem {
    var options = TestOptions()
    weak var delegate: TestPlayer?
    var state = SourceState.reading
    var isFirst = false
    var isSeek = false
    var currentTime = 5.0
    var target = 0.0
    var completion: ((Bool) -> Void)?
    var videoAudioTracks: [CapacityProtocol] = []
    func seek(time: TimeInterval, completion: @escaping (Bool) -> Void) {
        target = time
        state = .seeking
        self.completion = completion
    }
    func finishSeek() {
        currentTime = target
        isSeek = true
        state = .reading
        let callback = completion
        completion = nil
        callback?(true)
    }
    func pause() { state = .paused }
    func resume() { if state == .paused { state = .reading } }
    func adaptableVideo(loadingState: LoadingState) {}
    func frames(audio: Int, video: Int) {
        videoAudioTracks = [Capacity(mediaType: .audio, frameCount: audio),
                            Capacity(mediaType: .video, frameCount: video)]
    }
    /* PRODUCTION_CAPACITY_UPDATE */
}

final class TestPlayer {
    let options = TestOptions()
    let audioOutput = AudioDevice()
    var videoOutput: VideoDevice? = VideoDevice()
    let playerItem = TestItem()
    var delegate: Delegate? = Delegate()
    var duration = 2722.133
    var currentPlaybackTime: Double { playerItem.currentTime }
    var bufferingProgress = 0
    var playableTime = 0.0
    var playbackRate: Float = 1
    /* PRODUCTION_LOAD_STATE */
    /* PRODUCTION_PLAYBACK_STATE */
    /* PRODUCTION_PLAY_OR_PAUSE */
    /* PRODUCTION_SEEK */
    /* PRODUCTION_LOADING_UPDATE */
    init() {
        playerItem.options = options
        playerItem.delegate = self
        playbackState = .playing
        loadState = .playable
    }
    func play() { playbackState = .playing }
    func pause() { playbackState = .paused }
}

@main struct SeekReadinessRegressionTests {
    static func main() {
        for n in 0..<100 {
            let player = TestPlayer()
            let item = player.playerItem
            item.frames(audio: 8, video: 8)
            player.seek(time: 1002.75 + Double(n)) { success in
                expect(success, "Seek failed")
                player.play()
            }
            expect(player.loadState == .loading, "Seek reused old playable state")
            expect(!player.audioOutput.running, "Audio was not paused at seek start")
            // Timer samples old full queues before the demux thread finishes.
            item.codecDidChangeCapacity()
            expect(player.loadState == .loading, "Old queues made the new seek playable")
            item.frames(audio: 0, video: 0)
            item.finishSeek()
            expect(!player.audioOutput.running, "Demux completion started audio before video was decoded")
            let time = CMTimebaseGetTime(player.videoOutput!.displayLayer.controlTimebase!).seconds
            expect(abs(time - (1002.75 + Double(n))) < 0.00001, "Seek truncated fractional display time")
            // Audio is ready first, with many video packets but no decoded video.
            for videoFrames in 0...1 {
                item.frames(audio: 8, video: videoFrames)
                item.codecDidChangeCapacity()
                expect(!player.audioOutput.running && item.isSeek,
                       "Audio started while video was still preparing")
            }
            events = []
            item.frames(audio: 8, video: 2)
            item.codecDidChangeCapacity()
            expect(player.audioOutput.running && player.videoOutput!.running,
                   "Ready audio/video did not resume together")
            expect(events == ["video", "audio"], "Target picture must be submitted before audio resumes")
            expect(!item.isSeek, "Ready seek state was not cleared")
        }
        let paused = TestPlayer()
        paused.pause()
        paused.seek(time: 60.2) { _ in paused.pause() }
        paused.playerItem.finishSeek()
        paused.playerItem.frames(audio: 2, video: 2)
        paused.playerItem.codecDidChangeCapacity()
        expect(!paused.audioOutput.running && !paused.videoOutput!.running,
               "Paused seek started playback")
        expect(paused.videoOutput!.previews == 1, "Paused seek did not show target frame")
        let audioOnly = TestPlayer()
        audioOnly.videoOutput = nil
        audioOnly.seek(time: 60) { _ in audioOnly.play() }
        audioOnly.playerItem.finishSeek()
        audioOnly.playerItem.videoAudioTracks = [Capacity(mediaType: .audio, frameCount: 2)]
        audioOnly.playerItem.codecDidChangeCapacity()
        expect(audioOnly.audioOutput.running, "Audio-only seek incorrectly waited for video")
        print("PASS: 100 seek readiness schedules, no audio before target video, paused preview, fractional timebase and audio-only playback")
    }
}
