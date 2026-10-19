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
    let seekDiagnostics = SeekDiagnostics()
    var preferredForwardBufferDuration = 3.0
    var maxBufferDuration = 30.0
    var isAccurateSeek = false
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

/* PRODUCTION_AUDIO_MODEL */
extension AVAudioFormat {
    var sampleSize: UInt32 { streamDescription.pointee.mBytesPerFrame }
}
typealias TestFrame = AudioFrame
extension AudioFrame {
    convenience init(timestamp: Int64, duration: Int64) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 2, interleaved: false)!
        self.init(dataSize: Int(duration) * 48 * 4, audioFormat: format)
        self.timestamp = timestamp
        self.duration = duration
        timebase = Timebase(num: 1, den: 1000)
        numberOfSamples = UInt32(duration * 48)
        for buffer in data { buffer?.initialize(repeating: 0, count: dataSize) }
    }
}
final class TestTrack: CapacityProtocol {
    let outputRenderQueue = CircularBuffer<TestFrame>()
    var seekTime = 0.0
    var mediaType: AVMediaType
    var frameCount: Int { outputRenderQueue.count }
    var packetCount = 100
    var fps: Float = 48
    var frameMaxCount = 32
    var isEndOfFile = false
    init(_ mediaType: AVMediaType) { self.mediaType = mediaType }
    /* PRODUCTION_DISCARD_FRAMES */
}
struct TestClock { var time = CMTime.zero }

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
    var videoTrack: TestTrack?
    var audioTrack: TestTrack?
    var audioClock = TestClock()
    var videoClock = TestClock()
    /* PRODUCTION_PREPARE_SEEK_OUTPUT */
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
    init(initialLoadState: MediaLoadState = .playable) {
        playerItem.options = options
        playerItem.delegate = self
        playbackState = .playing
        loadState = initialLoadState
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
        // Replay the build-12 phone trace: video is ready at 1085.785, but ASF
        // delivers audio from 1083.519. That audio previously froze video ~2.25s.
        // WMA decoded blocks can span hundreds of milliseconds. Exercise actual
        // production PCM buffers: both channel layouts, formats and sample rates.
        for rate in [44100.0, 48000.0] {
            for interleaved in [false, true] {
                for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
                    let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: rate,
                                               channels: 2, interleaved: interleaved)!
                    let samples = Int(rate * 0.371)
                    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                    let frame = AudioFrame(dataSize: samples * bytesPerFrame, audioFormat: format)
                    frame.numberOfSamples = UInt32(samples)
                    frame.timebase = Timebase(num: 1, den: 1000)
                    frame.timestamp = 1085587
                    frame.duration = 371
                    var originals: [[UInt8]] = []
                    for (channel, pointer) in frame.data.enumerated() {
                        let bytes = (0..<frame.dataSize).map { UInt8(($0 + channel * 13) % 251) }
                        bytes.withUnsafeBufferPointer { pointer!.initialize(from: $0.baseAddress!, count: bytes.count) }
                        originals.append(bytes)
                    }
                    let originalStart = CMTimeConvertScale(frame.cmtime, timescale: Int32(rate), method: .roundHalfAwayFromZero).value
                    expect(frame.trim(before: 1085.785), "Crossing PCM block was discarded")
                    let removed = Int(frame.timestamp - originalStart)
                    expect(frame.seconds >= 1085.785 && frame.seconds - 1085.785 < 1 / rate,
                           "PCM did not begin at the video origin within one sample")
                    expect(Int(frame.numberOfSamples) == samples - removed, "PCM sample count was not trimmed")
                    expect(frame.dataSize == (samples - removed) * bytesPerFrame, "PCM byte size was not trimmed")
                    expect(frame.duration == Int64(frame.numberOfSamples), "PCM duration lost sample precision")
                    for (channel, pointer) in frame.data.enumerated() {
                        let actual = Array(UnsafeBufferPointer(start: pointer!, count: frame.dataSize))
                        expect(actual == Array(originals[channel][(removed * bytesPerFrame)...]),
                               "PCM channel data was corrupted by overlapping copy")
                    }
                    let remaining = frame.numberOfSamples
                    expect(frame.trim(before: 1085.785) && frame.numberOfSamples == remaining, "PCM trim was not idempotent")
                    expect(!frame.trim(before: 1086), "Wholly pre-origin PCM was retained")
                }
            }
        }
        print("PASS: sample-accurate PCM trim, planar/interleaved stereo, 44.1/48 kHz and Float32/Int16")
        for firstOpen in [false, true] {
            let fast = TestPlayer()
            let item = fast.playerItem
            item.isFirst = firstOpen
            fast.videoOutput?.pixelBuffer = firstOpen ? nil : 1
            let video = TestTrack(.video)
            let audio = TestTrack(.audio)
            item.videoTrack = video
            item.audioTrack = audio
            item.videoAudioTracks = [video, audio]
            fast.seek(time: 1088.853) { _ in fast.play() }
            item.finishSeek()
            for timestamp in [Int64(1085785), 1085819] {
                video.outputRenderQueue.push(TestFrame(timestamp: timestamp, duration: 34))
            }
            // Audio queue fills with preroll first. It must be drained without
            // starting the outputs; later decode uses the newly installed boundary.
            for index in 0..<32 {
                audio.outputRenderQueue.push(TestFrame(timestamp: 1083519 + Int64(index) * 22, duration: 22))
            }
            item.codecDidChangeCapacity()
            expect(audio.frameCount == 0, "Audio preroll survived fast seek")
            expect(fast.videoOutput!.previews == 0, "Resume consumed target video before aligned audio was ready")
            expect(video.outputRenderQueue.count == 2, "Resume lost its first queued video frames")
            expect(!fast.audioOutput.running && item.isSeek, "Audio resumed before aligned frames were ready")
            expect(abs(audio.seekTime - 1085.785) < 0.000001, "Future audio preroll was not filtered")
            // Keep only the samples at/after the video origin in the crossing block.
            for timestamp in [Int64(1085775), 1085797, 1085819] {
                audio.outputRenderQueue.push(TestFrame(timestamp: timestamp, duration: 22))
            }
            events = []
            item.codecDidChangeCapacity()
            expect(events == ["video", "audio"], "Aligned output order changed")
            expect(abs(audio.outputRenderQueue.first!.seconds - 1085.785) <= 1.0 / 48000, "Overlapping audio block was not trimmed")
            expect(abs(item.audioClock.time.seconds - 1085.785) < 0.000001,
                   "Audio clock kept the requested position instead of the actual keyframe")
            expect(item.audioClock.time == item.videoClock.time, "Seek clocks have different origins")
            let firstAudio = audio.outputRenderQueue.first!.seconds
            expect(video.outputRenderQueue.first!.seconds - firstAudio < 0.022,
                   "Phone trace would still wait seconds for audio")
            // A second, backward seek selects its own origin, not the previous one.
            video.outputRenderQueue.flush()
            audio.outputRenderQueue.flush()
            audio.seekTime = 0
            fast.seek(time: 600.5) { _ in fast.play() }
            item.finishSeek()
            for timestamp in [Int64(599566), 599600] {
                video.outputRenderQueue.push(TestFrame(timestamp: timestamp, duration: 34))
            }
            for timestamp in [Int64(597300), 599560, 599582] {
                audio.outputRenderQueue.push(TestFrame(timestamp: timestamp, duration: 22))
            }
            item.codecDidChangeCapacity()
            expect(abs(audio.outputRenderQueue.first!.seconds - 599.566) <= 1.0 / 48000, "Backward seek kept old preroll")
            expect(abs(item.audioClock.time.seconds - 599.566) < 0.000001, "Backward seek kept old clock")
            // Accurate seeks already filter against their requested target. Do not
            // replace that target with a keyframe; audio-only playback has no video anchor.
            fast.options.isAccurateSeek = true
            fast.seek(time: 700) { _ in fast.play() }
            item.finishSeek()
            audio.seekTime = 700
            let count = audio.frameCount
            item.codecDidChangeCapacity()
            expect(audio.seekTime == 700 && audio.frameCount == count, "Accurate seek was realigned")
        }
        print("PASS: 100 seek readiness schedules, no audio before target video, paused preview, fractional timebase and audio-only playback")
        // High-bitrate local files should start with decoded audio/video,
        // without requiring three seconds of compressed packets first.
        let startupOptions = TestOptions()
        let readyFrames: [CapacityProtocol] = [
            Capacity(mediaType: .audio, frameCount: 2, packetCount: 0),
            Capacity(mediaType: .video, frameCount: 2, packetCount: 0)
        ]
        expect(!startupOptions.playable(capacitys: readyFrames, isFirst: true, isSeek: false).isPlayable,
               "Network startup buffering was bypassed")
        startupOptions.isSecondOpen = true
        expect(startupOptions.playable(capacitys: readyFrames, isFirst: true, isSeek: false).isPlayable,
               "Local startup still waits for three seconds of packets")
        expect(!startupOptions.playable(capacitys: readyFrames, isFirst: false, isSeek: false).isPlayable,
               "Local startup policy changed ordinary rebuffering")
        for missingTrack in [AVMediaType.audio, .video] {
            for count in 0...1 {
                let incomplete: [CapacityProtocol] = [
                    Capacity(mediaType: .audio, frameCount: missingTrack == .audio ? count : 2, packetCount: 0),
                    Capacity(mediaType: .video, frameCount: missingTrack == .video ? count : 2, packetCount: 0)
                ]
                expect(!startupOptions.playable(capacitys: incomplete, isFirst: true, isSeek: false).isPlayable,
                       "Local startup began before both tracks were decoded")
            }
        }
        print("PASS: local startup with decoded frames, waits for both tracks, network and rebuffer policies unchanged")
        let normalOpen = TestPlayer(initialLoadState: .loading)
        normalOpen.playerItem.isFirst = true
        normalOpen.videoOutput?.pixelBuffer = nil
        normalOpen.playerItem.frames(audio: 0, video: 1)
        normalOpen.playerItem.codecDidChangeCapacity()
        expect(normalOpen.videoOutput!.previews == 1, "Ordinary first open lost its early preview")
        print("PASS: ASF audio preroll alignment on both first-open resume and in-session seek, shared clocks and backward seek")
    }
}
