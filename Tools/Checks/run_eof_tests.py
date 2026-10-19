"""Run the actual async track lifecycle with a deterministic codec stand-in."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from run_seek_readiness_tests import block

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Vendor/KSPlayer/Sources/KSPlayer/MEPlayer'

def main():
    track = (BASE / 'MEPlayerItemTrack.swift').read_text()
    source = (ROOT / 'Tools/Checks/EOFTrackRegressionTests.swift').read_text()
    for marker, signature in [
        ('TRACK_SEEK', '    func seek(time: TimeInterval) {'),
        ('TRACK_SHUTDOWN', '    func shutdown() {'),
        ('ASYNC_TRACK', 'final class AsyncPlayerItemTrack<'),
    ]:
        source = source.replace('/* PRODUCTION_' + marker + ' */', block(track, signature))
    assert '/* PRODUCTION_' not in source
    with tempfile.TemporaryDirectory(prefix='eof-lifecycle-') as folder:
        path = Path(folder) / 'EOF.swift'
        binary = Path(folder) / 'eof'
        command = [shutil.which('swiftc'), '-swift-version', '5', '-parse-as-library',
                   str(path), str(BASE / 'CircularBuffer.swift'), '-o', str(binary)]
        path.write_text(source)
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
        engine = (ROOT / 'Photo/Media/VideoEngine.swift').read_text()
        engine_test = """
import Foundation
final class Engine {
    var duration = 100.0
    var stopped = false
    var pendingSeek: (time: Double, accurate: Bool)?
    func performPendingSeek() {}
    ENGINE_SEEK
}
@main struct EndSeekPolicy {
    static func main() {
        let engine = Engine()
        engine.seek(to: 40, accurate: false)
        precondition(engine.pendingSeek?.accurate == false)
        engine.seek(to: 100, accurate: false)
        precondition(engine.pendingSeek?.time == 100 && engine.pendingSeek?.accurate == true,
                     "End seek replayed the preceding GOP")
        engine.seek(to: 120, accurate: false)
        precondition(engine.pendingSeek?.time == 100 && engine.pendingSeek?.accurate == true)
        engine.seek(to: 40, accurate: true)
        precondition(engine.pendingSeek?.accurate == true)
        engine.seek(to: .nan, accurate: false)
        precondition(engine.pendingSeek?.time == 40)
        print("PASS: exact end uses terminal seek; ordinary fast seek remains unchanged")
    }
}
""".replace('ENGINE_SEEK', block(engine, '    func seek(to seconds:'))
        engine_path = Path(folder) / 'Engine.swift'
        engine_binary = Path(folder) / 'engine'
        engine_path.write_text(engine_test)
        subprocess.run([shutil.which('swiftc'), '-swift-version', '5', '-parse-as-library',
                        str(engine_path), '-o', str(engine_binary)], check=True)
        subprocess.run([str(engine_binary)], check=True)
        broken = source.replace('if isEndOfFile { packetQueue.finish() }', '')
        assert broken != source
        path.write_text(broken)
        subprocess.run(command, check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
        assert result.returncode != 0 and 'Empty EOF left decoder waiting forever' in result.stderr
        print('PASS: EOF regression rejects the previous missing wakeup')

if __name__ == '__main__':
    main()
