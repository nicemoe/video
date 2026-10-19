import Foundation

@main
struct ServerLifecycleTests {
    static func main() async throws {
        let server = HTTPServer()
        let ports: [UInt16] = Array(49170...49220)
        let port = try await server.start(preferredPorts: ports) { _ in .notFound }
        precondition(server.port == port)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); server.stop() }
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        precondition((response as? HTTPURLResponse)?.statusCode == 404)
        server.stop()
        precondition(server.port == 0)

        // Exercise cancellation before entry, during binding and after ready.
        for delay in [UInt64(0), 100_000, 1_000_000, 5_000_000] {
            for _ in 0..<10 {
                let pending = Task {
                    try await server.start(preferredPorts: ports) { _ in .notFound }
                }
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                pending.cancel()
                server.stop()
                do { _ = try await pending.value }
                catch is CancellationError {}
                catch { throw error }
                precondition(server.port == 0, "Cancelled startup resurrected the listener")

                // The previous listener's queued callbacks must not clear its successor.
                let next = try await server.start(preferredPorts: ports) { _ in .notFound }
                try await Task.sleep(nanoseconds: 2_000_000)
                precondition(server.port == next, "Old callback changed the new listener")
                server.stop()
            }
        }
        print("PASS: HTTP serving and 40 startup cancellation/restart cycles")
    }
}
