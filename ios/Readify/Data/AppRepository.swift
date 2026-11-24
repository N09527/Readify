import CryptoKit
import Foundation

final class AppRepository {
    static let shared = AppRepository()

    let documentsDir: URL
    let appSupportDir: URL
    let booksDir: URL
    let coversDir: URL

    private let booksJsonURL: URL
    private let bookmarksJsonURL: URL
    private let settingsJsonURL: URL
    private let ioLock = NSRecursiveLock()

    private struct FolderFileCandidate {
        var url: URL
        var displayName: String
        var sizeBytes: Int64
        var relativePath: String
    }

    init() {
        let fm = FileManager.default
        self.documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.appSupportDir = baseSupport.appendingPathComponent("Readify", isDirectory: true)
        self.booksDir = documentsDir.appendingPathComponent("Books", isDirectory: true)
        self.coversDir = appSupportDir.appendingPathComponent("Covers", isDirectory: true)

        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        // Ensure Fonts folder exists so Readify immediately appears in iOS Files app
        _ = FontManager.publicFontsDirectory

        self.booksJsonURL = appSupportDir.appendingPathComponent("bookshelf.json")
        self.bookmarksJsonURL = appSupportDir.appendingPathComponent("bookmarks.json")
        self.settingsJsonURL = appSupportDir.appendingPathComponent("reader_settings.json")
    }

    // MARK: - Container-Resilient Path Resolution

    func resolveBookFileURL(_ book: BookItem) -> URL {
        resolveStoredPath(book.localPath, defaultBase: documentsDir)
    }

    func resolveCoverFileURL(_ book: BookItem) -> URL? {
        guard let raw = book.coverPath, !raw.isEmpty else { return nil }
        let url = resolveStoredPath(raw, defaultBase: appSupportDir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func resolveStoredPath(_ rawPath: String, defaultBase: URL) -> URL {
        let fm = FileManager.default
        if rawPath.hasPrefix("/") {
            if fm.fileExists(atPath: rawPath) {
                return URL(fileURLWithPath: rawPath)
            }
            if let r = rawPath.range(of: "/Documents/") {
                let rel = String(rawPath[r.upperBound...])
                let cand = documentsDir.appendingPathComponent(rel)
                if fm.fileExists(atPath: cand.path) { return cand }
            }
            if let r = rawPath.range(of: "/Application Support/Readify/") {
                let rel = String(rawPath[r.upperBound...])
                let cand = appSupportDir.appendingPathComponent(rel)
                if fm.fileExists(atPath: cand.path) { return cand }
            }
            return URL(fileURLWithPath: rawPath)
        }
        let primary = defaultBase.appendingPathComponent(rawPath)
        if fm.fileExists(atPath: primary.path) { return primary }
        let altDoc = documentsDir.appendingPathComponent(rawPath)
        if fm.fileExists(atPath: altDoc.path) { return altDoc }
        let altSup = appSupportDir.appendingPathComponent(rawPath)
        return altSup
    }

    // MARK: - Fast Content Fingerprint

    func computeFastFingerprint(fileURL: URL) -> String {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? fh.close() }

        let len = (try? fh.seekToEnd()) ?? 0
        var hasher = SHA256()
        if let lenData = "\(len)".data(using: .utf8) {
            hasher.update(data: lenData)
        }

        let chunk: UInt64 = 64 * 1024
        let headLen = Int(min(chunk, len))
        if headLen > 0 {
            try? fh.seek(toOffset: 0)
            if let d1 = try? fh.read(upToCount: headLen) {
                hasher.update(data: d1)
            }
        }
        if len > chunk {
            let tailLen = min(chunk, len - chunk)
            try? fh.seek(toOffset: len - tailLen)
            if let d2 = try? fh.read(upToCount: Int(tailLen)) {
                hasher.update(data: d2)
            }
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(24))
    }

    func sanitizeTags(_ rawTags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in rawTags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "未分類" && seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    static func resolveSupportedFormat(fileName: String) -> BookFormat? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "txt": return .TXT
        case "epub": return .EPUB
        case "pdf": return .PDF
        case "cbz": return .CBZ
        case "cbr", "rar": return .CBR
        case "zip": return .ZIP
        case "mobi", "prc": return .MOBI
        case "azw3", "kf8": return .AZW3
        default: return nil
        }
    }

