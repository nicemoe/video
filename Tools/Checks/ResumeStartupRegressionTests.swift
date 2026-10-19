import Foundation

// Devices and SwiftUI storage are replaced; start/seek bodies below are production code.
enum DecoderChoice { case auto, hardware, software }
enum ScenePhase { case active, background }
struct Asset { let duration = 2722.133 }
enum LibraryStore {
    static func fileURL(for asset: Asset) -> URL { URL(fileURLWithPath: "/fixture.wmv") }
}
final class AVAudioSession {
    enum Category { case playback }
    static let session = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { session }
    func setCategory(_ category: Category) throws {}
    func setActive(_ active: Bool) throws {}
}
protocol VideoEngine: AnyObject {
    var onProgress: ((Double) -> Void)? { get set }
    var onDuration: ((Double) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func setRate(_ rate: Float)
    func setFill(_ fill: Bool)
    func seek(to seconds: Double, accurate: Bool)
    func play()
    func shutdown()
}
final class FFmpegEngine: VideoEngine {
    var onProgress: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var requests: [(Double, Bool)] = []
    var events: [String] = []
    init(url: URL, hardwareDecode: Bool) {}
    func setRate(_ rate: Float) {}
    func setFill(_ fill: Bool) {}
    func seek(to seconds: Double, accurate: Bool) {
        requests.append((seconds, accurate)); events.append("seek")
    }
    func play() { events.append("play") }
    func shutdown() {}
}
@propertyWrapper struct Stored<Value> {
    final class Storage {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }
}
struct Page {
    enum DragMode { case seek }
    @Stored var engine: (any VideoEngine)? = nil
    @Stored var failed = false
    @Stored var failureMessage = ""
    @Stored var asset = Asset()
    @Stored var running = DecoderChoice.auto
    @Stored var initialDecoder = DecoderChoice.software
    @Stored var decoderPolicy = DecoderChoice.auto
    @Stored var scrubbing = false
    @Stored var dragMode: DragMode? = nil
    @Stored var current = 0.0
    @Stored var duration = 0.0
    @Stored var rate: Float = 1
    @Stored var fill = false
    @Stored var startAt = 0.0
    @Stored var announceResume = true
    @Stored var scenePhase = ScenePhase.active
    @Stored var isPlaying = false
    @Stored var accurateSeek = false
    func finish() {}
    func switchTo(_ choice: DecoderChoice, remember: Bool, announce: Bool) {}
    func show(hint: String) {}
    func timeText(_ time: Double) -> String { String(time) }
    /* PRODUCTION_START */
    /* PRODUCTION_PAGE_SEEK */
    func open(from time: Double? = nil) { start(from: time) }
    func scrub(to time: Double) { seek(to: time) }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
@main struct ResumeStartupRegressionTests {
    static func main() {
        for accurate in [false, true] {
            let page = Page()
            page.startAt = 1361.725
            page.accurateSeek = accurate
            page.open()
            let engine = page.engine as! FFmpegEngine
            expect(engine.requests.count == 1, "Resume did not issue exactly one seek")
            expect(engine.requests[0].0 == 1361.725, "Resume lost the saved position")
            expect(engine.requests[0].1 == accurate, "Resume ignored the seek preference")
            expect(engine.events == ["seek", "play"], "Resume played before requesting the saved position")
            page.scrub(to: 1700.125)
            expect(engine.requests.last!.1 == engine.requests[0].1, "Resume and scrub use different seek policies")
            page.open()
            expect(engine.requests.count == 2, "Existing engine was reopened")

            let rebuilt = Page()
            rebuilt.startAt = 30
            rebuilt.accurateSeek = accurate
            rebuilt.open(from: 1361.725)
            let rebuiltEngine = rebuilt.engine as! FFmpegEngine
            expect(rebuiltEngine.requests[0].0 == 1361.725 && rebuiltEngine.requests[0].1 == accurate,
                   "Rebuilt playback did not retain current position and seek policy")
        }
        let background = Page()
        background.startAt = 1361.725
        background.scenePhase = .background
        background.open()
        expect((background.engine as! FFmpegEngine).events == ["seek"], "Background resume started playback")
        let beginning = Page()
        beginning.open()
        expect((beginning.engine as! FFmpegEngine).events == ["play"], "Fresh playback introduced a seek")
        print("PASS: production startup resumes saved progress using the same seek policy as scrubbing; rebuild and background behavior")
    }
}
