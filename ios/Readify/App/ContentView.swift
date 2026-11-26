import SwiftUI

struct ContentView: View {
    private let repository = AppRepository.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var books: [BookItem] = []
    @State private var settings = ReaderSettings()
    @State private var activeBook: BookItem?
    @State private var showCloudSync = false
    @State private var isReaderMenuVisible = false

    @State private var isOpeningBook = false
    @State private var isImporting = false
    @State private var importStatus: String?
    @State private var fontScanVersion: Int = 0
    @State private var activePicker: ActiveDocumentPicker?

    var body: some View {
        ZStack {
            Group {
                if showCloudSync {
                    CloudSyncScreen(
                        repository: repository,
                        eInkMode: settings.eInkMode,
                        onSyncCompleted: {
                            books = repository.loadBooks()
                            settings = repository.loadSettings()
                        },
                        onBack: {
                            books = repository.loadBooks()
                            settings = repository.loadSettings()
                            showCloudSync = false
                        }
                    )
                } else if let current = activeBook {
                    let useVisualReader: Bool = {
                        switch current.contentType {
                        case .COMIC: return true
                        case .PDF: return !settings.pdfReflowMode
                        case .TEXT: return false
                        }
                    }()

                    if useVisualReader {
                        VisualReaderScreen(
                            book: current,
                            repository: repository,
                            settings: settings,
                            onSettingsChange: { updated in
                                settings = updated
                                repository.saveSettings(updated)
                            },
                            onSwitchToPdfReflow: current.format == .PDF ? {
                                var updated = settings
                                updated.pdfReflowMode = true
                                settings = updated
                                repository.saveSettings(updated)
                            } : nil,
                            onMenuVisibilityChange: { vis in
                                isReaderMenuVisible = vis
                            },
                            onExitReader: handleExitReader
                        )
                        .persistentSystemOverlays(isReaderMenuVisible ? .automatic : .hidden)
                    } else {
                        ReaderScreen(
                            book: current,
                            repository: repository,
                            settings: settings,
                            fontScanVersion: fontScanVersion,
                            onSettingsChange: { updated in
                                settings = updated
                                repository.saveSettings(updated)
                            },
                            onImportFontFiles: {
                                activePicker = .fontFiles
                            },
                            onPickFontsFolder: {
                                activePicker = .fontFolder
                            },
                            onSwitchBackToPdfOriginal: current.format == .PDF ? {
                                var updated = settings
                                updated.pdfReflowMode = false
                                settings = updated
                                repository.saveSettings(updated)
                            } : nil,
                            onMenuVisibilityChange: { vis in
                                isReaderMenuVisible = vis
                            },
                            onExitReader: handleExitReader
                        )
                        .persistentSystemOverlays(isReaderMenuVisible ? .automatic : .hidden)
                    }
                } else {
                    BookshelfScreen(
                        books: books,
                        repository: repository,
                        eInkMode: settings.eInkMode,
                        sortField: settings.shelfSortField,
                        sortAscending: settings.shelfSortAscending,
                        coverSize: settings.shelfCoverSize,
                        isImporting: isImporting,
                        importStatusMessage: importStatus,
                        onDismissStatus: { importStatus = nil },
                        onImportFilesClick: { activePicker = .bookFiles },
                        onImportFolderClick: { activePicker = .bookFolder },
                        onScanFilesAppClick: { triggerScanDroppedFiles(showFeedbackWhenZero: true) },
                        onOpenBook: { book in
                            openBookWithOptionalAutoSync(book)
                        },
                        onDeleteBook: { book in
                            repository.deleteBook(book.id)
                            books = repository.loadBooks()
                        },
                        onBatchDeleteBooks: { ids in
                            repository.deleteBooks(ids)
                            books = repository.loadBooks()
                            importStatus = "已刪除 \(ids.count) 本書"
                        },
                        onUpdateBookTags: { book, tags in
                            repository.updateBookTags(bookId: book.id, newTags: tags)
                            books = repository.loadBooks()
                        },
                        onBatchAddTags: { ids, tags in
                            repository.addTagsToBooks(ids, tagsToAdd: tags)
                            books = repository.loadBooks()
                            let tagLabel = tags.map { "#\($0)" }.joined(separator: " ")
                            importStatus = "已為 \(ids.count) 本書加入標籤：\(tagLabel)"
                        },
                        onBatchRemoveTags: { ids, tags in
                            repository.removeTagsFromBooks(ids, tagsToRemove: tags)
                            books = repository.loadBooks()
                            let tagLabel = tags.map { "#\($0)" }.joined(separator: " ")
                            importStatus = "已從 \(ids.count) 本書移除標籤：\(tagLabel)"
                        },
                        onSetBookReadStatus: { book, isRead in
                            repository.setBookReadStatus(bookId: book.id, isRead: isRead)
                            books = repository.loadBooks()
                        },
                        onBatchSetReadStatus: { ids, isRead in
                            repository.setBooksReadStatus(ids, isRead: isRead)
                            books = repository.loadBooks()
                            importStatus = isRead ? "已將 \(ids.count) 本書標記為已讀" : "已將 \(ids.count) 本書標記為未讀"
                        },
                        onUpdateBookContentType: { book, newType in
                            repository.updateBookContentType(bookId: book.id, newType: newType)
                            books = repository.loadBooks()
                        },
                        onSortChange: { field, asc in
                            var updated = settings
                            updated.shelfSortField = field
                            updated.shelfSortAscending = asc
                            settings = updated
                            repository.saveSettings(updated)
                        },
                        onCoverSizeChange: { newSize in
                            guard settings.shelfCoverSize != newSize else { return }
                            var updated = settings
                            updated.shelfCoverSize = newSize
                            settings = updated
                            repository.saveSettings(updated)
                        },
                        onToggleEInkMode: {
                            var updated = settings
                            updated.eInkMode.toggle()
                            settings = updated
                            repository.saveSettings(updated)
                        },
                        onOpenCloudSync: {
                            showCloudSync = true
                        }
                    )
                }
            }

            if isOpeningBook {
                Color.black.opacity(settings.eInkMode ? 0.15 : 0.35)
                    .ignoresSafeArea()
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(settings.eInkMode ? .black : .primary)
                    Text("正在同步雲端最新閱讀進度…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(settings.eInkMode ? .black : .primary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(settings.eInkMode ? Color.white : Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(settings.eInkMode ? Color.black : Color.clear, lineWidth: 1.5)
                )
                .shadow(color: settings.eInkMode ? .clear : .black.opacity(0.18), radius: 12, y: 4)
            }
        }
        .statusBarHidden(activeBook != nil && !showCloudSync && !isReaderMenuVisible)
        .sheet(item: $activePicker) { pickerMode in
            DocumentPickerRepresentable(
                mode: pickerMode,
                onPickURLs: { urls in
                    activePicker = nil
                    handlePickedURLs(urls, mode: pickerMode)
                },
                onCancel: {
                    activePicker = nil
                }
            )
        }
        .onAppear {
            books = repository.loadBooks()
            settings = repository.loadSettings()
            Task {
                let importedDropped = await repository.scanDroppedFilesInDocuments()
                let repairedMobi = await repository.repairMissingMobiCovers()
                if importedDropped > 0 || repairedMobi {
                    await MainActor.run {
                        books = repository.loadBooks()
                        if importedDropped > 0 {
                            importStatus = "已自動匯入 Readify 資料夾內的 \(importedDropped) 本新書籍"
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                fontScanVersion += 1
                triggerScanDroppedFiles(showFeedbackWhenZero: false)
            }
        }
        .onOpenURL { url in
            handleOpenExternalURL(url)
        }
    }

    // MARK: - Open / Exit Reader Auto-Sync

    private func openBookWithOptionalAutoSync(_ book: BookItem) {
        guard !isOpeningBook else { return }
        let repo = repository
        let syncCfg = repo.loadCloudSyncConfig()

        Task {
            var targetBook = book
            if syncCfg.shouldAutoSync {
                await MainActor.run {
                    isOpeningBook = true
                }
                await awaitPreOpenSync(config: syncCfg)
                let latestBooks = repo.loadBooks()
                let latestSettings = repo.loadSettings()
                targetBook = latestBooks.first(where: { $0.id == book.id })
                    ?? latestBooks.first(where: { !book.contentHash.isEmpty && $0.contentHash == book.contentHash })
                    ?? latestBooks.first(where: { $0.localPath == book.localPath })
                    ?? book
                await MainActor.run {
                    books = latestBooks
                    settings = latestSettings
                    isOpeningBook = false
                }
            }

            let resolved = await repo.refreshContentTypeIfNeeded(book: targetBook)
            await MainActor.run {
                if resolved != targetBook {
                    books = repo.loadBooks()
                }
                isReaderMenuVisible = false
                activeBook = resolved
            }
        }
    }

    private func awaitPreOpenSync(config: CloudSyncConfig) async {
        let repo = repository
        let syncTask = Task.detached(priority: .userInitiated) {
            let manager = CloudSyncManager(repository: repo)
            _ = try? await manager.syncNow(
                config: config,
                syncBookFilesOverride: false,
                onConfigUpdated: { _ in },
                onProgress: { _ in }
            )
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await syncTask.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func handleExitReader() {
        guard activeBook != nil else { return }
        books = repository.loadBooks()
        isReaderMenuVisible = false
        activeBook = nil

        let repo = repository
        let syncCfg = repo.loadCloudSyncConfig()
        guard syncCfg.shouldAutoSync else { return }

        Task {
            await MainActor.run {
                if !isImporting {
                    importStatus = "正在自動同步閱讀進度至雲端…"
                }
            }
            let manager = CloudSyncManager(repository: repo)
            let doneMessage: String
            do {
                _ = try await manager.syncNow(
                    config: syncCfg,
                    onConfigUpdated: { _ in },
                    onProgress: { _ in }
                )
                doneMessage = "已自動同步閱讀進度（\(syncCfg.activeProvider.label)）"
            } catch {
                doneMessage = "自動同步暫時略過：\(error.localizedDescription)"
            }
            let latestBooks = repo.loadBooks()
            let latestSettings = repo.loadSettings()
            await MainActor.run {
                books = latestBooks
                settings = latestSettings
                if !isImporting {
                    importStatus = doneMessage
                }
            }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                if importStatus == doneMessage {
                    importStatus = nil
                }
            }
        }
    }

    // MARK: - Import Handlers

    private func handlePickedURLs(_ urls: [URL], mode: ActiveDocumentPicker) {
        guard !urls.isEmpty else { return }
        switch mode {
        case .bookFiles:
            guard !isImporting else { return }
            Task {
                isImporting = true
                importStatus = "正在準備匯入 \(urls.count) 個檔案…"
                let res = await repository.importBooksFromURLs(urls) { cur, total, name in
                    await MainActor.run {
                        importStatus = "正在匯入 (\(cur) / \(total))：\(name)"
                        if cur % 3 == 0 { books = repository.loadBooks() }
                    }
                }
                await MainActor.run {
                    books = repository.loadBooks()
                    importStatus = formatBatchSummary(prefix: "檔案匯入", res: res)
                    isImporting = false
                }
            }

        case .bookFolder:
            guard let folderURL = urls.first, !isImporting else { return }
            Task {
                isImporting = true
                importStatus = "正在掃描資料夾內的電子書與漫畫…"
                let res = await repository.importBooksFromFolderURL(folderURL) { cur, total, name in
                    await MainActor.run {
                        importStatus = "正在匯入資料夾 (\(cur) / \(total))：\(name)"
                        if cur % 3 == 0 { books = repository.loadBooks() }
                    }
                }
                await MainActor.run {
                    books = repository.loadBooks()
                    importStatus = formatBatchSummary(prefix: "資料夾匯入", res: res)
                    isImporting = false
                }
            }

        case .fontFiles:
            let count = FontManager.importFontFiles(urls)
            fontScanVersion += 1
            if count > 0 {
                importStatus = "已成功匯入 \(count) 個字體檔"
            }

        case .fontFolder:
            guard let folderURL = urls.first else { return }
            let scoped = folderURL.startAccessingSecurityScopedResource()
            defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }
            if let bookmarkData = try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                var updated = settings
                updated.customFontFolderBookmark = bookmarkData.base64EncodedString()
                settings = updated
                repository.saveSettings(updated)
                fontScanVersion += 1
            }
        }
    }

    private func handleOpenExternalURL(_ url: URL) {
        if url.scheme?.lowercased() == "com.inkflow.reader" || url.host?.lowercased() == "oauth" {
            _ = OAuthPkceHelper.handleRedirectURL(url)
            return
        }

        let ext = url.pathExtension.lowercased()
        if FontManager.fontExtensions.contains(ext) {
            let count = FontManager.importFontFiles([url])
            fontScanVersion += 1
            if count > 0 {
                importStatus = "已匯入字體：\(url.lastPathComponent)"
            }
            return
        }

        Task {
            isImporting = true
            importStatus = "正在匯入：\(url.lastPathComponent)"
            let res = await repository.importBooksFromURLs([url]) { _, _, _ in }
            await MainActor.run {
                books = repository.loadBooks()
                importStatus = formatBatchSummary(prefix: "外部開啟", res: res)
                isImporting = false
                if res.importedCount == 1, let newest = books.first {
                    activeBook = newest
                }
            }
        }
    }

    private func triggerScanDroppedFiles(showFeedbackWhenZero: Bool) {
        Task {
            let count = await repository.scanDroppedFilesInDocuments()
            await MainActor.run {
                if count > 0 {
                    books = repository.loadBooks()
                    importStatus = "已從「檔案 → Readify」匯入 \(count) 本書"
                } else if showFeedbackWhenZero {
                    importStatus = "「檔案 → Readify」根目錄目前沒有待匯入的新書檔"
                }
            }
        }
    }

    private func formatBatchSummary(prefix: String, res: BatchImportResult) -> String {
        if res.importedCount == 0 && res.skippedDuplicateCount == 0 && res.unsupportedCount == 0 && res.failedCount == 0 {
            return "\(prefix)內找不到支援的電子書或漫畫檔案"
        }
        if res.importedCount == 1 && res.skippedDuplicateCount == 0 && res.unsupportedCount == 0 && res.failedCount == 0,
           let title = res.lastImportedTitle {
            return "已成功匯入「\(title)」"
        }
        var parts: [String] = ["成功 \(res.importedCount) 本"]
        if res.skippedDuplicateCount > 0 { parts.append("略過重複 \(res.skippedDuplicateCount) 本") }
        if res.unsupportedCount > 0 { parts.append("不支援格式 \(res.unsupportedCount) 個") }
        if res.failedCount > 0 { parts.append("失敗 \(res.failedCount) 個") }
        return "\(prefix)完成：\(parts.joined(separator: "、"))"
    }
}
