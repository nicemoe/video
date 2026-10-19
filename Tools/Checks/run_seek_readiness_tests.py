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
        'FINISH_IF_DRAINED': block(item, '    private func finishIfDrained()'),
        'SOURCE_FINISHED': block(player, '    func sourceDidFinished()'),
        'PREPARE_SEEK_OUTPUT': block(item, 'private func prepareSeekOutput()'),
        'DISCARD_FRAMES': block((BASE / 'MEPlayer/MEPlayerItemTrack.swift').read_text(), 'func discardFrames(before '),
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

        early_preview = source.replace('if loadingState.isFirst, !loadingState.isSeek {', 'if loadingState.isFirst {')
        assert early_preview != source
        path.write_text(early_preview)
        subprocess.run(command, check=True)
        failed = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert failed.returncode != 0 and 'Resume consumed target video before aligned audio was ready' in failed.stderr
        print('PASS: regression test rejects premature first-open seek preview')

        page = (ROOT / 'Photo/Views/VideoPage.swift').read_text()
        startup = (ROOT / 'Tools/Checks/ResumeStartupRegressionTests.swift').read_text()
        startup = startup.replace('/* PRODUCTION_START */', block(page, 'private func start(from '))
        startup = startup.replace('/* PRODUCTION_PAGE_SEEK */', block(page, 'private func seek(to '))
        startup_path = Path(directory) / 'Startup.swift'
        startup_binary = Path(directory) / 'startup'
        startup_path.write_text(startup)
        startup_command = [compiler, '-swift-version', '5', '-parse-as-library', str(startup_path), '-o', str(startup_binary)]
        subprocess.run(startup_command, check=True)
        subprocess.run([str(startup_binary)], check=True)
        forced_precise = startup.replace('            seek(to: from)', '            made.seek(to: from, accurate: true)')
        assert forced_precise != startup
        startup_path.write_text(forced_precise)
        subprocess.run(startup_command, check=True)
        failed = subprocess.run([str(startup_binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert failed.returncode != 0 and 'Resume ignored the seek preference' in failed.stderr
        print('PASS: regression test rejects forced accurate resume')


if __name__ == '__main__':
    main()
