import Foundation
import Darwin
import CryptoKit

private final class HTTPClient {
    private let fd: Int32
    private var buffered = Data()

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        precondition(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        precondition(setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        var noSignal: Int32 = 1
        precondition(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4) == 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0, "Client connect failed")
    }

    deinit { Darwin.close(fd) }

    func send(_ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                precondition(count > 0, "Client send failed")
                offset += count
            }
        }
    }

    func response() -> String {
        let delimiter = Data("\r\n\r\n".utf8)
        while buffered.range(of: delimiter) == nil { receive() }
        let headerEnd = buffered.range(of: delimiter)!.upperBound
        let header = String(decoding: buffered[..<headerEnd], as: UTF8.self)
        precondition(header.hasPrefix("HTTP/1.1 200"), header)
        let line = header.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length:") }!
        let length = Int(line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces))!
        buffered.removeSubrange(..<headerEnd)
        while buffered.count < length { receive() }
        let body = String(decoding: buffered.prefix(length), as: UTF8.self)
        buffered.removeFirst(length)
        return body
    }

    private func receive() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.recv(fd, &bytes, bytes.count, 0)
        precondition(count > 0, "Response stalled or connection closed")
        buffered.append(contentsOf: bytes.prefix(count))
    }
}

private actor UploadedFiles {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

@main
struct UploadTransportTests {
    static func main() async throws {
        let server = HTTPServer()
        let files = UploadedFiles()
        let block = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 * 31) })
        var payload = Data()
        for _ in 0..<513 { payload.append(block) }
        payload.append(Data([0xDA, 0x7A, 0x01]))
        let expectedDigest = SHA256.hash(data: payload).description
        let expectedSize = payload.count
        let smallVideo = Data(payload.prefix(2 * 1024 * 1024 + 7))
        let port = try await server.start(preferredPorts: Array(49221...49270)) { request in
            if request.path == "/ping" { return .text("pong") }
            if request.path == "/small" {
                precondition(request.bodyFile == nil && request.body == Data("abc".utf8))
                return .text("small")
            }
            if request.path == "/small-video" {
                precondition(request.bodyFile == nil && request.body == smallVideo)
                return .text("video saved")
            }
            precondition(request.path == "/upload")
            precondition(request.body.isEmpty, "Large upload entered in-memory request path")
            let url = request.bodyFile!
            await files.record(url)
            let bytes = try! Data(contentsOf: url)
            precondition(bytes.count == expectedSize)
            precondition(SHA256.hash(data: bytes).description == expectedDigest, "Upload bytes corrupted")
            return .text("saved")
        }
        defer { server.stop() }
        let uploadBytes = payload
        try await Task.detached {
            let client = try HTTPClient(port: port)
            // Fragment the header so body batching cannot delay header parsing.
            client.send(Data("POST /upload HTTP/1.1\r\nContent-Len".utf8))
            Thread.sleep(forTimeInterval: 0.01)
            client.send(Data("gth: \(expectedSize)\r\n\r\n".utf8))
            client.send(uploadBytes.prefix(16_384))
            // An incomplete upload must not block another connection.
            let other = try HTTPClient(port: port)
            other.send(Data("GET /ping HTTP/1.1\r\n\r\n".utf8))
            precondition(other.response() == "pong")
            let start = Date()
            for offset in stride(from: 16_384, to: uploadBytes.count - 3, by: 16_384) {
                client.send(uploadBytes.subdata(in: offset..<(offset + 16_384)))
            }
            // Deliberately send a tail shorter than the minimum batch size.
            Thread.sleep(forTimeInterval: 0.02)
            client.send(uploadBytes.suffix(3))
            precondition(client.response() == "saved", "Tail waited for nonexistent bytes")
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "INFO: loopback upload %.1f MiB/s (not a Wi-Fi speed measurement)",
                         Double(expectedSize) / 1_048_576 / elapsed))
            client.send(Data("POST /small HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc".utf8))
            precondition(client.response() == "small", "Keep-alive body parsing failed")
            client.send(Data("GET /ping HTTP/1.1\r\n\r\n".utf8))
            precondition(client.response() == "pong", "Keep-alive header remained in batching mode")
            let smallStart = Date()
            client.send(Data("POST /small-video HTTP/1.1\r\nContent-Length: \(smallVideo.count)\r\n\r\n".utf8))
            client.send(smallVideo)
            precondition(client.response() == "video saved")
            print(String(format: "INFO: 2 MiB loopback upload completed in %.3f seconds",
                         Date().timeIntervalSince(smallStart)))
        }.value
        let saved = await files.urls
        precondition(saved.count == 1)
        precondition(!FileManager.default.fileExists(atPath: saved[0].path), "Completed upload temp file leaked")
        print("PASS: fragmented large upload, exact SHA256, short final tail, concurrent request, keep-alive and cleanup")
    }
}
