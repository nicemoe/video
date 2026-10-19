import AVFoundation

public protocol ObjectQueueItem { var timestamp: Int64 { get set } }
protocol MEFrame: ObjectQueueItem {}
struct TestFrame: MEFrame { var timestamp: Int64 }
struct Packet: ObjectQueueItem { var timestamp: Int64 }
enum MECodecState { case idle, decoding, flush, closed, failed, finished }
final class KSOptions {
    static let stackSize = 1024 * 1024
    var isAccurateSeek = false
}
final class Decoder {
    func decode() {}
    func shutdown() {}
    func doFlushCodec() {}
}
class SyncPlayerItemTrack<Frame: MEFrame> {
    let options: KSOptions
    let mediaType: AVMediaType
    var state = MECodecState.idle
    var seekTime = 0.0
    var isEndOfFile = false
    var isDecodeFinished: Bool { isEndOfFile }
    var isLoopModel = false
    var decoderMap = [Int32: Decoder]()
    var packetCount: Int { 0 }
    let outputRenderQueue = CircularBuffer<Frame>(initialCapacity: 16, expanding: false)
    var entered: DispatchSemaphore?
    var release: DispatchSemaphore?
    required init(mediaType: AVMediaType, frameCapacity: UInt8, options: KSOptions) {
        self.mediaType = mediaType
        self.options = options
    }
    func decode() { state = .decoding }
    func putPacket(packet: Packet) {}
    /* PRODUCTION_TRACK_SEEK */
    /* PRODUCTION_TRACK_SHUTDOWN */
    // Replace the codec only; queueing, worker state and seek are production code.
    func doDecode(packet: Packet, isCurrent: (() -> Bool)?) {
        entered?.signal()
        if let release { precondition(release.wait(timeout: .now() + 5) == .success) }
        outputRenderQueue.push(TestFrame(timestamp: packet.timestamp) as! Frame, if: {
            isCurrent?() != false && self.state != .flush && self.state != .closed
        })
    }
}

/* PRODUCTION_ASYNC_TRACK */

func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
func eventually(_ message: String, _ predicate: () -> Bool) {
    let end = Date().addingTimeInterval(3)
    while !predicate(), Date() < end { Thread.sleep(forTimeInterval: 0.001) }
    expect(predicate(), message)
}

@main struct EOFTrackRegressionTests {
    static func main() {
        let track = AsyncPlayerItemTrack<TestFrame>(mediaType: .video, frameCapacity: 16, options: KSOptions())
        track.decode()
        // Let the worker reach an empty blocking pop, then send EOF without a packet.
        Thread.sleep(forTimeInterval: 0.03)
        track.isEndOfFile = true
        eventually("Empty EOF left decoder waiting forever") { track.isDecodeFinished }
        // readThread calls decode again when seeking after demux EOF. It must not
        // clear EOF on the retained worker before seek resets the entire timeline.
        track.decode()
        expect(track.isEndOfFile && track.isDecodeFinished, "Repeated decode corrupted EOF state")

        for cycle in 0..<200 {
            track.seek(time: Double(cycle))
            track.decode()
            track.putPacket(packet: Packet(timestamp: Int64(cycle)))
            track.isEndOfFile = true
            eventually("Seek after EOF never decoded its keyframe") { track.outputRenderQueue.count == 1 }
            expect(track.outputRenderQueue.pop()?.timestamp == Int64(cycle), "Seek returned the wrong frame")
            eventually("Decoded EOF did not finish") { track.isDecodeFinished }
        }
        track.shutdown()
        print("PASS: empty EOF wakes decoder; 200 end/seek/replay cycles retain a live worker")

        let inflight = AsyncPlayerItemTrack<TestFrame>(mediaType: .audio, frameCapacity: 16, options: KSOptions())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        inflight.entered = entered
        inflight.release = release
        inflight.decode()
        inflight.putPacket(packet: Packet(timestamp: 100))
        expect(entered.wait(timeout: .now() + 3) == .success, "Decode never started")
        inflight.isEndOfFile = true
        expect(!inflight.isDecodeFinished, "EOF finished while the last packet was still decoding")
        inflight.seek(time: 1)
        release.signal()
        inflight.putPacket(packet: Packet(timestamp: 200))
        expect(entered.wait(timeout: .now() + 3) == .success, "New timeline did not resume")
        release.signal()
        inflight.isEndOfFile = true
        eventually("In-flight seek never completed") { inflight.isDecodeFinished }
        expect(inflight.outputRenderQueue.count == 1 && inflight.outputRenderQueue.pop()?.timestamp == 200,
               "Old in-flight packet survived the seek")
        inflight.shutdown()
        print("PASS: EOF waits for in-flight decode; seek rejects the old packet without losing the new one")
    }
}
