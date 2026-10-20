import Foundation

/* PRODUCTION_MODELS */

enum Paths {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static let media = root.appendingPathComponent("Media")
    static let posters = root.appendingPathComponent("Posters")
    static func url(for asset: Asset) -> URL { media.appendingPathComponent(asset.fileName) }
    static func poster(for id: UUID) -> URL { posters.appendingPathComponent("\(id.uuidString).jpg") }
}
enum MediaFormats {
    static func isVideo(fileName: String) -> Bool { fileName.hasSuffix(".mp4") }
    static func isImage(fileName: String) -> Bool { fileName.hasSuffix(".jpg") }
}
@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    var invalidated: Set<UUID> = []
    func invalidate(_ id: UUID) { invalidated.insert(id) }
}
struct Library: Codable { var groups: [PhotoGroup] = [] }
@MainActor final class LibraryStore {
    var library = Library()
    var groups: [PhotoGroup] { library.groups }
    var diskSyncTask: Task<(added: Int, removed: Int), Never>?
    var operationError: String?
    var saved: Data?
    var registrations = 0
    func saveNow() { saved = try! JSONEncoder().encode(library) }
    func forgetClaimedNames() {}
    // Codec/import I/O is outside these tests; reconciliation and filesystem scanning are production code.
    func folderID(forDiskPath path: String) -> UUID? { library.groups.first?.folders.first?.id }
    func register(path: String, in id: UUID) async -> Bool {
        registrations += 1
        await Task.yield()
        guard let (gi, fi) = locate(folder: id) else { return false }
        library.groups[gi].folders[fi].assets.append(Asset(fileName: path))
        return true
    }
    /* PRODUCTION_METHODS */
}
struct Failure: Error { let message: String }
func expect(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(at: Paths.media.appendingPathComponent(path), withIntermediateDirectories: true)
}

@main struct DiskSyncRegressionTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        try mkdir("保留/空目录")
        try mkdir("空分组")
        try fm.createDirectory(at: Paths.posters, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: Paths.root) }
        let video = Asset(fileName: "删除/父/子/movie.mp4", kind: .video)
        let parent = Folder(name: "父", dirName: "父")
        let child = Folder(name: "子", parentID: parent.id, dirName: "子", assets: [video])
        let empty = Folder(name: "空目录", dirName: "空目录")
        let missingEmpty = Folder(name: "删掉的空目录", dirName: "删掉的空目录")
        let keep = PhotoGroup(name: "保留", dirName: "保留", folders: [empty, missingEmpty])
        let store = LibraryStore()
        store.library.groups = [PhotoGroup(name: "删除", dirName: "删除", folders: [parent, child]), keep,
                                PhotoGroup(name: "空分组", dirName: "空分组"),
                                PhotoGroup(name: "已删除空分组", dirName: "已删除空分组")]
        try Data([1]).write(to: Paths.poster(for: video.id))
        let result = await store.syncWithDisk()
        try expect(store.groups.map(\.name) == ["保留", "空分组"], "Deleted directory records remain")
        try expect(store.groups[0].folders.map(\.id) == [empty.id], "Existing empty folder was lost")
        try expect(result.removed == 6, "Wrong deletion count")
        try expect(!fm.fileExists(atPath: Paths.poster(for: video.id).path), "Deleted video poster remains")
        try expect(ThumbnailCache.shared.invalidated.contains(video.id), "Deleted thumbnail cache remains")
        let restored = try JSONDecoder().decode(Library.self, from: store.saved!)
        try expect(restored.groups == store.groups, "Pruned directory index was not saved")
        let repeated = await store.syncWithDisk()
        try expect(repeated.removed == 0, "Repeated refresh is not idempotent")
        print("PASS: deleted group/subtree/empty folders removed, existing empty folders retained, index saved")

        // Only directories disappeared: no asset count change may be needed to persist the index.
        try fm.removeItem(at: Paths.media.appendingPathComponent("空分组"))
        let emptyResult = await store.syncWithDisk()
        try expect(emptyResult.removed == 1 && store.groups.count == 1, "Empty group removal was not persisted")
        try expect(try JSONDecoder().decode(Library.self, from: store.saved!).groups.count == 1, "Empty-only deletion was not saved")

        // A stale scan cannot delete a renamed, newly created, or recreated directory.
        let snapshot = store.diskDirectoryPaths
        store.library.groups[0].folders[0].dirName = "已改名"
        let created = Folder(name: "扫描后新增", dirName: "扫描后新增")
        store.library.groups[0].folders.append(created)
        try expect(store.removeMissingDirectories(existing: [], scanned: snapshot) == 0, "Concurrent rename/create lost")
        store.library.groups[0].folders[0].dirName = "空目录"
        try expect(store.removeMissingDirectories(existing: [], scanned: store.diskDirectoryPaths) == 1,
                   "Recreated on-disk directory lost or missing empty directory retained")
        print("PASS: directory-only changes saved; concurrent rename/create/recreation preserved")

        // A newly attached descendant keeps its ancestor chain even if the old snapshot lacked it.
        let outer = Folder(name: "外", dirName: "外")
        let inner = Folder(name: "内", parentID: outer.id, dirName: "内",
                           assets: [Asset(fileName: "保留/外/内/new.mp4")])
        store.library.groups[0].folders += [outer, inner]
        try expect(store.removeMissingDirectories(existing: [], scanned: store.diskDirectoryPaths) == 0,
                   "Active descendant orphaned by stale scan")
        store.library.groups[0].folders = [empty]

        // Both callers wait for the same scan/import, including its result.
        try Data([2]).write(to: Paths.media.appendingPathComponent("保留/空目录/new.jpg"))
        async let first = store.syncWithDisk()
        async let second = store.syncWithDisk()
        let (a, b) = await (first, second)
        try expect(a.added == 1 && b.added == 1 && store.registrations == 1, "Concurrent refresh duplicated import or returned early")
        print("PASS: simultaneous foreground and pull refresh share one completed import")

        // Invalid/unreadable root is an error, not an empty successful snapshot.
        try fm.moveItem(at: Paths.media, to: Paths.root.appendingPathComponent("SavedMedia"))
        try Data([3]).write(to: Paths.media)
        let before = store.library.groups
        let failure = await store.syncWithDisk()
        try expect(failure.removed == 0 && store.groups == before && store.operationError != nil,
                   "Failed scan destroyed the index")
        try fm.removeItem(at: Paths.media)
        store.operationError = nil
        let deletedRoot = await store.syncWithDisk()
        try expect(deletedRoot.removed > 0 && store.groups.isEmpty && store.operationError == nil,
                   "Deleted Media root left stale records")
        print("PASS: scan failure preserves index; explicitly missing Media root clears stale records")
    }
}