    // MARK: - Bookshelf Persistence

    func loadBooks() -> [BookItem] {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard FileManager.default.fileExists(atPath: booksJsonURL.path),
              let data = try? Data(contentsOf: booksJsonURL),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }

        var items: [BookItem] = []
        for obj in arr {
            guard let id = obj["id"] as? String,
                  let title = obj["title"] as? String,
                  let localPath = obj["localPath"] as? String else { continue }

            let fmtRaw = (obj["format"] as? String) ?? "TXT"
            let fmt = BookFormat(rawValue: fmtRaw) ?? .TXT
            let defaultContentType: BookContentType = {
                switch fmt {
                case .PDF: return .PDF
                case .CBZ, .CBR, .ZIP: return .COMIC
                default: return .TEXT
                }
            }()
            let ctRaw = (obj["contentType"] as? String) ?? ""
            let contentType = BookContentType(rawValue: ctRaw) ?? defaultContentType

            let lastCh = (obj["lastChapterIndex"] as? NSNumber)?.intValue ?? 0
            let lastOff = (obj["lastCharOffset"] as? NSNumber)?.intValue ?? 0
            let lastPg = (obj["lastPageIndex"] as? NSNumber)?.intValue ?? 0
            let rawProg = (obj["readingProgress"] as? NSNumber)?.floatValue ?? 0
            let progress = min(1.0, max(0.0, rawProg))
            let isRead = (obj["isRead"] as? Bool) ?? (progress >= 0.99)
            let hasStarted = (obj["hasStartedReading"] as? Bool)
                ?? (isRead || progress > 0 || lastCh > 0 || lastOff > 0 || lastPg > 0)

            let parsedTags: [String]
            if let tagsArr = obj["tags"] as? [String] {
                parsedTags = sanitizeTags(tagsArr)
            } else if let legacy = (obj["groupName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !legacy.isEmpty && legacy != "未分類" {
                parsedTags = [legacy]
            } else {
                parsedTags = []
            }

            let coverRaw = (obj["coverPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let now = BookItem.nowMs()

            let item = BookItem(
                id: id,
                title: title,
                author: (obj["author"] as? String) ?? "未知作者",
                format: fmt,
                contentType: contentType,
                localPath: localPath,
                coverPath: (coverRaw?.isEmpty == false) ? coverRaw : nil,
                tags: parsedTags,
                lastChapterIndex: lastCh,
                lastCharOffset: lastOff,
                lastPageIndex: lastPg,
                lastReadTime: (obj["lastReadTime"] as? NSNumber)?.int64Value ?? now,
                addedTime: (obj["addedTime"] as? NSNumber)?.int64Value ?? now,
                sourceFileName: (obj["sourceFileName"] as? String) ?? "",
                fileSizeBytes: (obj["fileSizeBytes"] as? NSNumber)?.int64Value ?? 0,
                contentHash: (obj["contentHash"] as? String) ?? "",
                readingProgress: progress,
                isRead: isRead,
                hasStartedReading: hasStarted
            )

            let resolvedURL = resolveBookFileURL(item)
            if FileManager.default.fileExists(atPath: resolvedURL.path) {
                items.append(item)
            }
        }
        return items
    }

    func saveBooks(_ books: [BookItem]) {
        ioLock.lock()
        defer { ioLock.unlock() }

        let arr: [[String: Any]] = books.map { b in
            [
                "id": b.id,
                "title": b.title,
                "author": b.author,
                "format": b.format.rawValue,
                "contentType": b.contentType.rawValue,
                "localPath": b.localPath,
                "coverPath": b.coverPath ?? "",
                "tags": sanitizeTags(b.tags),
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
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
            try? data.write(to: booksJsonURL, options: .atomic)
        }
    }

    // MARK: - Import Books (Files, Folders, AirDrop / Open-In, & Finder File Sharing)

    private func isDuplicateBook(existing: [BookItem], displayName: String, sizeBytes: Int64) -> Bool {
        guard !displayName.isEmpty else { return false }
        return existing.contains { item in
            item.sourceFileName.caseInsensitiveCompare(displayName) == .orderedSame &&
                (sizeBytes <= 0 || item.fileSizeBytes <= 0 || item.fileSizeBytes == sizeBytes)
        }
    }

    private func copyAndParseBook(
        sourceURL: URL,
        displayName: String,
        sizeBytes: Int64,
        format: BookFormat,
        moveInsteadOfCopy: Bool = false
    ) throws -> BookItem {
        let rawExt = URL(fileURLWithPath: displayName).pathExtension.lowercased()
        let ext = rawExt.isEmpty ? format.rawValue.lowercased() : rawExt
        let id = UUID().uuidString.lowercased()
        let relativeBookPath = "Books/\(id).\(ext)"
        let destURL = documentsDir.appendingPathComponent(relativeBookPath)

        let fm = FileManager.default
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }

        // Trigger download if file is an evicted iCloud Ubiquitous item
        try? fm.startDownloadingUbiquitousItem(at: sourceURL)

        if moveInsteadOfCopy {
            try fm.moveItem(at: sourceURL, to: destURL)
        } else {
            var coordError: NSError?
            var copyErr: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordError) { coordURL in
                do {
                    try fm.copyItem(at: coordURL, to: destURL)
                } catch {
                    copyErr = error
                }
            }
            if let copyErr { throw copyErr }
            if !fm.fileExists(atPath: destURL.path) {
                try fm.copyItem(at: sourceURL, to: destURL)
            }
        }

        let attrs = try? fm.attributesOfItem(atPath: destURL.path)
        let actualSize = (attrs?[.size] as? NSNumber)?.int64Value ?? sizeBytes
        let hash = computeFastFingerprint(fileURL: destURL)
        let baseTitle = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let fallbackTitle = baseTitle.isEmpty ? displayName : baseTitle

        let parsed = BookParser.parseMetadataAndCover(fileURL: destURL, format: format, fallbackTitle: fallbackTitle)

        var relativeCoverPath: String?
        if let coverBytes = parsed.coverBytes, !coverBytes.isEmpty {
            let relCover = "Covers/\(id).img"
            let coverURL = appSupportDir.appendingPathComponent(relCover)
            if (try? coverBytes.write(to: coverURL, options: .atomic)) != nil {
                relativeCoverPath = relCover
            }
        }

        let now = BookItem.nowMs()
        let finalTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAuthor = parsed.author.trimmingCharacters(in: .whitespacesAndNewlines)

        return BookItem(
            id: id,
            title: finalTitle.isEmpty ? fallbackTitle : finalTitle,
            author: finalAuthor.isEmpty ? "未知作者" : finalAuthor,
            format: format,
            contentType: parsed.contentType,
            localPath: relativeBookPath,
            coverPath: relativeCoverPath,
            tags: [],
            lastReadTime: now,
            addedTime: now,
            sourceFileName: displayName,
            fileSizeBytes: actualSize,
            contentHash: hash
        )
    }

    func importBooksFromURLs(
        _ urls: [URL],
        onProgress: @escaping @Sendable (Int, Int, String) async -> Void
    ) async -> BatchImportResult {
        guard !urls.isEmpty else {
            return BatchImportResult(importedCount: 0, skippedDuplicateCount: 0, unsupportedCount: 0, failedCount: 0)
        }

        return await Task.detached(priority: .userInitiated) { [self] in
            var currentBooks = self.loadBooks()
            var imported = 0
            var skippedDup = 0
            var unsupported = 0
            var failed = 0
            var lastTitle: String?

            for (idx, url) in urls.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let displayName = url.lastPathComponent.isEmpty ? "未命名書籍" : url.lastPathComponent
                await onProgress(idx + 1, urls.count, displayName)

                guard let format = Self.resolveSupportedFormat(fileName: displayName) else {
                    unsupported += 1
                    continue
                }

                let resVals = try? url.resourceValues(forKeys: [.fileSizeKey])
                let sizeBytes = Int64(resVals?.fileSize ?? 0)
                if self.isDuplicateBook(existing: currentBooks, displayName: displayName, sizeBytes: sizeBytes) {
                    skippedDup += 1
                    continue
                }

                let isInboxItem = url.path.contains("/Documents/Inbox/")
                do {
                    let item = try self.copyAndParseBook(
                        sourceURL: url,
                        displayName: displayName,
                        sizeBytes: sizeBytes,
                        format: format,
                        moveInsteadOfCopy: isInboxItem
                    )
                    currentBooks.insert(item, at: 0)
                    imported += 1
                    lastTitle = item.title
                    if imported % 3 == 0 {
                        self.saveBooks(currentBooks)
                    }
                } catch {
                    failed += 1
                }
            }

            if imported > 0 {
                self.saveBooks(currentBooks)
            }
            return BatchImportResult(
                importedCount: imported,
                skippedDuplicateCount: skippedDup,
                unsupportedCount: unsupported,
                failedCount: failed,
                lastImportedTitle: lastTitle
            )
        }.value
    }

