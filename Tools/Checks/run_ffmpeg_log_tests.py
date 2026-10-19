"""Exercise the production FFmpeg callback and reject late log filtering."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main():
    source = (ROOT / 'Vendor/KSPlayer/Sources/KSPlayer/MEPlayer/MEPlayerItem.swift').read_text()
    start = source.index('av_log_set_callback {')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    callback = source[start:end]
    marker = 'var log = String(cString: format)'
    assert callback.count(marker) == 1
    callback = callback.replace(marker, 'formatted += 1\n            ' + marker)
    test = (ROOT / 'Tools/Checks/FFmpegLogRegressionTests.swift').read_text()
    test = test.replace('/* PRODUCTION_LOG_CALLBACK */', callback)
    guard = 'guard level <= KSOptions.logLevel.rawValue || filterOptions != nil else { return }'
    assert guard in test
    compiler = shutil.which('swiftc')
    if not compiler:
        raise SystemExit('macOS Swift compiler required')
    with tempfile.TemporaryDirectory(prefix='ffmpeg-log-tests-') as folder:
        path, binary = Path(folder) / 'Log.swift', Path(folder) / 'log-tests'
        command = [compiler, '-O', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)]
        path.write_text(test)
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)
        path.write_text(test.replace(guard, ''))
        subprocess.run(command, check=True)
        subprocess.run([str(binary), '--benchmark'], check=True)
        failed = subprocess.run([str(binary)], capture_output=True, text=True)
        assert failed.returncode != 0 and 'Disabled index traces were formatted' in failed.stderr
        print('PASS: regression test rejects the previous late filtering')

if __name__ == '__main__':
    main()
