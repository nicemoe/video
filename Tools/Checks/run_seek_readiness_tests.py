"""Exercise actual KSPlayer readiness methods with controlled output devices.

Only unrelated AV/FFmpeg devices are stubbed; tested methods/properties are
extracted unchanged from production. Also prove the original code fails.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Vendor/KSPlayer/Sources/KSPlayer'

def block(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def main():
    player = (BASE / 'MEPlayer/KSMEPlayer.swift').read_text()
    item = (BASE / 'MEPlayer/MEPlayerItem.swift').read_text()
    options = (BASE / 'AVPlayer/KSOptions.swift').read_text()
    definitions = (BASE / 'AVPlayer/PlayerDefines.swift').read_text()
    model = (BASE / 'MEPlayer/Model.swift').read_text()
    parts = {
        'AUDIO_MODEL': '\n'.join(block(model, signature) for signature in [
            'public protocol ObjectQueueItem', 'extension ObjectQueueItem', 'protocol MEFrame',
            'public struct Timebase', 'public final class AudioFrame']),
        'CAPACITY_TYPES': '\n'.join(block(definitions, signature) for signature in
            ['public protocol CapacityProtocol', 'extension CapacityProtocol', 'public struct LoadingState']),
        'PLAYABLE': block(options, 'open func playable('),
        'CAPACITY_UPDATE': block(item, 'func codecDidChangeCapacity()'),
        'PREPARE_SEEK_OUTPUT': block(item, 'private func prepareSeekOutput()'),
        'DISCARD_FRAMES': block((BASE / 'MEPlayer/MEPlayerItemTrack.swift').read_text(), 'func discardFrames(before:'),
        'LOAD_STATE': block(player, 'public private(set) var loadState ='),
        'PLAYBACK_STATE': block(player, 'public private(set) var playbackState ='),
        'PLAY_OR_PAUSE': block(player, 'func playOrPause()'),
        'SEEK': block(player, 'public func seek(time:'),
        'LOADING_UPDATE': block(player, 'func sourceDidChange(loadingState:'),
    }
    source = (ROOT / 'Tools/Checks/SeekReadinessRegressionTests.swift').read_text()
    for name, method in parts.items():
        source = source.replace('/* PRODUCTION_' + name + ' */', method)
    assert '/* PRODUCTION_' not in source
    compiler = shutil.which('swiftc')
    if not compiler:
        raise SystemExit('macOS Swift compiler required')
    with tempfile.TemporaryDirectory(prefix='seek-readiness-') as directory:
        path = Path(directory) / 'Readiness.swift'
        binary = Path(directory) / 'readiness'
        path.write_text(source)
        command = [compiler, '-swift-version', '5', '-parse-as-library', str(path), str(BASE / 'MEPlayer/SeekDiagnostics.swift'), str(BASE / 'MEPlayer/CircularBuffer.swift'), '-o', str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)
        # Remove only the new seek invalidation. The same test must reject it.
        old_seek = parts['SEEK'].replace('        loadState = .loading\n', '')
        assert old_seek != parts['SEEK']
        path.write_text(source.replace(parts['SEEK'], old_seek))
        subprocess.run(command, check=True)
        failed = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert failed.returncode != 0 and 'Seek reused old playable state' in failed.stderr
        print('PASS: regression test rejects the previous seek implementation')
        # The real phone trace must fail if audio preroll alignment is removed.
        unaligned = source.replace('audioTrack?.discardFrames(before: firstVideo.seconds)', '')
        assert unaligned != source
        path.write_text(unaligned)
        subprocess.run(command, check=True)
        failed = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert failed.returncode != 0 and 'Audio preroll survived fast seek' in failed.stderr
        print('PASS: regression test rejects unaligned fast-seek audio')

if __name__ == '__main__':
    main()