    func importBooksFromFolderURL(
        _ folderURL: URL,
        onProgress: @escaping @Sendable (Int, Int, String) async -> Void
    ) async -> BatchImportResult {
        await Task.detached(priority: .userInitiated) { [self] in
            let scoped = folderURL.startAccessingSecurityScopedResource()
            defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

            var candidates: [FolderFileCandidate] = []
            self.collectFolderBooksRecursively(
                dirURL: folderURL,
                relativePrefix: "",
                maxDepth: 6,
                out: &candidates
            )

            guard !candidates.isEmpty else {
                return BatchImportResult(importedCount: 0, skippedDuplicateCount: 0, unsupportedCount: 0, failedCount: 0)
            }
            candidates.sort { NaturalSort.lessThan($0.relativePath, $1.relativePath) }

            var currentBooks = self.loadBooks()
            var imported = 0
            var skippedDup = 0
            var failed = 0
            var lastTitle: String?

            for (idx, candidate) in candidates.enumerated() {
                await onProgress(idx + 1, candidates.count, candidate.displayName)
                guard let format = Self.resolveSupportedFormat(fileName: candidate.displayName) else { continue }
                if self.isDuplicateBook(existing: currentBooks, displayName: candidate.displayName, sizeBytes: candidate.sizeBytes) {
                    skippedDup += 1
                    continue
                }

                let fileScoped = candidate.url.startAccessingSecurityScopedResource()
                defer { if fileScoped { candidate.url.stopAccessingSecurityScopedResource() } }

                do {
                    let item = try self.copyAndParseBook(
                        sourceURL: candidate.url,
                        displayName: candidate.displayName,
                        sizeBytes: candidate.sizeBytes,
                        format: format
                    )
                    currentBooks.insert(item, at: 0)
                    imported += 1
                    lastTitle = item.title
                    if imported % 3 == 0 {
                        self.saveBooks(currentBooks)
                    }
                } catch {
                    failed += 1
                }
            }

            if imported > 0 {
                self.saveBooks(currentBooks)
            }
            return BatchImportResult(
                importedCount: imported,
                skippedDuplicateCount: skippedDup,
                unsupportedCount: 0,
                failedCount: failed,
                lastImportedTitle: lastTitle
            )
        }.value
    }

