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
        broken = source.replace('if isEndOfFile { packetQueue.finish() }', '')
        assert broken != source
        path.write_text(broken)
        subprocess.run(command, check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
        assert result.returncode != 0 and 'Empty EOF left decoder waiting forever' in result.stderr
        print('PASS: EOF regression rejects the previous missing wakeup')

if __name__ == '__main__':
    main()
