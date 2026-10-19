import Foundation

/// 由连接队列独占读取。每发送完一块才读取下一块，内存不随文件大小增长。
final class HTTPFileBody {
    static let chunkSize = 128 * 1024
    let length: Int
    private let handle: FileHandle
    private var remaining: Int

    init(handle: FileHandle, length: Int) {
        self.handle = handle
        self.length = length
        remaining = length
    }

    deinit { try? handle.close() }

    func readChunk() throws -> Data? {
        guard remaining > 0 else { return nil }
        guard let data = try handle.read(upToCount: min(Self.chunkSize, remaining)),
              !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        remaining -= data.count
        return data
    }
}
