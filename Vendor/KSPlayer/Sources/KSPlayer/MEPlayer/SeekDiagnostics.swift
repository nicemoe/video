import Foundation

/// Bounded, in-memory timings for the most recent seek. No file or network I/O.
public final class SeekDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var sequence: UInt64 = 0
    private var started: TimeInterval?
    private var demuxReady = false
    private var entries: [String] = []
    private var milestones: Set<String> = []
    private var lastSamples: [String: TimeInterval] = [:]
    private let window: TimeInterval = 8
    private let limit = 160

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    @discardableResult
    public func begin(target: TimeInterval, accurate: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        started = now()
        demuxReady = false
        entries = [String(format: "seek %llu target=%.3f accurate=%@", sequence, target, String(accurate))]
        milestones.removeAll(keepingCapacity: true)
        lastSamples.removeAll(keepingCapacity: true)
        return sequence
    }

    public var token: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let started, now() - started <= window else { return nil }
        return sequence
    }

    public var mediaToken: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard demuxReady, let started, now() - started <= window else { return nil }
        return sequence
    }

    public func demuxCompleted(token: UInt64?, result: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard token == sequence, let started else { return }
        demuxReady = result >= 0
        append("demux_end result=\(result)", elapsed: now() - started)
    }

    public func mark(_ name: String, token: UInt64?, detail: @autoclosure () -> String = "") {
        lock.lock()
        defer { lock.unlock() }
        guard token == sequence, let started, now() - started <= window,
              entries.count < limit, milestones.insert(name).inserted else { return }
        append(name + " " + detail(), elapsed: now() - started)
    }

    /// At most four samples per channel per second, only during the seek window.
    public func sample(_ name: String, token: UInt64?, detail: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        guard token == sequence, demuxReady, let started, timestamp - started <= window,
              entries.count < limit else { return }
        if let last = lastSamples[name], timestamp - last < 0.25 { return }
        lastSamples[name] = timestamp
        append(name + " " + detail(), elapsed: timestamp - started)
    }

    private func append(_ message: String, elapsed: TimeInterval) {
        guard entries.count < limit else { return }
        entries.append(String(format: "%8.1f ms  %@", elapsed * 1000, message))
    }

    public func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard started != nil else { return "尚无跳转记录，请先快进一次。" }
        return entries.joined(separator: "\n")
    }
}
