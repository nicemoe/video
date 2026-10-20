import Foundation

/// 共享目录可能正在被电脑写入；同一轮导入只接受状态未变化的文件。
struct DiskFileState: Equatable, Sendable {
    let bytes: Int
    let modified: Date
    let fileID: UInt64

    static func read(at url: URL) throws -> DiskFileState? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard let bytes = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let fileID = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return DiskFileState(bytes: bytes.intValue, modified: modified, fileID: fileID.uint64Value)
    }

    func matchesFile(at url: URL) throws -> Bool {
        try Self.read(at: url) == self
    }
}