    private func collectFolderBooksRecursively(
        dirURL: URL,
        relativePrefix: String,
        maxDepth: Int,
        out: inout [FolderFileCandidate]
    ) {
        guard maxDepth >= 0 else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            if name.isEmpty || name.hasPrefix(".") { continue }
            let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let relPath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"

            if vals?.isDirectory == true {
                if name.caseInsensitiveCompare("__MACOSX") != .orderedSame {
                    collectFolderBooksRecursively(dirURL: child, relativePrefix: relPath, maxDepth: maxDepth - 1, out: &out)
                }
            } else if Self.resolveSupportedFormat(fileName: name) != nil {
                let size = Int64(vals?.fileSize ?? 0)
                out.append(FolderFileCandidate(url: child, displayName: name, sizeBytes: size, relativePath: relPath))
            }
        }
    }

    /// Auto-imports any book files dropped directly into the `Readify` folder via iOS Files app or Mac Finder File Sharing.
    func scanDroppedFilesInDocuments() async -> Int {
        await Task.detached(priority: .utility) { [self] in
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: self.documentsDir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            var currentBooks = self.loadBooks()
            var imported = 0
            for url in items {
                let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard vals?.isRegularFile == true else { continue }
                let name = url.lastPathComponent
                guard let format = Self.resolveSupportedFormat(fileName: name) else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                if !self.isDuplicateBook(existing: currentBooks, displayName: name, sizeBytes: size) {
                    if let book = try? self.copyAndParseBook(
                        sourceURL: url,
                        displayName: name,
                        sizeBytes: size,
                        format: format,
                        moveInsteadOfCopy: true
                    ) {
                        currentBooks.insert(book, at: 0)
                        imported += 1
                    }
                } else {
                    try? fm.removeItem(at: url)
                }
            }
            if imported > 0 {
                self.saveBooks(currentBooks)
            }
            return imported
        }.value
    }

    // MARK: - Book Mutations & Progress

    func refreshContentTypeIfNeeded(book: BookItem) async -> BookItem {
        guard book.format == .EPUB && book.contentType == .TEXT else { return book }
        return await Task.detached(priority: .userInitiated) { [self] in
            let url = self.resolveBookFileURL(book)
            let info = BookParser.inspectEpubComic(fileURL: url, fallbackTitle: book.title)
            if info.isComic {
                var updated = book
                updated.contentType = .COMIC
                let list = self.loadBooks().map { $0.id == book.id ? updated : $0 }
                self.saveBooks(list)
                return updated
            }
            return book
        }.value
    }

    func repairMissingMobiCovers() async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            let current = self.loadBooks()
            var anyChanged = false
            let updated: [BookItem] = current.map { book in
                guard book.format == .MOBI || book.format == .AZW3 else { return book }
                let missingCover = self.resolveCoverFileURL(book) == nil
                guard missingCover else { return book }
                let fileURL = self.resolveBookFileURL(book)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return book }

                let parsed = BookParser.parseMetadataAndCover(fileURL: fileURL, format: book.format, fallbackTitle: book.title)
                var copy = book
                if let coverBytes = parsed.coverBytes, !coverBytes.isEmpty {
                    let relCover = "Covers/\(book.id).img"
                    let coverURL = self.appSupportDir.appendingPathComponent(relCover)
                    if (try? coverBytes.write(to: coverURL, options: .atomic)) != nil {
                        copy.coverPath = relCover
                        anyChanged = true
                    }
                }
                if (copy.author == "未知作者" || copy.author == "Kindle 電子書") &&
                    !parsed.author.isEmpty && parsed.author != "Kindle 電子書" {
                    copy.author = parsed.author
                    anyChanged = true
                }
                return copy
            }
            if anyChanged {
                self.saveBooks(updated)
            }
            return anyChanged
        }.value
    }

    func deleteBook(_ bookId: String) {
        deleteBooks([bookId])
    }

    func deleteBooks(_ bookIds: Set<String>) {
        guard !bookIds.isEmpty else { return }
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let current = loadBooks()
        for target in current where bookIds.contains(target.id) {
            try? fm.removeItem(at: resolveBookFileURL(target))
            if let coverURL = resolveCoverFileURL(target) {
                try? fm.removeItem(at: coverURL)
            }
            let cbrCache = cachesDir.appendingPathComponent("cbr_cache/\(target.id)")
            try? fm.removeItem(at: cbrCache)
        }
        saveBooks(current.filter { !bookIds.contains($0.id) })
        let allBm = loadAllBookmarks()
        saveAllBookmarks(allBm.filter { !bookIds.contains($0.bookId) })
    }

    func updateBookProgress(bookId: String, chapterIndex: Int, charOffset: Int, progressFraction: Float) {
        let clamped = min(1.0, max(0.0, progressFraction))
        let now = BookItem.nowMs()
        let updated = loadBooks().map { book -> BookItem in
            guard book.id == bookId else { return book }
            var copy = book
            let nowRead = book.isRead || clamped >= 0.99
            copy.lastChapterIndex = chapterIndex
            copy.lastCharOffset = charOffset
            copy.readingProgress = (nowRead && clamped < 0.99) ? max(book.readingProgress, clamped) : clamped
            copy.isRead = nowRead
            copy.hasStartedReading = true
            copy.lastReadTime = now
            return copy
        }
        saveBooks(updated)
    }

    func updateVisualBookProgress(bookId: String, pageIndex: Int, progressFraction: Float) {
        let clamped = min(1.0, max(0.0, progressFraction))
        let now = BookItem.nowMs()
        let updated = loadBooks().map { book -> BookItem in
            guard book.id == bookId else { return book }
            var copy = book
            let nowRead = book.isRead || clamped >= 0.99
            copy.lastPageIndex = pageIndex
            copy.readingProgress = (nowRead && clamped < 0.99) ? max(book.readingProgress, clamped) : clamped
            copy.isRead = nowRead
            copy.hasStartedReading = true
            copy.lastReadTime = now
            return copy
        }
        saveBooks(updated)
    }

    func setBookReadStatus(bookId: String, isRead: Bool) {
        setBooksReadStatus([bookId], isRead: isRead)
    }

    func setBooksReadStatus(_ bookIds: Set<String>, isRead: Bool) {
        guard !bookIds.isEmpty else { return }
        let now = BookItem.nowMs()
        let updated = loadBooks().map { book -> BookItem in
            guard bookIds.contains(book.id) else { return book }
            var copy = book
            if isRead {
                copy.isRead = true
                copy.hasStartedReading = true
                copy.readingProgress = 1.0
                copy.lastReadTime = now
            } else {
                copy.isRead = false
                copy.hasStartedReading = false
                copy.readingProgress = 0.0
                copy.lastChapterIndex = 0
                copy.lastCharOffset = 0
                copy.lastPageIndex = 0
                copy.lastReadTime = now
            }
            return copy
        }
        saveBooks(updated)
    }

    func updateBookTags(bookId: String, newTags: [String]) {
        let clean = sanitizeTags(newTags)
        let updated = loadBooks().map { book -> BookItem in
            guard book.id == bookId else { return book }
            var copy = book
            copy.tags = clean
            return copy
        }
        saveBooks(updated)
    }

    func addTagsToBooks(_ bookIds: Set<String>, tagsToAdd: [String]) {
        let clean = sanitizeTags(tagsToAdd)
        guard !bookIds.isEmpty && !clean.isEmpty else { return }
        let updated = loadBooks().map { book -> BookItem in
            guard bookIds.contains(book.id) else { return book }
            var copy = book
            copy.tags = sanitizeTags(book.tags + clean)
            return copy
        }
        saveBooks(updated)
    }

    func removeTagsFromBooks(_ bookIds: Set<String>, tagsToRemove: [String]) {
        let removeSet = Set(sanitizeTags(tagsToRemove))
        guard !bookIds.isEmpty && !removeSet.isEmpty else { return }
        let updated = loadBooks().map { book -> BookItem in
            guard bookIds.contains(book.id) else { return book }
            var copy = book
            copy.tags = book.tags.filter { !removeSet.contains($0) }
            return copy
        }
        saveBooks(updated)
    }

    func updateBookContentType(bookId: String, newType: BookContentType) {
        let updated = loadBooks().map { book -> BookItem in
            guard book.id == bookId else { return book }
            var copy = book
            copy.contentType = newType
            return copy
        }
        saveBooks(updated)
    }

    // MARK: - Bookmarks

    func loadAllBookmarks() -> [BookmarkItem] {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard FileManager.default.fileExists(atPath: bookmarksJsonURL.path),
              let data = try? Data(contentsOf: bookmarksJsonURL),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }

        let now = BookItem.nowMs()
        return arr.compactMap { obj in
            guard let id = obj["id"] as? String,
                  let bookId = obj["bookId"] as? String,
                  let chIdx = (obj["chapterIndex"] as? NSNumber)?.intValue,
                  let off = (obj["charOffset"] as? NSNumber)?.intValue else {
                return nil
            }
            return BookmarkItem(
                id: id,
                bookId: bookId,
                chapterIndex: chIdx,
                chapterTitle: (obj["chapterTitle"] as? String) ?? "",
                charOffset: off,
                preview: (obj["preview"] as? String) ?? "",
                createdAt: (obj["createdAt"] as? NSNumber)?.int64Value ?? now
            )
        }
    }

    func saveAllBookmarks(_ items: [BookmarkItem]) {
        ioLock.lock()
        defer { ioLock.unlock() }

        let arr: [[String: Any]] = items.map { bm in
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
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
            try? data.write(to: bookmarksJsonURL, options: .atomic)
        }
    }

    func loadBookmarksForBook(_ bookId: String) -> [BookmarkItem] {
        loadAllBookmarks()
            .filter { $0.bookId == bookId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func addBookmark(_ bookmark: BookmarkItem) {
        var list = loadAllBookmarks()
        list.insert(bookmark, at: 0)
        saveAllBookmarks(list)
    }

    func deleteBookmark(_ bookmarkId: String) {
        saveAllBookmarks(loadAllBookmarks().filter { $0.id != bookmarkId })
    }

    // MARK: - Settings Persistence

    func loadSettings() -> ReaderSettings {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard FileManager.default.fileExists(atPath: settingsJsonURL.path),
              let data = try? Data(contentsOf: settingsJsonURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ReaderSettings()
        }

        let tapZones: [TapAction] = {
            if let arr = obj["tapZones"] as? [String], arr.count == 9 {
                let mapped = arr.compactMap { TapAction(rawValue: $0) }
                if mapped.count == 9 { return mapped }
            }
            return ReaderSettings.defaultVerticalTapZones()
        }()

        let rawFontPath = (obj["customFontPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validFontPath: String? = {
            guard let p = rawFontPath, !p.isEmpty else { return nil }
            return FontManager.resolveFontFileURL(p) != nil ? p : nil
        }()

        let rawFontName = (obj["customFontName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBookmark = (obj["customFontFolderBookmark"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ReaderSettings(
            writingMode: WritingMode(rawValue: (obj["writingMode"] as? String) ?? "") ?? .VERTICAL,
            verticalNaturalSwipe: (obj["verticalNaturalSwipe"] as? Bool) ?? true,
            dualPageMode: DualPageMode(rawValue: (obj["dualPageMode"] as? String) ?? "") ?? .AUTO,
            showSpineShadow: (obj["showSpineShadow"] as? Bool) ?? true,
            pageTurnAnimation: PageTurnAnimation(rawValue: (obj["pageTurnAnimation"] as? String) ?? "") ?? .SIMULATION,
            eInkMode: (obj["eInkMode"] as? Bool) ?? false,
            theme: ReaderTheme(rawValue: (obj["theme"] as? String) ?? "") ?? .SEPIA,
            fontSizeSp: (obj["fontSizeSp"] as? NSNumber)?.floatValue ?? 20,
            fontBold: (obj["fontBold"] as? Bool) ?? false,
            letterSpacingEm: (obj["letterSpacingEm"] as? NSNumber)?.floatValue ?? 0.04,
            lineSpacingMultiplier: (obj["lineSpacingMultiplier"] as? NSNumber)?.floatValue ?? 1.65,
            paragraphSpacingEm: (obj["paragraphSpacingEm"] as? NSNumber)?.floatValue ?? 0.45,
            paragraphIndentChars: min(6, max(0, (obj["paragraphIndentChars"] as? NSNumber)?.intValue ?? 2)),
            marginHorizontalDp: (obj["marginHorizontalDp"] as? NSNumber)?.floatValue ?? 20,
            marginVerticalDp: (obj["marginVerticalDp"] as? NSNumber)?.floatValue ?? 24,
            customFontPath: validFontPath,
            customFontName: (validFontPath != nil && rawFontName?.isEmpty == false) ? rawFontName : nil,
            customFontFolderBookmark: (rawBookmark?.isEmpty == false) ? rawBookmark : nil,
            chineseConvertMode: ChineseConvertMode(rawValue: (obj["chineseConvertMode"] as? String) ?? "") ?? .ORIGINAL,
            volumeKeyPageTurn: (obj["volumeKeyPageTurn"] as? Bool) ?? true,
            comicRtl: (obj["comicRtl"] as? Bool) ?? true,
            pdfAutoCrop: (obj["pdfAutoCrop"] as? Bool) ?? false,
            pdfReflowMode: (obj["pdfReflowMode"] as? Bool) ?? false,
            pdfNightInvert: (obj["pdfNightInvert"] as? Bool) ?? false,
            shelfSortField: ShelfSortField(rawValue: (obj["shelfSortField"] as? String) ?? "") ?? .ADDED_TIME,
            shelfSortAscending: (obj["shelfSortAscending"] as? Bool) ?? false,
            tapZones: tapZones
        )
    }

    func saveSettings(_ settings: ReaderSettings) {
        ioLock.lock()
        defer { ioLock.unlock() }

        let obj: [String: Any] = [
            "writingMode": settings.writingMode.rawValue,
            "verticalNaturalSwipe": settings.verticalNaturalSwipe,
            "dualPageMode": settings.dualPageMode.rawValue,
            "showSpineShadow": settings.showSpineShadow,
            "pageTurnAnimation": settings.pageTurnAnimation.rawValue,
            "eInkMode": settings.eInkMode,
            "theme": settings.theme.rawValue,
            "fontSizeSp": Double(settings.fontSizeSp),
            "fontBold": settings.fontBold,
            "letterSpacingEm": Double(settings.letterSpacingEm),
            "lineSpacingMultiplier": Double(settings.lineSpacingMultiplier),
            "paragraphSpacingEm": Double(settings.paragraphSpacingEm),
            "paragraphIndentChars": settings.paragraphIndentChars,
            "marginHorizontalDp": Double(settings.marginHorizontalDp),
            "marginVerticalDp": Double(settings.marginVerticalDp),
            "customFontPath": settings.customFontPath ?? "",
            "customFontName": settings.customFontName ?? "",
            "customFontFolderBookmark": settings.customFontFolderBookmark ?? "",
            "chineseConvertMode": settings.chineseConvertMode.rawValue,
            "volumeKeyPageTurn": settings.volumeKeyPageTurn,
            "comicRtl": settings.comicRtl,
            "pdfAutoCrop": settings.pdfAutoCrop,
            "pdfReflowMode": settings.pdfReflowMode,
            "pdfNightInvert": settings.pdfNightInvert,
            "shelfSortField": settings.shelfSortField.rawValue,
            "shelfSortAscending": settings.shelfSortAscending,
            "tapZones": settings.tapZones.map { $0.rawValue }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: settingsJsonURL, options: .atomic)
        }
    }
}
