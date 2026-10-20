"""Run production disk scanning/reconciliation against a real temporary media tree."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from run_seek_readiness_tests import block

ROOT = Path(__file__).resolve().parents[2]

def main():
    store = (ROOT / 'Photo/Models/LibraryStore.swift').read_text()
    sync = (ROOT / 'Photo/Models/DiskSync.swift').read_text()
    models = (ROOT / 'Photo/Models/Models.swift').read_text()
    source = (ROOT / 'Tools/Checks/DiskSyncRegressionTests.swift').read_text()
    methods = [block(store, signature) for signature in [
        '    var diskDirectoryPaths:', '    func removeMissingDirectories(',
        '    func removeAssets(', '    var livePosterNames:', '    func dirPath(ofFolder',
        '    private func locate(folder', '    private func group(containing',
        '    func path(to folderID:',
        '    nonisolated static func displayName(',
    ]]
    methods += [block(sync, signature) for signature in [
        '    func syncWithDisk()', '    private func reconcileDisk()',
        '    nonisolated private static func scanMedia()',
        '    nonisolated private static func sweepPosters(',
        '    private func register(',
    ]]
    source = source.replace('/* PRODUCTION_MODELS */', models[models.index('enum AssetKind:'):models.index('// MARK: - 排序')])
    source = source.replace('/* PRODUCTION_METHODS */', '\n'.join(methods))
    with tempfile.TemporaryDirectory(prefix='disk-sync-') as folder:
        path = Path(folder) / 'DiskSync.swift'
        binary = Path(folder) / 'disk-sync'
        command = [shutil.which('swiftc'), '-swift-version', '5', '-parse-as-library', str(path),
                   str(ROOT / 'Photo/Models/DiskFileState.swift'), '-o', str(binary)]
        path.write_text(source)
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
        # Verify the scenario catches the old behavior (asset-only reconciliation).
        start = source.index('let removedDirectories = removeMissingDirectories(')
        end = source.index('\n        let removed =', start)
        path.write_text(source[:start] + 'let removedDirectories = 0' + source[end:])
        subprocess.run(command, check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and 'Deleted directory records remain' in result.stderr
        print('PASS: disk sync regression rejects asset-only reconciliation')

if __name__ == '__main__':
    main()
