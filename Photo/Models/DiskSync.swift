import Foundation

// MARK: - 拿磁盘和索引对账

extension LibraryStore {

    /// 扫一遍 Media，把磁盘上多出来的收进来、少掉的清出去。
    ///
    /// 开了文件共享之后，Media 就是用户直接看得见、动得了的东西：他会在
    /// 访达里新建 `Media/视频/搞笑/`、往里丢文件，也会直接删掉不要的。
    /// 所以这里不再单独开一个「导入」文件夹，磁盘本身就是入口——
    /// 目录结构本来就是分组和目录，一一对得上：
    ///
    ///     Media/2025 京都/大阪/IMG_0001.jpg  →  分组「2025 京都」→ 目录「大阪」
    ///     Media/视频/a.mp4                   →  分组「视频」→ 目录「未分类」
    ///
    /// 「哪些是新的」靠对账：asset.fileName 存的正是相对 Media 的路径，
    /// 拿磁盘上扫到的路径和它比一遍就知道。不用比文件数——比数不可靠，
    /// 删一个加一个数字还一样。
    ///
    /// 返回 (收进来的, 清出去的)。
    @discardableResult
    func syncWithDisk() async -> (added: Int, removed: Int) {
        // 下拉刷新与前台同步共用本轮任务，刷新指示器等到实际同步完成。
        if let diskSyncTask { return await diskSyncTask.value }
        let task = Task { await reconcileDisk() }
        diskSyncTask = task
        let result = await task.value
        diskSyncTask = nil
        return result
    }

    private func reconcileDisk() async -> (added: Int, removed: Int) {
        let scannedDirectories = diskDirectoryPaths

        let scanned = Dictionary(uniqueKeysWithValues: library.groups.flatMap {
            $0.folders.flatMap { $0.assets.map { ($0.id, $0.fileName) } }
        })

        // 扫盘甩到后台：一万张照片走一遍目录树要几百毫秒，
        // 压在主线程上每次切回前台都要顿一下。
        //
        // 扫不动就整个对账都不做。下面第二步是拿「磁盘上没有」当删除依据的，
        // 而扫失败和扫出空目录长得一模一样——混为一谈的话，一次读不到 Media
        // 就等于把整个图库连同封面一起清空。
        let onDisk: (files: [String: DiskFileState], directories: Set<String>)
        do {
            onDisk = try await Task.detached(priority: .utility) { try Self.scanMedia() }.value
        } catch {
            operationError = "扫描媒体库失败：\(error.localizedDescription)"
            return (0, 0)
        }

        // 磁盘刚被人动过，之前记住的「这个目录里有哪些名字」不作数了
        forgetClaimedNames()

        // 先摘掉消失的文件，再移除消失的目录记录；不删除磁盘内容。
        // 必须在导入前完成，避免沿用已被电脑删除的旧目录记录。
        let removedAssets = removeAssets(notIn: Set(onDisk.files.keys.map { $0.lowercased() }), scanned: scanned)
        let removedDirectories = removeMissingDirectories(existing: onDisk.directories,
                                                          scanned: scannedDirectories)
        let removed = removedAssets + removedDirectories

        var known: Set<String> = []
        for group in library.groups {
            for folder in group.folders {
                for asset in folder.assets { known.insert(asset.fileName.lowercased()) }
            }
        }

        // 一、磁盘上有、索引里没有 —— 新丢进来的
        var added = 0
        let candidates = onDisk.files.keys.sorted().filter { !known.contains($0.lowercased()) }
        if !candidates.isEmpty {
            // 整批只等一次，观察复制期间的大小/修改时间变化，不按文件逐个等待。
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch {
                if removed > 0 { saveNow() }
                return (0, removed)
            }
        }
        for path in candidates {
            guard let expected = onDisk.files[path], expected.bytes > 0 else { continue }
            guard let folderID = folderID(forDiskPath: path) else { continue }
            if await register(path: path, in: folderID, expected: expected) { added += 1 }
        }

        // 顺手把没人认领的封面清了。摘记录时已经删过对应的那张，这里是兜底：
        // 早先的版本、以及删分组/删目录那几条路都可能漏下几张。
        //
        // 甩到后台。一万个视频就是一万个封面文件，列一遍加上删几个，
        // 压在主线程上每次切回前台都要顿一下。
        let live = livePosterNames
        await Task.detached(priority: .utility) { Self.sweepPosters(keeping: live) }.value

        if added > 0 || removed > 0 { saveNow() }
        return (added, removed)
    }

    /// 把库里所有视频的封面提前抽好。
    ///
    /// 抽帧是这条链上最贵的一步（开解码器解一帧，一百到三百毫秒），而目录
    /// 封面一张卡要四个。等人滑到哪儿才抽哪儿，第一次进分组就得盯着封面
    /// 一格一格往外冒。提前抽完，之后所有列表都只是读盘解图。
    ///
    /// 每次对账之后跑一次。全都有封面时它就是每个视频一次 fileExists，
    /// 而且在后台线程上，白跑一趟也不疼。
    func backfillPosters() async {
        guard !isBackfilling else { return }
        isBackfilling = true
        defer { isBackfilling = false }

        var videos: [Asset] = []
        for group in library.groups {
            for folder in group.folders {
                for asset in folder.assets where asset.isVideo { videos.append(asset) }
            }
        }
        guard !videos.isEmpty else { return }
        await ThumbnailCache.shared.backfillPosters(for: videos)
    }

