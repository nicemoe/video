import Foundation

@main struct SeekDiagnosticsTests {
    static func check(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func main() {
        var clockReads = 0
        var stringBuilds = 0
        let disabled = SeekDiagnostics(now: { clockReads += 1; return 100 })
        func diagnosticText() -> String { stringBuilds += 1; return "unused" }
        check(!disabled.isEnabled, "Diagnostics enabled by default")
        for _ in 0..<10_000 {
            let token = disabled.begin(target: 1002.8, accurate: false)
            check(token == nil && disabled.token == nil && disabled.mediaToken == nil,
                  "Disabled diagnostics produced a generation")
            disabled.demuxCompleted(token: token, result: 0)
            disabled.mark(diagnosticText(), token: token, detail: diagnosticText())
            disabled.sample(diagnosticText(), token: token, detail: diagnosticText())
        }
        check(clockReads == 0 && stringBuilds == 0 && disabled.report().isEmpty,
              "Disabled diagnostics collected timings, formatted strings or retained a report")
        print("PASS: diagnostics off by default; no clock reads, string formatting or recorded events")
        var clock = 100.0
        let trace = SeekDiagnostics(enabled: true, now: { clock })
        check(trace.token == nil && trace.mediaToken == nil, "Trace started before a seek")
        let first = trace.begin(target: 1002.8, accurate: false)
        trace.mark("demux_start", token: first)
        check(trace.mediaToken == nil, "Old timeline frames were eligible")
        clock += 0.125
        trace.demuxCompleted(token: first, result: 0)
        check(trace.mediaToken == first, "New timeline was not enabled")
        trace.mark("video_queued", token: first, detail: "pts=1001.768")
        trace.mark("video_queued", token: first, detail: "duplicate")
        for _ in 0..<1000 { trace.sample("clock", token: first, detail: "main=1001") }
        check(!trace.report().contains("duplicate"), "Milestone duplicated")
        check(trace.report().components(separatedBy: "clock main").count == 2, "Samples were not throttled")
        let second = trace.begin(target: 600, accurate: true)
        trace.mark("stale", token: first)
        trace.demuxCompleted(token: first, result: 0)
        check(trace.mediaToken == nil && !trace.report().contains("stale"), "Old seek polluted new trace")
        trace.demuxCompleted(token: second, result: 0)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            trace.mark("event-\(index)", token: second)
        }
        check(trace.report().split(separator: "\n").count <= 160, "Trace exceeded memory bound")
        clock += 9
        check(trace.token == nil && trace.mediaToken == nil, "Trace continued after window")
        trace.mark("expired", token: second)
        check(!trace.report().contains("expired"), "Expired event recorded")
        check(trace.report().contains("target=600.000 accurate=true"), "Report lost the selected seek mode")
        print("PASS: bounded seek diagnostics, timing, stale generation rejection, sampling and concurrent writes")
    }
}
