import Foundation

// Only the FFmpeg ABI and log destinations are stand-ins. The runner inserts
// the production callback unchanged, with one counter before string creation.
struct AVClass { var value: Int = 0 }
struct AVFilterGraph { var opaque: UnsafeMutableRawPointer? }
struct AVFilterContext {
    var av_class: UnsafePointer<AVClass>
    var graph: UnsafeMutablePointer<AVFilterGraph>?
}
let filterClass: UnsafeMutablePointer<AVClass> = {
    let pointer = UnsafeMutablePointer<AVClass>.allocate(capacity: 1)
    pointer.initialize(to: AVClass())
    return pointer
}()
func avfilter_get_class() -> UnsafePointer<AVClass> { UnsafePointer(filterClass) }
enum LogLevel: Int32 {
    case panic = 0, fatal = 8, error = 16, warning = 24
    case info = 32, verbose = 40, debug = 48, trace = 56
}
final class KSOptions {
    static var logLevel = LogLevel.warning
    var filterMessages: [String] = []
    func filter(log: String) { filterMessages.append(log) }
}
var messages: [(LogLevel, String)] = []
var formatted = 0
func KSLog(level: LogLevel, _ message: String) {
    if level.rawValue <= KSOptions.logLevel.rawValue { messages.append((level, message)) }
}
typealias LogCallback = (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, CVaListPointer?) -> Void
var callback: LogCallback!
func av_log_set_callback(_ body: @escaping LogCallback) { callback = body }
func installCallback() {
    /* PRODUCTION_LOG_CALLBACK */
}
func emit(_ level: Int32, _ format: String = "sample=%d", context: UnsafeMutableRawPointer? = nil) {
    format.withCString { pointer in
        withVaList([Int32(42)]) { args in callback(context, level, pointer, args) }
    }
}
func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
@main struct FFmpegLogRegressionTests {
    static func main() {
        installCallback()
        let start = Date()
        for _ in 0..<1_000_000 { emit(56) }
        let elapsed = Date().timeIntervalSince(start)
        print("MP4-style trace callbacks: 1000000; formatted=\(formatted); seconds=\(elapsed)")
        if CommandLine.arguments.contains("--benchmark") { return }
        expect(formatted == 0, "Disabled index traces were formatted")
        expect(messages.isEmpty, "Suppressed traces reached the log destination")
        for level in [Int32(0), 8, 16, 24] { emit(level) }
        expect(formatted == 4 && messages.count == 4, "Enabled errors or warnings were dropped")
        expect(messages.allSatisfy { $0.1 == "sample=42" }, "C variadic formatting changed")
        KSOptions.logLevel = .trace
        emit(56)
        expect(messages.last?.0 == .trace && formatted == 5, "Explicit trace logging stopped working")
        KSOptions.logLevel = .warning
        emit(24 | 0x100)
        expect(formatted == 6 && messages.last?.0 == .warning, "FFmpeg color flags changed severity")
        callback(nil, 16, nil, nil)
        expect(formatted == 6, "Nil format was accessed")

        let options = KSOptions()
        var graph = AVFilterGraph(opaque: Unmanaged.passUnretained(options).toOpaque())
        withUnsafeMutablePointer(to: &graph) { graphPointer in
            var context = AVFilterContext(av_class: avfilter_get_class(), graph: graphPointer)
            withUnsafeMutablePointer(to: &context) { pointer in
                emit(40, "Repeated Field: sample=%d", context: UnsafeMutableRawPointer(pointer))
            }
        }
        expect(options.filterMessages == ["Repeated Field: sample=42"], "Filter analysis lost its messages")
        expect(formatted == 7 && messages.count == 6, "Filter messages bypassed console verbosity")
        print("PASS: disabled trace formatting eliminated, warning/error formatting, opt-in trace, filter consumers and severity flags")
    }
}
