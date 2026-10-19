import Foundation

private struct Failure: Error { let message: String }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}

private func readBody(_ response: HTTPResponse) throws -> Data {
    guard let file = response.fileBody else { return response.body }
    var result = Data()
    while let chunk = try file.readChunk() {
        try expect(chunk.count <= HTTPFileBody.chunkSize, "File chunk exceeds memory bound")
        result.append(chunk)
    }
    return result
}

@main
struct CoreRegressionTests {
    struct Snapshot: Codable, Sendable { let value: Int }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 实际读取大于旧 4 MB 上限的文件，验证完整内容以及每次读取上限。
        let source = Data((0..<(6 * 1024 * 1024 + 37)).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("large.bin")
        try source.write(to: file)
        let whole = HTTPResponse.file(file, type: "application/octet-stream", range: nil)
        try expect(whole.status == 200, "GET without Range must return 200")
        let headers = String(decoding: whole.serialized(keepAlive: true), as: UTF8.self)
        try expect(headers.contains("Content-Length: \(source.count)\r\n"), "Wrong full response length")
        try expect(try readBody(whole) == source, "Large GET was truncated or corrupted")

        for (range, expected) in [
            ("bytes=17-31", source.subdata(in: 17..<32)),
            ("bytes=100-", source.subdata(in: 100..<source.count)),
            ("bytes=-19", Data(source.suffix(19))),
            ("bytes=0-999999999", source)
        ] {
            let response = HTTPResponse.file(file, type: "video/mp4", range: range)
            try expect(response.status == 206, "Valid Range must return 206")
            try expect(try readBody(response) == expected, "Incorrect Range payload: \(range)")
        }
        for range in ["bytes=999999999-", "bytes=30-10", "bytes=-0", "bytes=x-9", "bytes=0-1,4-5", "foo=0-5"] {
            let response = HTTPResponse.file(file, type: "video/mp4", range: range)
            try expect(response.status == 416, "Invalid Range accepted: \(range)")
        }
        let empty = root.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let emptyResponse = HTTPResponse.file(empty, type: "application/octet-stream", range: nil)
        try expect(emptyResponse.status == 200, "Empty file rejected")
        try expect(try readBody(emptyResponse).isEmpty, "Empty file returned content")

        let shrinking = HTTPResponse.file(file, type: "video/mp4", range: nil)
        let truncate = try FileHandle(forWritingTo: file)
        try truncate.truncate(atOffset: 20)
        try truncate.close()
        do {
            _ = try readBody(shrinking)
            throw Failure(message: "Truncated file was treated as a successful response")
        } catch is CocoaError { }
        print("PASS: full file streaming, Range and read failures")

        // 跨多个读取块的 multipart，以及缺失尾部分隔符、写入路径失败。
        let payload = Data(repeating: 0x61, count: 700_003)
        var multipart = Data("--test-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sample.mp4\"\r\n\r\n".utf8)
        multipart.append(payload)
        multipart.append(Data("\r\n--test-boundary--\r\n".utf8))
        let request = root.appendingPathComponent("request.bin")
        try multipart.write(to: request)
        let parts = try MultipartStream.parse(fileURL: request, boundary: "test-boundary",
                                               into: root.appendingPathComponent("parts"))
        try expect(parts.count == 1 && parts[0].byteCount == payload.count, "Multipart size mismatch")
        try expect(try Data(contentsOf: parts[0].fileURL) == payload, "Multipart payload mismatch")
        try Data(multipart.dropLast(15)).write(to: request)
        do {
            _ = try MultipartStream.parse(fileURL: request, boundary: "test-boundary",
                                          into: root.appendingPathComponent("broken"))
            throw Failure(message: "Truncated multipart accepted")
        } catch is CocoaError { }
        do {
            _ = try MultipartStream.parse(fileURL: request, boundary: "test-boundary", into: empty)
            throw Failure(message: "Multipart destination error ignored")
        } catch is CocoaError { }
        print("PASS: multipart streaming, truncation and destination failures")

        let saved = root.appendingPathComponent("library.json")
        let writer = SnapshotWriter(url: saved)
        try await writer.write(Snapshot(value: 2), revision: 2)
        try await writer.write(Snapshot(value: 1), revision: 1)
        var value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: saved))
        try expect(value.value == 2, "Late old snapshot replaced newer data")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 3...100 {
                group.addTask { try await writer.write(Snapshot(value: revision), revision: UInt64(revision)) }
            }
            try await group.waitForAll()
        }
        value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: saved))
        try expect(value.value == 100, "Concurrent snapshots were persisted out of order")
        let badWriter = SnapshotWriter(url: root.appendingPathComponent("missing/library.json"))
        do {
            try await badWriter.write(Snapshot(value: 1), revision: 1)
            throw Failure(message: "Snapshot write failure was ignored")
        } catch is CocoaError { }
        print("PASS: ordered snapshots, concurrent updates and write failures")
    }
}