    /// Posters 里认不出主人的封面一律清掉
    nonisolated private static func sweepPosters(keeping live: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.posters.path) else { return }
        for name in names where name.hasSuffix(".jpg") && !live.contains(name) {
            try? fm.removeItem(at: Paths.posters.appendingPathComponent(name))
        }
    }

    // MARK: 扫盘

    /// Media 下所有能认的媒体文件，key 是相对 Media 的路径。
    ///
    /// 任何目录读取失败都终止本轮扫描，不用不完整快照删除记录。
    nonisolated private static func scanMedia() throws -> (files: [String: DiskFileState], directories: Set<String>) {
        let fm = FileManager.default
        do {
            let root = try fm.attributesOfItem(atPath: Paths.media.path)
            guard root[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadCorruptFile) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return ([:], [])
        }
        var scanError: Error?
        guard let walker = fm.enumerator(at: Paths.media,
                                         includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles], errorHandler: { _, error in
            scanError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }

        let rootParts = Paths.media.standardizedFileURL.pathComponents
        var out: [String: DiskFileState] = [:]
        var directories: Set<String> = []

        for case let url as URL in walker {
            let parts = url.standardizedFileURL.pathComponents
            guard parts.count > rootParts.count,
                  Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            let relative = parts.dropFirst(rootParts.count).joined(separator: "/")
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true {
                directories.insert(relative.lowercased())
                continue
            }
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            let isVideo = MediaFormats.isVideo(fileName: name)
            guard isVideo || MediaFormats.isImage(fileName: name) else { continue }

            if let state = try DiskFileState.read(at: url) { out[relative] = state }
        }
        if let scanError { throw scanError }
        return (out, directories)
    }

    // MARK: 收进来

    /// 相对路径 → 该落在哪个目录，分组和目录不存在就照着磁盘建出来
    private func folderID(forDiskPath path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }   // 直接躺在 Media 根下的不收

        let groupDir = parts[0]
        let group = groups.first { $0.dirName == groupDir }
            ?? makeGroup(dirName: groupDir)
        guard let group else { return nil }

        // 中间几段是目录，最后一段是文件名
        var current: UUID?
        for dir in parts.dropFirst().dropLast().prefix(8) {
            guard let next = makeFolder(dirName: dir, under: current, in: group.id) else { break }
            current = next
        }
        if let current { return current }

        // 文件直接躺在分组目录下，没有目录可落——收进「未分类」，
        // 和从别处导入的规矩一致
        return makeFolder(dirName: "未分类", under: nil, in: group.id)
    }

    /// 按磁盘上的目录名找分组，没有就建一个同名的。
    /// 注意认的是 dirName 不是显示名：磁盘上那个才是权威。
    private func makeGroup(dirName: String) -> PhotoGroup? {
        // addGroup 会自己洗一遍名字、避重，算出来的 dirName 可能和磁盘上的
        // 不一样。这里要的是和磁盘完全一致，所以照磁盘回填一次。
        let group = addGroup(name: dirName)
        setDirName(dirName, forGroup: group.id)
        return self.group(group.id)
    }

    private func makeFolder(dirName: String, under parentID: UUID?, in groupID: UUID) -> UUID? {
        if let hit = group(groupID)?.folders.first(where: {
            $0.parentID == parentID && $0.dirName == dirName
        }) {
            return hit.id
        }
        guard let folder = addFolder(to: groupID, name: dirName, parent: parentID) else { return nil }
        setDirName(dirName, forFolder: folder.id)
        return folder.id
    }

    /// 探一下这个文件，挂进索引。文件本身不动——它已经在该在的位置了。
    private func register(path: String, in folderID: UUID, expected: DiskFileState) async -> Bool {
        let url = Paths.media.appendingPathComponent(path)
        let name = (path as NSString).lastPathComponent
        do {
            guard expected.bytes > 0, try expected.matchesFile(at: url) else { return false }
            let asset: Asset
            if MediaFormats.isVideo(fileName: name) {
                let info = try await VideoProbe.inspect(url)
                asset = Asset(fileName: path, originalName: Self.displayName(from: name), kind: .video,
                              width: info.width, height: info.height, byteCount: expected.bytes,
                              duration: info.duration)
            } else {
                let probe = try await Task.detached(priority: .utility) { () -> ImageProbe.Info? in
                    let data = try Data(contentsOf: url)
                    return ImageProbe.inspect(data)
                }.value
                guard let info = probe else { return false }
                asset = Asset(fileName: path, originalName: Self.displayName(from: name),
                              width: info.width, height: info.height, byteCount: expected.bytes)
            }
            guard try expected.matchesFile(at: url) else { return false }
            return attach(asset, to: folderID)
        } catch {
            let probeError = error
            do {
                // 探测期间继续复制或被移走，下次刷新再处理，不当成坏视频。
                guard try expected.matchesFile(at: url) else { return false }
            } catch {
                operationError = "无法读取「\(name)」：\(error.localizedDescription)"
                return false
            }
            operationError = "无法导入「\(name)」：\(probeError.localizedDescription)"
            return false
        }
    }

}
