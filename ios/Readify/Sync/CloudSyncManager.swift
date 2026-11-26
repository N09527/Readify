import Foundation

private actor CloudSyncGate {
    static let shared = CloudSyncGate()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

final class CloudSyncManager {
    private static let stateFile = "sync_state.json"
    private static let booksSubfolder = "books"

    private let repository: AppRepository

    init(repository: AppRepository) {
        self.repository = repository
    }

    func createClient(
        config: CloudSyncConfig,
        onConfigUpdated: @escaping @Sendable (CloudSyncConfig) -> Void
    ) -> CloudStorageClient {
        let repo = repository
        switch config.activeProvider {
        case .WEBDAV:
            return WebDavClient(config: config.webDav)
        case .GOOGLE_DRIVE:
            return GoogleDriveClient(initialConfig: config.googleDrive) { updatedGDrive in
                var newCfg = repo.loadCloudSyncConfig()
                newCfg.googleDrive = updatedGDrive
                repo.saveCloudSyncConfig(newCfg)
                onConfigUpdated(newCfg)
            }
        case .ONEDRIVE:
            return OneDriveClient(initialConfig: config.oneDrive) { updatedOneDrive in
                var newCfg = repo.loadCloudSyncConfig()
                newCfg.oneDrive = updatedOneDrive
                repo.saveCloudSyncConfig(newCfg)
                onConfigUpdated(newCfg)
            }
        }
    }

    func testConnection(
        config: CloudSyncConfig,
        onConfigUpdated: @escaping @Sendable (CloudSyncConfig) -> Void
    ) async throws -> String {
        let client = createClient(config: config, onConfigUpdated: onConfigUpdated)
        return try await client.testConnection()
    }

    func listCloudFiles(
        config: CloudSyncConfig,
        onConfigUpdated: @escaping @Sendable (CloudSyncConfig) -> Void
    ) async throws -> [RemoteFileEntry] {
        let client = createClient(config: config, onConfigUpdated: onConfigUpdated)
        try await client.ensureRootFolder()
        let rootEntries = try await client.listFiles(subFolder: "")
        let bookEntries = (try? await client.listFiles(subFolder: Self.booksSubfolder)) ?? []
        let mappedBooks = bookEntries.map { entry -> RemoteFileEntry in
            var copy = entry
            copy.name = "\(Self.booksSubfolder)/\(entry.name)"
            return copy
        }
        let filteredRoot = rootEntries.filter { !($0.isDirectory && $0.name.lowercased() == Self.booksSubfolder) }
        return (filteredRoot + mappedBooks).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func syncNow(
        config: CloudSyncConfig,
        syncBookFilesOverride: Bool? = nil,
        onConfigUpdated: @escaping @Sendable (CloudSyncConfig) -> Void,
        onProgress: @escaping @Sendable (String) async -> Void
    ) async throws -> SyncReport {
        await CloudSyncGate.shared.acquire()
        do {
            let report = try await performSyncNow(
                config: config,
                syncBookFilesOverride: syncBookFilesOverride,
                onConfigUpdated: onConfigUpdated,
                onProgress: onProgress
            )
            await CloudSyncGate.shared.release()
            return report
        } catch {
            await CloudSyncGate.shared.release()
            throw error
        }
    }

    private func performSyncNow(
        config: CloudSyncConfig,
        syncBookFilesOverride: Bool?,
        onConfigUpdated: @escaping @Sendable (CloudSyncConfig) -> Void,
        onProgress: @escaping @Sendable (String) async -> Void
    ) async throws -> SyncReport {
        let effectiveSyncBookFiles = syncBookFilesOverride ?? config.syncBookFiles
        let client = createClient(config: config, onConfigUpdated: onConfigUpdated)
        var errors: [String] = []
        var uploadedBooks = 0
        var downloadedBooks = 0

        await onProgress("正在連線 \(config.activeProvider.label) 並檢查同步目錄…")
        try await client.ensureRootFolder()

        await onProgress("正在掃描本機書架與計算書籍指紋…")
        let fm = FileManager.default
        let localBooks: [BookItem] = repository.loadBooks().map { book in
            let fileURL = repository.resolveBookFileURL(book)
            if book.contentHash.isEmpty && fm.fileExists(atPath: fileURL.path) {
                var copy = book
                copy.contentHash = repository.computeFastFingerprint(fileURL: fileURL)
                if copy.fileSizeBytes <= 0,
                   let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let sz = (attrs[.size] as? NSNumber)?.int64Value {
                    copy.fileSizeBytes = sz
                }
                return copy
            }
            return book
        }

        let localBookmarks = repository.loadAllBookmarks()
        let localDeletedBookmarks = repository.loadDeletedBookmarkIds()
        let localSettings = repository.loadSettings()
        let localSettingsUpdatedAt = repository.loadSettingsUpdatedAtMs()

        await onProgress("正在下載雲端同步紀錄 (\(Self.stateFile))…")
        let remoteStateBytes = try await client.downloadBytes(remotePath: Self.stateFile)
        let remoteJson: [String: Any]? = remoteStateBytes.flatMap { bytes in
            (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }

        let remoteBooks = parseRemoteBooks(remoteJson)
        let remoteBookmarks = parseRemoteBookmarks(remoteJson)
        let remoteDeletedBookmarks = parseRemoteStringSet(remoteJson, key: "deletedBookmarkIds")
        let remoteSettingsUpdatedAt = (remoteJson?["settingsUpdatedAtMs"] as? NSNumber)?.int64Value ?? 0
        let remoteSettingsObj = remoteJson?["settings"] as? [String: Any]

        var remoteBookFileSet: Set<String> = []
        if effectiveSyncBookFiles {
            await onProgress("正在比對雲端書檔清單…")
            let listed = (try? await client.listFiles(subFolder: Self.booksSubfolder)) ?? []
            remoteBookFileSet = Set(listed.filter { !$0.isDirectory }.map { $0.name })
        }

        var bookIdRemap: [String: String] = [:]
        var mergedBooks: [BookItem] = []
        var matchedRemoteIds: Set<String> = []

        // Step A: Reconcile local books against remote records
        for local in localBooks {
            if let remoteMatch = findMatchingRemoteBook(local: local, remoteBooks: remoteBooks, alreadyMatchedIds: matchedRemoteIds) {
                matchedRemoteIds.insert(remoteMatch.id)
                let canonicalId = remoteMatch.id
                var merged = local
                if local.id != canonicalId {
                    bookIdRemap[local.id] = canonicalId
                    merged.id = canonicalId
                }
                if remoteMatch.lastReadTime > local.lastReadTime {
                    if !remoteMatch.tags.isEmpty { merged.tags = remoteMatch.tags }
                    merged.lastChapterIndex = remoteMatch.lastChapterIndex
                    merged.lastCharOffset = remoteMatch.lastCharOffset
                    merged.lastPageIndex = remoteMatch.lastPageIndex
                    merged.lastReadTime = remoteMatch.lastReadTime
                    merged.contentType = remoteMatch.contentType
                    merged.readingProgress = remoteMatch.readingProgress
                    merged.isRead = remoteMatch.isRead
                    merged.hasStartedReading = remoteMatch.hasStartedReading
                }
                mergedBooks.append(merged)

                if effectiveSyncBookFiles {
                    let remoteFileName = buildRemoteBookFileName(merged)
                    if !remoteBookFileSet.contains(remoteFileName) {
                        let localURL = repository.resolveBookFileURL(local)
                        if fm.fileExists(atPath: localURL.path) {
                            await onProgress("正在上傳書檔：\(merged.title)…")
                            do {
                                try await client.uploadFile(
                                    remotePath: "\(Self.booksSubfolder)/\(remoteFileName)",
                                    sourceURL: localURL,
                                    contentType: "application/octet-stream"
                                )
                                uploadedBooks += 1
                            } catch {
                                errors.append("上傳「\(merged.title)」失敗：\(error.localizedDescription)")
                            }
                        }
                    }
                }
            } else {
                mergedBooks.append(local)
                if effectiveSyncBookFiles {
                    let remoteFileName = buildRemoteBookFileName(local)
                    if !remoteBookFileSet.contains(remoteFileName) {
                        let localURL = repository.resolveBookFileURL(local)
                        if fm.fileExists(atPath: localURL.path) {
                            await onProgress("正在上傳書檔：\(local.title)…")
                            do {
                                try await client.uploadFile(
                                    remotePath: "\(Self.booksSubfolder)/\(remoteFileName)",
                                    sourceURL: localURL,
                                    contentType: "application/octet-stream"
                                )
                                uploadedBooks += 1
                            } catch {
                                errors.append("上傳「\(local.title)」失敗：\(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }

        // Step B: Download remote-only books (if effectiveSyncBookFiles is enabled)
        let unmatchedRemoteBooks = remoteBooks.filter { !matchedRemoteIds.contains($0.id) }
        var preservedRemoteOnlyRecords: [RemoteBookRecord] = []

        for remote in unmatchedRemoteBooks {
            if effectiveSyncBookFiles {
                let safeExt = remote.ext.isEmpty ? remote.format.rawValue.lowercased() : remote.ext
                let remoteFileName = remote.remoteFileName.isEmpty ? "\(remote.id).\(safeExt)" : remote.remoteFileName
                let relBookPath = "Books/\(remote.id).\(safeExt)"
                let destURL = repository.booksDir.appendingPathComponent("\(remote.id).\(safeExt)")

                await onProgress("正在從雲端下載：\(remote.title)…")
                do {
                    let downloaded = try await client.downloadFile(
                        remotePath: "\(Self.booksSubfolder)/\(remoteFileName)",
                        destURL: destURL
                    )
                    let sizeBytes = ((try? fm.attributesOfItem(atPath: destURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    if downloaded && fm.fileExists(atPath: destURL.path) && sizeBytes > 0 {
                        let parsed = BookParser.parseMetadataAndCover(
                            fileURL: destURL,
                            format: remote.format,
                            fallbackTitle: remote.title.isEmpty ? remote.sourceFileName : remote.title
                        )

                        var relCoverPath: String?
                        if let coverBytes = parsed.coverBytes, !coverBytes.isEmpty {
                            let relCover = "Covers/\(remote.id).img"
                            let coverURL = repository.appSupportDir.appendingPathComponent(relCover)
                            if (try? coverBytes.write(to: coverURL, options: .atomic)) != nil {
                                relCoverPath = relCover
                            }
                        }

                        let newLocal = BookItem(
                            id: remote.id,
                            title: remote.title.isEmpty ? parsed.title : remote.title,
                            author: remote.author.isEmpty ? parsed.author : remote.author,
                            format: remote.format,
                            contentType: remote.contentType,
                            localPath: relBookPath,
                            coverPath: relCoverPath,
                            tags: remote.tags,
                            lastChapterIndex: remote.lastChapterIndex,
                            lastCharOffset: remote.lastCharOffset,
                            lastPageIndex: remote.lastPageIndex,
                            lastReadTime: remote.lastReadTime,
                            addedTime: remote.addedTime,
                            sourceFileName: remote.sourceFileName,
                            fileSizeBytes: sizeBytes,
                            contentHash: remote.contentHash.isEmpty ? repository.computeFastFingerprint(fileURL: destURL) : remote.contentHash,
                            readingProgress: remote.readingProgress,
                            isRead: remote.isRead,
                            hasStartedReading: remote.hasStartedReading
                        )
                        mergedBooks.append(newLocal)
                        downloadedBooks += 1
                    } else {
                        preservedRemoteOnlyRecords.append(remote)
                    }
                } catch {
                    errors.append("下載「\(remote.title)」失敗：\(error.localizedDescription)")
                    preservedRemoteOnlyRecords.append(remote)
                }
            } else {
                preservedRemoteOnlyRecords.append(remote)
            }
        }

        // Step C: Merge Bookmarks (union minus deleted tombstones)
        await onProgress("正在合併書籤資料…")
        let mergedDeletedBookmarks = localDeletedBookmarks.union(remoteDeletedBookmarks)
        var bookmarkMap: [String: BookmarkItem] = [:]
        for bm in remoteBookmarks where !mergedDeletedBookmarks.contains(bm.id) {
            bookmarkMap[bm.id] = bm
        }
        for bm in localBookmarks where !mergedDeletedBookmarks.contains(bm.id) {
            var copy = bm
            if let mappedId = bookIdRemap[bm.bookId] {
                copy.bookId = mappedId
            }
            bookmarkMap[copy.id] = copy
        }
        let mergedBookmarks = bookmarkMap.values.sorted { $0.createdAt > $1.createdAt }

        // Step D: Optionally merge ReaderSettings (preserving device-local font paths & shelfCoverSize)
        var effectiveSettings = localSettings
        var effectiveSettingsUpdatedAt = localSettingsUpdatedAt
        var settingsSynced = false
        if config.syncReaderSettings, let remoteSettingsObj, remoteSettingsUpdatedAt > localSettingsUpdatedAt {
            effectiveSettings = repository.applySyncedSettingsJson(local: localSettings, obj: remoteSettingsObj)
            effectiveSettingsUpdatedAt = remoteSettingsUpdatedAt
            repository.saveSettingsWithTimestamp(effectiveSettings, timestampMs: effectiveSettingsUpdatedAt)
            settingsSynced = true
        }

        // Step E: Persist merged state locally
        repository.saveBooks(mergedBooks)
        repository.saveAllBookmarks(mergedBookmarks)
        repository.saveDeletedBookmarkIds(mergedDeletedBookmarks)

        // Step F: Upload merged sync_state.json to cloud
        await onProgress("正在上傳合併後的雲端同步紀錄…")
        let allRemoteRecords = mergedBooks.map { toRemoteBookRecord($0) } + preservedRemoteOnlyRecords
        let stateObj = buildSyncStateJson(
            books: allRemoteRecords,
            bookmarks: mergedBookmarks,
            deletedBookmarkIds: mergedDeletedBookmarks,
            settings: config.syncReaderSettings ? effectiveSettings : nil,
            settingsUpdatedAtMs: effectiveSettingsUpdatedAt
        )
        let stateData = try JSONSerialization.data(withJSONObject: stateObj, options: [.prettyPrinted])
        try await client.uploadBytes(
            remotePath: Self.stateFile,
            data: stateData,
            contentType: "application/json; charset=utf-8"
        )

        let report = SyncReport(
            provider: config.activeProvider,
            uploadedBooks: uploadedBooks,
            downloadedBooks: downloadedBooks,
            mergedBooksCount: mergedBooks.count,
            mergedBookmarksCount: mergedBookmarks.count,
            settingsSynced: settingsSynced || config.syncReaderSettings,
            errors: errors
        )

        var refreshedCfg = repository.loadCloudSyncConfig()
        refreshedCfg.lastSyncTimeMs = BookItem.nowMs()
        refreshedCfg.lastSyncSummary = report.toDisplaySummary()
        repository.saveCloudSyncConfig(refreshedCfg)
        onConfigUpdated(refreshedCfg)

        return report
    }

    // MARK: - Serialization & Matching

    private struct RemoteBookRecord {
        var id: String
        var title: String
        var author: String
        var format: BookFormat
        var contentType: BookContentType
        var ext: String
        var remoteFileName: String
        var tags: [String]
        var lastChapterIndex: Int
        var lastCharOffset: Int
        var lastPageIndex: Int
        var lastReadTime: Int64
        var addedTime: Int64
        var sourceFileName: String
        var fileSizeBytes: Int64
        var contentHash: String
        var readingProgress: Float
        var isRead: Bool
        var hasStartedReading: Bool
    }

    private func resolveBookExtension(_ book: BookItem) -> String {
        let rawExt = URL(fileURLWithPath: book.localPath).pathExtension.lowercased()
        return rawExt.isEmpty ? book.format.rawValue.lowercased() : rawExt
    }

    private func buildRemoteBookFileName(_ book: BookItem) -> String {
        "\(book.id).\(resolveBookExtension(book))"
    }

    private func toRemoteBookRecord(_ book: BookItem) -> RemoteBookRecord {
        let ext = resolveBookExtension(book)
        return RemoteBookRecord(
            id: book.id,
            title: book.title,
            author: book.author,
            format: book.format,
            contentType: book.contentType,
            ext: ext,
            remoteFileName: "\(book.id).\(ext)",
            tags: repository.sanitizeTags(book.tags),
            lastChapterIndex: book.lastChapterIndex,
            lastCharOffset: book.lastCharOffset,
            lastPageIndex: book.lastPageIndex,
            lastReadTime: book.lastReadTime,
            addedTime: book.addedTime,
            sourceFileName: book.sourceFileName,
            fileSizeBytes: book.fileSizeBytes,
            contentHash: book.contentHash,
            readingProgress: book.readingProgress,
            isRead: book.isRead,
            hasStartedReading: book.hasStartedReading
        )
    }

    private func findMatchingRemoteBook(
        local: BookItem,
        remoteBooks: [RemoteBookRecord],
        alreadyMatchedIds: Set<String>
    ) -> RemoteBookRecord? {
        let candidates = remoteBooks.filter { !alreadyMatchedIds.contains($0.id) }
        if let exact = candidates.first(where: { $0.id == local.id }) {
            return exact
        }
        if !local.contentHash.isEmpty,
           let byHash = candidates.first(where: { !$0.contentHash.isEmpty && $0.contentHash == local.contentHash }) {
            return byHash
        }
        if !local.sourceFileName.isEmpty && local.fileSizeBytes > 0,
           let byNameSize = candidates.first(where: {
               $0.sourceFileName.caseInsensitiveCompare(local.sourceFileName) == .orderedSame &&
                   $0.fileSizeBytes == local.fileSizeBytes
           }) {
            return byNameSize
        }
        return nil
    }

    private func parseRemoteBooks(_ root: [String: Any]?) -> [RemoteBookRecord] {
        guard let arr = root?["books"] as? [[String: Any]] else { return [] }
        let now = BookItem.nowMs()
        return arr.compactMap { obj in
            let id = ((obj["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let fmt = BookFormat(rawValue: (obj["format"] as? String) ?? "TXT") ?? .TXT
            let ct = BookContentType(rawValue: (obj["contentType"] as? String) ?? "TEXT") ?? .TEXT
            let ext = (obj["ext"] as? String) ?? fmt.rawValue.lowercased()
            let tags: [String] = {
                if let tArr = obj["tags"] as? [String] {
                    return repository.sanitizeTags(tArr)
                }
                let legacy = ((obj["groupName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return (!legacy.isEmpty && legacy != "未分類") ? [legacy] : []
            }()
            let prog = min(1.0, max(0.0, (obj["readingProgress"] as? NSNumber)?.floatValue ?? 0))

            return RemoteBookRecord(
                id: id,
                title: (obj["title"] as? String) ?? "未命名",
                author: (obj["author"] as? String) ?? "未知作者",
                format: fmt,
                contentType: ct,
                ext: ext,
                remoteFileName: (obj["remoteFileName"] as? String) ?? "\(id).\(fmt.rawValue.lowercased())",
                tags: tags,
                lastChapterIndex: (obj["lastChapterIndex"] as? NSNumber)?.intValue ?? 0,
                lastCharOffset: (obj["lastCharOffset"] as? NSNumber)?.intValue ?? 0,
                lastPageIndex: (obj["lastPageIndex"] as? NSNumber)?.intValue ?? 0,
                lastReadTime: (obj["lastReadTime"] as? NSNumber)?.int64Value ?? 0,
                addedTime: (obj["addedTime"] as? NSNumber)?.int64Value ?? now,
                sourceFileName: (obj["sourceFileName"] as? String) ?? "",
                fileSizeBytes: (obj["fileSizeBytes"] as? NSNumber)?.int64Value ?? 0,
                contentHash: (obj["contentHash"] as? String) ?? "",
                readingProgress: prog,
                isRead: (obj["isRead"] as? Bool) ?? false,
                hasStartedReading: (obj["hasStartedReading"] as? Bool) ?? false
            )
        }
    }

    private func parseRemoteBookmarks(_ root: [String: Any]?) -> [BookmarkItem] {
        guard let arr = root?["bookmarks"] as? [[String: Any]] else { return [] }
        let now = BookItem.nowMs()
        return arr.compactMap { obj in
            let id = ((obj["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bookId = ((obj["bookId"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty && !bookId.isEmpty else { return nil }
            return BookmarkItem(
                id: id,
                bookId: bookId,
                chapterIndex: (obj["chapterIndex"] as? NSNumber)?.intValue ?? 0,
                chapterTitle: (obj["chapterTitle"] as? String) ?? "",
                charOffset: (obj["charOffset"] as? NSNumber)?.intValue ?? 0,
                preview: (obj["preview"] as? String) ?? "",
                createdAt: (obj["createdAt"] as? NSNumber)?.int64Value ?? now
            )
        }
    }

    private func parseRemoteStringSet(_ root: [String: Any]?, key: String) -> Set<String> {
        guard let arr = root?[key] as? [String] else { return [] }
        return Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func buildSyncStateJson(
        books: [RemoteBookRecord],
        bookmarks: [BookmarkItem],
        deletedBookmarkIds: Set<String>,
        settings: ReaderSettings?,
        settingsUpdatedAtMs: Int64
    ) -> [String: Any] {
        let booksArr: [[String: Any]] = books.map { b in
            [
                "id": b.id,
                "title": b.title,
                "author": b.author,
                "format": b.format.rawValue,
                "contentType": b.contentType.rawValue,
                "ext": b.ext,
                "remoteFileName": b.remoteFileName,
                "tags": repository.sanitizeTags(b.tags),
                "lastChapterIndex": b.lastChapterIndex,
                "lastCharOffset": b.lastCharOffset,
                "lastPageIndex": b.lastPageIndex,
                "lastReadTime": b.lastReadTime,
                "addedTime": b.addedTime,
                "sourceFileName": b.sourceFileName,
                "fileSizeBytes": b.fileSizeBytes,
                "contentHash": b.contentHash,
                "readingProgress": Double(b.readingProgress),
                "isRead": b.isRead,
                "hasStartedReading": b.hasStartedReading
            ]
        }

        let bmArr: [[String: Any]] = bookmarks.map { bm in
            [
                "id": bm.id,
                "bookId": bm.bookId,
                "chapterIndex": bm.chapterIndex,
                "chapterTitle": bm.chapterTitle,
                "charOffset": bm.charOffset,
                "preview": bm.preview,
                "createdAt": bm.createdAt
            ]
        }

        var root: [String: Any] = [
            "schemaVersion": 1,
            "updatedAtMs": BookItem.nowMs(),
            "books": booksArr,
            "bookmarks": bmArr,
            "deletedBookmarkIds": Array(deletedBookmarkIds),
            "settingsUpdatedAtMs": settingsUpdatedAtMs
        ]
        if let settings {
            root["settings"] = repository.serializePortableSettings(settings)
        }
        return root
    }
}
