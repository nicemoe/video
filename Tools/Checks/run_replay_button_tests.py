"""Exercise the real page buttons and engine callbacks together with controlled I/O."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from run_seek_readiness_tests import block

ROOT = Path(__file__).resolve().parents[2]

def main():
    engine = (ROOT / 'Photo/Media/VideoEngine.swift').read_text()
    engine = engine[engine.index('final class FFmpegEngine:'):]
    page = (ROOT / 'Photo/Views/VideoPage.swift').read_text()
    source = (ROOT / 'Tools/Checks/ReplayButtonRegressionTests.swift').read_text()
    parts = {
        'ENGINE_TIME': block(engine, '    var currentTime: Double {'),
        'ENGINE_PLAY': block(engine, '    func play() {'),
        'ENGINE_PAUSE': block(engine, '    func pause() {'),
        'ENGINE_SEEK': block(engine, '    func seek(to seconds: Double, accurate: Bool) {'),
        'ENGINE_PERFORM_SEEK': block(engine, '    private func performPendingSeek() {'),
        'ENGINE_FINISH': block(engine, '    func finish(player:'),
        'PAGE_FINISH': block(page, '    private func finish() {'),
        'PAGE_TOGGLE': block(page, '    private func toggle() {'),
        'PAGE_SEEK': block(page, '    private func seek(to seconds:'),
    }
    for name, method in parts.items():
        source = source.replace('/* PRODUCTION_' + name + ' */', method)
    assert '/* PRODUCTION_' not in source
    with tempfile.TemporaryDirectory(prefix='replay-button-') as folder:
        path = Path(folder) / 'Replay.swift'
        binary = Path(folder) / 'replay'
        command = [shutil.which('swiftc'), '-swift-version', '5', '-parse-as-library', str(path),
                   str(ROOT / 'Vendor/KSPlayer/Sources/KSPlayer/MEPlayer/SeekDiagnostics.swift'), '-o', str(binary)]
        path.write_text(source)
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
        branch = '''        if hasFinishedPlayback {
            seek(to: 0, accurate: options.isAccurateSeek)
            return
        }
'''
        assert branch in source
        path.write_text(source.replace(branch, ''))
        subprocess.run(command, check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and 'Play after completion did not seek to zero' in result.stderr
        print('PASS: replay-button regression rejects the previous missing completed-state handling')

if __name__ == '__main__':
    main()
