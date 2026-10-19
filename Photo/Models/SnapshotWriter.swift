import Foundation

/// 所有快照在同一个 actor 内编码、落盘；迟到的旧版本不能覆盖新版本。
actor SnapshotWriter {
    private let url: URL
    private var latestRevision: UInt64 = 0

    init(url: URL) { self.url = url }

    func write<Value: Encodable>(_ value: Value, revision: UInt64) throws {
        guard revision > latestRevision else { return }
        latestRevision = revision
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
