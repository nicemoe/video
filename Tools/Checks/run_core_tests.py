"""Compile and run regression tests against the production Foundation components."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
compiler = shutil.which('swiftc')
if compiler is None:
    raise SystemExit('Swift compiler required. Run on macOS with Xcode installed.')
sources = [
    'Photo/Server/HTTPTypes.swift',
    'Photo/Server/HTTPFileBody.swift',
    'Photo/Server/MultipartStream.swift',
    'Photo/Models/SnapshotWriter.swift',
    'Tools/Checks/CoreRegressionTests.swift',
]
with tempfile.TemporaryDirectory(prefix='multimedia-tests-') as output:
    binary = Path(output) / 'core-tests'
    subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                    *[str(root / source) for source in sources], '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    server_binary = Path(output) / 'server-lifecycle-tests'
    server_sources = sources[:3] + [
        'Photo/Server/HTTPServer.swift',
        'Tools/Checks/ServerLifecycleTests.swift',
    ]
    subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                    *[str(root / source) for source in server_sources], '-o', str(server_binary)], check=True)
    subprocess.run([str(server_binary)], check=True, timeout=60)

    upload_binary = Path(output) / 'upload-transport-tests'
    upload_sources = sources[:3] + [
        'Photo/Server/HTTPServer.swift',
        'Tools/Checks/UploadTransportTests.swift',
    ]
    subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                    *[str(root / source) for source in upload_sources], '-o', str(upload_binary)], check=True)
    subprocess.run([str(upload_binary)], check=True, timeout=60)

    seek_binary = Path(output) / 'seek-queue-tests'
    seek_sources = [
        'Vendor/KSPlayer/Sources/KSPlayer/MEPlayer/CircularBuffer.swift',
        'Tools/Checks/SeekQueueRegressionTests.swift',
    ]
    subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                    *[str(root / source) for source in seek_sources], '-o', str(seek_binary)], check=True)
    subprocess.run([str(seek_binary)], check=True)

    diagnostic_binary = Path(output) / 'seek-diagnostic-tests'
    diagnostic_sources = [
        'Vendor/KSPlayer/Sources/KSPlayer/MEPlayer/SeekDiagnostics.swift',
        'Tools/Checks/SeekDiagnosticsTests.swift',
    ]
    subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                    *[str(root / source) for source in diagnostic_sources], '-o', str(diagnostic_binary)], check=True)
    subprocess.run([str(diagnostic_binary)], check=True)

from run_seek_readiness_tests import main as check_seek_readiness
check_seek_readiness()

from run_ffmpeg_log_tests import main as check_ffmpeg_log
check_ffmpeg_log()

from run_eof_tests import main as check_eof
check_eof()

from run_replay_button_tests import main as check_replay_button
check_replay_button()
