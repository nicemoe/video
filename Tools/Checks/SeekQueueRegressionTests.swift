import Foundation

// CircularBuffer only uses timestamp from the media model. Keep this test free
// of FFmpeg/AVFoundation while compiling the actual vendored queue unchanged.
public protocol ObjectQueueItem { var timestamp: Int64 { get set } }
private struct Packet: ObjectQueueItem { var timestamp: Int64 }
private struct Failure: Error { let message: String }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}

@main
struct SeekQueueRegressionTests {
    static func main() throws {
        let packets = CircularBuffer<Packet>()
        let beforeSeek = packets.generation
        packets.flush()
        packets.push(Packet(timestamp: 1001768))
        try expect(packets.pop(wait: true, generation: beforeSeek) == nil,
                   "An interrupted read consumed the first packet after seek")
        var needsFlush = true
        try expect(packets.pop(wait: true, where: { _, _ in !needsFlush }) == nil,
                   "Pending decoder flush consumed a keyframe")
        try expect(packets.count == 1, "Keyframe disappeared while decoder reset was pending")
        needsFlush = false
        try expect(packets.pop(where: { _, _ in !needsFlush })?.timestamp == 1001768,
                   "Decoder did not receive the retained first keyframe")

        let output = CircularBuffer<Packet>()
        let decodingGeneration = packets.generation
        packets.flush()
        output.flush()
        output.push(Packet(timestamp: 9999999), if: { packets.generation == decodingGeneration })
        try expect(output.pop() == nil, "Old in-flight decode published into the new timeline")
        let currentGeneration = packets.generation
        output.push(Packet(timestamp: 1002000), if: { packets.generation == currentGeneration })
        try expect(output.pop()?.timestamp == 1002000, "Current output was rejected")

        // Exercise both schedules: flush before pop starts, and flush while pop waits.
        // Either way, the old read must leave the new keyframe available.
        for index in 0..<300 {
            let queue = CircularBuffer<Packet>()
            let entered = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let result = CircularBuffer<Packet>()
            DispatchQueue.global().async {
                let generation = queue.generation
                entered.signal()
                if let item = queue.pop(wait: true, generation: generation) { result.push(item) }
                finished.signal()
            }
            try expect(entered.wait(timeout: .now() + 5) == .success, "Consumer did not start")
            queue.flush()
            queue.push(Packet(timestamp: Int64(index)))
            try expect(finished.wait(timeout: .now() + 5) == .success, "Seek did not wake consumer")
            try expect(result.pop() == nil, "Old wait consumed new generation")
            try expect(queue.pop()?.timestamp == Int64(index), "Seek lost first packet under contention")
            queue.shutdown()
        }
        print("PASS: first seek keyframe retained, stale decode rejected, 300 concurrent seek/wait schedules")
    }
}
