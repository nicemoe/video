import Foundation

enum PlaybackState { case playing, paused, seeking, finished }
enum ScenePhase { case active, background }
enum Mode { case once, loop, queue }
let AVSEEK_FLAG_BACKWARD: Int32 = 1
@MainActor protocol MediaPlayerProtocol {}
@MainActor final class DisplayLayer { func flush() {} }
@MainActor final class Output { let displayLayer = DisplayLayer() }
@MainActor final class Options {
    let seekDiagnostics = SeekDiagnostics()
    var seekFlags: Int32 = 0
    var isAccurateSeek = false
}
@MainActor final class Player: MediaPlayerProtocol {
    var duration = 100.0
    var currentPlaybackTime = 99.6
    var playbackState = PlaybackState.playing
    var playbackRate: Float = 1
    var videoOutput: Output? = Output()
    var seeks: [Double] = []
    var plays = 0
    var callback: ((Bool) -> Void)?
    func play() { plays += 1; playbackState = .playing }
    func pause() { playbackState = .paused }
    func seek(time: Double, completion: @escaping (Bool) -> Void) {
        seeks.append(time)
        playbackState = .seeking
        callback = completion
    }
    func completeSeek() {
        currentPlaybackTime = seeks.last!
        playbackState = .paused
        let completion = callback
        callback = nil
        completion?(true)
    }
}
@MainActor final class Engine {
    let player = Player()
    let options = Options()
    var stopped = false
    var ready = true
    var wantsPlay = true
    var hasFinishedPlayback = false
    var seeking = false
    var pendingSeek: (time: Double, accurate: Bool)?
    var rate: Float = 1
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var duration: Double { player.duration }
    /* PRODUCTION_ENGINE_TIME */
    /* PRODUCTION_ENGINE_PLAY */
    /* PRODUCTION_ENGINE_PAUSE */
    /* PRODUCTION_ENGINE_SEEK */
    /* PRODUCTION_ENGINE_PERFORM_SEEK */
    /* PRODUCTION_ENGINE_FINISH */
}
@MainActor final class Page {
    var engine: Engine?
    var scenePhase = ScenePhase.active
    var isCurrent = true
    var isPlaying = true
    var duration = 101.5 // Cached metadata can differ from decoder duration.
    var current = 0.0
    var mode = Mode.once
    var accurateSeek = false
    var onNext: (() -> Void)?
    /* PRODUCTION_PAGE_FINISH */
    /* PRODUCTION_PAGE_TOGGLE */
    /* PRODUCTION_PAGE_SEEK */
    init() {
        let engine = Engine()
        self.engine = engine
        engine.onFinish = { [weak self] in self?.finish() }
    }
    func reachEnd() {
        engine!.player.playbackState = .finished
        engine!.finish(player: engine!.player, error: nil)
        current = engine!.currentTime // Same update as the progress timer.
    }
    func tapPlay() { toggle() }
    func scrub(to time: Double) { current = time; seek(to: time) }
}
func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
@MainActor func finishSeek(_ engine: Engine) async {
    engine.player.completeSeek()
    // Let the real MainActor completion task run, with a bounded test timeout.
    for _ in 0..<100 {
        if !engine.seeking { return }
        try! await Task.sleep(nanoseconds: 1_000_000)
    }
    fatalError("Seek completion never returned to the engine")
}

@main struct ReplayButtonRegressionTests {
    @MainActor static func main() async {
        for cachedDuration in [98.0, 100.0, 101.5] {
            let page = Page()
            page.duration = cachedDuration
            let engine = page.engine!
            page.reachEnd()
            expect(!page.isPlaying, "Stop-at-end mode did not stop the button")
            page.tapPlay()
            expect(engine.player.seeks == [0], "Play after completion did not seek to zero")
            expect(engine.player.plays == 0, "Replay started before its seek completed")
            await finishSeek(engine)
            expect(engine.player.plays == 1 && engine.currentTime == 0 && page.isPlaying,
                   "Play after completion did not resume from the beginning")
        }
        let background = Page()
        background.reachEnd()
        background.engine!.pause() // Background/audio interruption must retain completion.
        expect(background.engine!.currentTime == 100, "Pause erased the completed position")
        background.tapPlay()
        expect(background.engine!.player.seeks == [0], "Pause erased replay intent")
        await finishSeek(background.engine!)

        let scrubbed = Page()
        scrubbed.reachEnd()
        scrubbed.scrub(to: 40)
        await finishSeek(scrubbed.engine!)
        scrubbed.tapPlay()
        expect(scrubbed.engine!.player.seeks == [40] && scrubbed.engine!.player.plays == 1,
               "Manual backward seek was overwritten with a restart")

        let pausedNearEnd = Page()
        pausedNearEnd.duration = 100
        pausedNearEnd.current = 99.95
        pausedNearEnd.engine!.player.currentPlaybackTime = 99.95
        pausedNearEnd.tapPlay() // Pause before EOF.
        pausedNearEnd.tapPlay()
        expect(pausedNearEnd.engine!.player.seeks.isEmpty,
               "Pausing near EOF incorrectly restarted the video")

        let cancelled = Page()
        cancelled.reachEnd()
        cancelled.tapPlay()
        cancelled.tapPlay() // Cancel play intent while the replay seek is pending.
        await finishSeek(cancelled.engine!)
        expect(!cancelled.isPlaying && cancelled.engine!.player.plays == 0,
               "Replay ignored a pause while seeking")
        cancelled.tapPlay()
        expect(cancelled.engine!.player.plays == 1 && cancelled.engine!.player.seeks == [0],
               "Paused replay needed a second seek or extra button tap")
        print("PASS: stop-at-end Play restarts at zero despite stale metadata; pause, backward seek and rapid toggles retain intent")
    }
}
