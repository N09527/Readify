import SwiftUI
import UIKit

private struct PaginatedChapterData: Equatable {
    var title: String
    var pages: [PageContent]
}

struct ReaderScreen: View {
    let book: BookItem
    let repository: AppRepository
    let settings: ReaderSettings
    let fontScanVersion: Int
    let onSettingsChange: (ReaderSettings) -> Void
    let onImportFontFiles: () -> Void
    let onPickFontsFolder: () -> Void
    let onSwitchBackToPdfOriginal: (() -> Void)?
    let onMenuVisibilityChange: (Bool) -> Void
    let onExitReader: () -> Void

    @StateObject private var turnController = ReaderTurnController()

    @State private var isLoading = true
    @State private var rawChapters: [Chapter] = []
    @State private var currentChapterIndex: Int = 0
    @State private var targetCharOffset: Int = 0

    @State private var viewportWidthPt: CGFloat = 0
    @State private var viewportHeightPt: CGFloat = 0

    @State private var chapterCache: [Int: PaginatedChapterData] = [:]
    @State private var currentPageIndex: Int = 0

    @State private var showMenu = false
    @State private var showSettingsSheet = false
    @State private var showTocAndBookmarks = false
    @State private var showSearchSheet = false
    @State private var showTapZoneSheet = false

    @State private var bookmarks: [BookmarkItem] = []
    @State private var toastMessage: String?

    @State private var availableFonts: [LocalFontItem] = []
    @State private var isScanningFonts = false
    @State private var hasExited = false

    private var layoutMetrics: SpreadLayoutMetrics? {
        guard viewportWidthPt > 10 && viewportHeightPt > 10 else { return nil }
        return ReaderLayoutMetrics.compute(widthPt: viewportWidthPt, heightPt: viewportHeightPt, settings: settings)
    }

    private var isDualPage: Bool { layoutMetrics?.isDualPage ?? false }
    private var contentWidthPt: CGFloat { layoutMetrics?.contentWidthPt ?? 0 }
    private var contentHeightPt: CGFloat { layoutMetrics?.contentHeightPt ?? 0 }

    private var currentChapterData: PaginatedChapterData? {
        chapterCache[currentChapterIndex]
    }

    private var pages: [PageContent] {
        currentChapterData?.pages ?? []
    }

    private var chapterPrefixChars: [Int64] {
        var prefix = [Int64](repeating: 0, count: rawChapters.count + 1)
        for i in rawChapters.indices {
            prefix[i + 1] = prefix[i] + Int64(max(1, rawChapters[i].content.count))
        }
        return prefix
    }

    private var paginationConfigKey: String {
        "\(rawChapters.count)|\(Int(contentWidthPt))x\(Int(contentHeightPt))|\(isDualPage)|\(settings.writingMode.rawValue)|\(settings.fontSizeSp)|\(settings.fontBold)|\(settings.letterSpacingEm)|\(settings.lineSpacingMultiplier)|\(settings.paragraphSpacingEm)|\(settings.paragraphIndentChars)|\(settings.customFontPath ?? "")|\(settings.chineseConvertMode.rawValue)"
    }

    private func resolveMatchedPageIndex(
        chapterPages: [PageContent],
        desiredOffset: Int,
        dual: Bool
    ) -> Int {
        guard !chapterPages.isEmpty else { return 0 }
        let step = dual ? 2 : 1
        let rawMatched: Int
        if desiredOffset == Int.max {
            rawMatched = chapterPages.count - 1
        } else if desiredOffset <= 0 {
            rawMatched = 0
        } else if let exact = chapterPages.firstIndex(where: { desiredOffset >= $0.startOffset && desiredOffset <= $0.endOffset }) {
            rawMatched = exact
        } else {
            rawMatched = max(0, chapterPages.lastIndex(where: { $0.startOffset <= desiredOffset }) ?? 0)
        }
        return step == 2 ? ((rawMatched / 2) * 2) : rawMatched
    }

    private var currentSpread: SpreadSnapshot? {
        guard !rawChapters.isEmpty, let data = currentChapterData else { return nil }
        let p1 = (currentPageIndex >= 0 && currentPageIndex < data.pages.count) ? data.pages[currentPageIndex] : nil
        let p2 = (isDualPage && currentPageIndex + 1 >= 0 && currentPageIndex + 1 < data.pages.count) ? data.pages[currentPageIndex + 1] : nil
        return SpreadSnapshot(
            chapterIndex: currentChapterIndex,
            chapterTitle: data.title,
            firstPage: p1,
            secondPage: p2,
            totalPagesInChapter: max(1, data.pages.count)
        )
    }

    private var nextSpread: SpreadSnapshot? {
        guard !rawChapters.isEmpty else { return nil }
        let step = isDualPage ? 2 : 1
        let idx1 = currentPageIndex + step
        let nextChIdx = currentChapterIndex + 1
        if let cur = chapterCache[currentChapterIndex], idx1 >= 0 && idx1 < cur.pages.count {
            let p1 = cur.pages[idx1]
            let p2 = (isDualPage && idx1 + 1 < cur.pages.count) ? cur.pages[idx1 + 1] : nil
            return SpreadSnapshot(
                chapterIndex: currentChapterIndex,
                chapterTitle: cur.title,
                firstPage: p1,
                secondPage: p2,
                totalPagesInChapter: max(1, cur.pages.count)
            )
        } else if nextChIdx >= 0 && nextChIdx < rawChapters.count {
            if let nxt = chapterCache[nextChIdx] {
                let p1 = nxt.pages.first
                let p2 = (isDualPage && nxt.pages.count > 1) ? nxt.pages[1] : nil
                return SpreadSnapshot(
                    chapterIndex: nextChIdx,
                    chapterTitle: nxt.title,
                    firstPage: p1,
                    secondPage: p2,
                    totalPagesInChapter: max(1, nxt.pages.count)
                )
            } else {
                return SpreadSnapshot(
                    chapterIndex: nextChIdx,
                    chapterTitle: rawChapters[nextChIdx].title,
                    firstPage: nil,
                    secondPage: nil,
                    totalPagesInChapter: 1
                )
            }
        }
        return nil
    }

    private var prevSpread: SpreadSnapshot? {
        guard !rawChapters.isEmpty else { return nil }
        let step = isDualPage ? 2 : 1
        let idx1 = currentPageIndex - step
        let prevChIdx = currentChapterIndex - 1
        if let cur = chapterCache[currentChapterIndex], idx1 >= 0 && idx1 < cur.pages.count {
            let p1 = cur.pages[idx1]
            let p2 = (isDualPage && idx1 + 1 < cur.pages.count) ? cur.pages[idx1 + 1] : nil
            return SpreadSnapshot(
                chapterIndex: currentChapterIndex,
                chapterTitle: cur.title,
                firstPage: p1,
                secondPage: p2,
                totalPagesInChapter: max(1, cur.pages.count)
            )
        } else if prevChIdx >= 0 && prevChIdx < rawChapters.count {
            if let prv = chapterCache[prevChIdx], !prv.pages.isEmpty {
                let lastStart = isDualPage ? (((prv.pages.count - 1) / 2) * 2) : (prv.pages.count - 1)
                let p1 = (lastStart >= 0 && lastStart < prv.pages.count) ? prv.pages[lastStart] : nil
                let p2 = (isDualPage && lastStart + 1 >= 0 && lastStart + 1 < prv.pages.count) ? prv.pages[lastStart + 1] : nil
                return SpreadSnapshot(
                    chapterIndex: prevChIdx,
                    chapterTitle: prv.title,
                    firstPage: p1,
                    secondPage: p2,
                    totalPagesInChapter: max(1, prv.pages.count)
                )
            } else {
                return SpreadSnapshot(
                    chapterIndex: prevChIdx,
                    chapterTitle: rawChapters[prevChIdx].title,
                    firstPage: nil,
                    secondPage: nil,
                    totalPagesInChapter: 1
                )
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            ReaderCanvasRepresentable(
                settings: settings,
                bookTitle: ChineseConverter.convert(book.title, mode: settings.chineseConvertMode),
                totalChapters: max(1, rawChapters.count),
                currentSpread: currentSpread,
                nextSpread: nextSpread,
                prevSpread: prevSpread,
                turnController: turnController,
                onRequestNextSpread: handleNextSpread,
                onRequestPrevSpread: handlePrevSpread,
                onToggleMenu: {
                    showMenu.toggle()
                },
                onBoundaryReached: { isEnd in
                    if isEnd {
                        showToast("已經是最後一頁了")
                    } else if settings.writingMode == .VERTICAL && settings.verticalNaturalSwipe {
                        showToast("已經是第一頁（直排模式向右滑為下一頁，可在設定切換方向）")
                    } else {
                        showToast("已經是第一頁了")
                    }
                },
                onViewportReady: { w, h in
                    viewportWidthPt = w
                    viewportHeightPt = h
                }
            )
            .ignoresSafeArea()

            VolumePageTurnBridge(
                enabled: settings.volumeKeyPageTurn,
                onVolumeNext: { turnController.triggerNext?() },
                onVolumePrev: { turnController.triggerPrev?() }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)

            if isLoading {
                ZStack {
                    settings.effectiveTheme.bgSwiftUIColor.ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(book.format == .PDF ? "正在擷取 PDF 文字重排…" : "正在解析電子書…")
                            .font(.subheadline)
                            .foregroundStyle(settings.effectiveTheme.textSwiftUIColor)
                    }
                }
            }

            if let toast = toastMessage {
                VStack {
                    Spacer()
                    ToastBannerView(message: toast)
                        .padding(.bottom, showMenu ? 120 : 48)
                }
                .transition(.opacity)
            }

            if showMenu {
                menuOverlay
            }
        }
        .onAppear {
            bookmarks = repository.loadBookmarksForBook(book.id)
            onMenuVisibilityChange(showMenu)
            loadBookChapters()
            rescanFonts()
        }
        .onChange(of: showMenu) { vis in
            onMenuVisibilityChange(vis)
        }
        .onChange(of: fontScanVersion) { _ in
            rescanFonts()
        }
        .task(id: paginationConfigKey) {
            await rebuildPaginationCache()
        }
        .task(id: currentChapterIndex) {
            await ensureAdjacentChaptersPaginated()
        }
        .onChange(of: currentPageIndex) { _ in
            persistReadingProgress()
        }
        .onChange(of: currentChapterIndex) { _ in
            persistReadingProgress()
        }
        .sheet(isPresented: $showSettingsSheet) {
            ReaderTypographySheet(
                settings: settings,
                availableFonts: availableFonts,
                isScanningFonts: isScanningFonts,
                onSettingsChange: onSettingsChange,
                onRescanFonts: rescanFonts,
                onImportFontFiles: {
                    showSettingsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onImportFontFiles()
                    }
                },
                onPickFontsFolder: {
                    showSettingsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onPickFontsFolder()
                    }
                }
            )
        }
        .sheet(isPresented: $showTocAndBookmarks) {
            TocAndBookmarksSheet(
                chapters: rawChapters,
                currentChapterIndex: currentChapterIndex,
                chineseConvertMode: settings.chineseConvertMode,
                bookmarks: bookmarks,
                onSelectChapter: { idx in
                    guard !rawChapters.isEmpty else { return }
                    currentChapterIndex = min(max(0, idx), rawChapters.count - 1)
                    targetCharOffset = 0
                    currentPageIndex = 0
                    showTocAndBookmarks = false
                    showMenu = false
                },
                onSelectBookmark: { bm in
                    guard !rawChapters.isEmpty else { return }
                    let safeCh = min(max(0, bm.chapterIndex), rawChapters.count - 1)
                    let safeOff = max(0, bm.charOffset)
                    currentChapterIndex = safeCh
                    targetCharOffset = safeOff
                    if let cur = chapterCache[safeCh] {
                        currentPageIndex = resolveMatchedPageIndex(chapterPages: cur.pages, desiredOffset: safeOff, dual: isDualPage)
                    }
                    showTocAndBookmarks = false
                    showMenu = false
                },
                onDeleteBookmark: { bmId in
                    repository.deleteBookmark(bmId)
                    bookmarks = repository.loadBookmarksForBook(book.id)
                }
            )
        }
        .sheet(isPresented: $showSearchSheet) {
            FullBookSearchSheet(
                chapters: rawChapters,
                onSelectHit: { hit in
                    guard !rawChapters.isEmpty else { return }
                    let safeCh = min(max(0, hit.chapterIndex), rawChapters.count - 1)
                    let safeOff = max(0, hit.charOffset)
                    currentChapterIndex = safeCh
                    targetCharOffset = safeOff
                    if let cur = chapterCache[safeCh] {
                        currentPageIndex = resolveMatchedPageIndex(chapterPages: cur.pages, desiredOffset: safeOff, dual: isDualPage)
                    }
                    showSearchSheet = false
                    showMenu = false
                }
            )
        }
        .sheet(isPresented: $showTapZoneSheet) {
            TapZoneEditorSheet(
                tapZones: settings.tapZones,
                leftPresetTitle: "套用橫書預設",
                rightPresetTitle: "套用直書預設",
                onUpdateTapZones: { updated in
                    var copy = settings
                    copy.tapZones = updated
                    onSettingsChange(copy)
                }
            )
        }
    }

    // MARK: - Menu Overlay

    private var menuOverlay: some View {
        let barBg: Color = settings.eInkMode ? .white : Color(uiColor: .systemBackground).opacity(0.96)
        let barFg: Color = settings.eInkMode ? .black : .primary

        return VStack {
            // Top Bar
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: exitReaderSafely) {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(barFg)
                            .frame(width: 38, height: 38)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(barFg)
                            .lineLimit(1)
                        Text(currentChapterData?.title ?? "")
                            .font(.caption2)
                            .foregroundStyle(barFg.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()

                    Button {
                        showSearchSheet = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .foregroundStyle(barFg)
                            .frame(width: 36, height: 36)
                    }

                    Button {
                        addCurrentPageBookmark()
                    } label: {
                        Image(systemName: "bookmark")
                            .font(.body.weight(.medium))
                            .foregroundStyle(barFg)
                            .frame(width: 36, height: 36)
                    }
                }
                .padding(.horizontal, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let onSwitchBackToPdfOriginal {
                            SelectableChip(label: "切回 PDF 原版面", selected: true, eInkMode: settings.eInkMode) {
                                showMenu = false
                                onSwitchBackToPdfOriginal()
                            }
                        }

                        SelectableChip(
                            label: settings.writingMode == .VERTICAL ? "直排" : "橫排",
                            selected: settings.writingMode == .VERTICAL,
                            eInkMode: settings.eInkMode
                        ) {
                            var copy = settings
                            copy.writingMode = (settings.writingMode == .VERTICAL) ? .HORIZONTAL : .VERTICAL
                            onSettingsChange(copy)
                        }

                        SelectableChip(
                            label: settings.dualPageMode.label,
                            selected: settings.dualPageMode == .DUAL || isDualPage,
                            eInkMode: settings.eInkMode
                        ) {
                            var copy = settings
                            switch settings.dualPageMode {
                            case .AUTO: copy.dualPageMode = .DUAL
                            case .DUAL: copy.dualPageMode = .SINGLE
                            case .SINGLE: copy.dualPageMode = .AUTO
                            }
                            onSettingsChange(copy)
                        }

                        SelectableChip(
                            label: settings.chineseConvertMode.label,
                            selected: settings.chineseConvertMode != .ORIGINAL,
                            eInkMode: settings.eInkMode
                        ) {
                            var copy = settings
                            switch settings.chineseConvertMode {
                            case .ORIGINAL: copy.chineseConvertMode = .TO_TRADITIONAL_TW
                            case .TO_TRADITIONAL_TW: copy.chineseConvertMode = .TO_SIMPLIFIED
                            case .TO_SIMPLIFIED: copy.chineseConvertMode = .ORIGINAL
                            }
                            onSettingsChange(copy)
                        }

                        SelectableChip(
                            label: "電子紙",
                            selected: settings.eInkMode,
                            eInkMode: settings.eInkMode
                        ) {
                            var copy = settings
                            copy.eInkMode.toggle()
                            onSettingsChange(copy)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .background(barBg.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) { Divider() }

            Spacer()

            // Bottom Bar
            VStack(spacing: 10) {
                if pages.count > 1 || rawChapters.count > 1 {
                    HStack(spacing: 10) {
                        Button("上一章") {
                            currentChapterIndex = max(0, currentChapterIndex - 1)
                            targetCharOffset = 0
                            currentPageIndex = 0
                        }
                        .font(.footnote.weight(.medium))
                        .disabled(currentChapterIndex <= 0)

                        if pages.count > 1 {
                            Slider(
                                value: Binding(
                                    get: { Double(min(max(0, currentPageIndex), max(1, pages.count - 1))) },
                                    set: { val in
                                        let raw = Int(val.rounded())
                                        let snapped = isDualPage ? ((raw / 2) * 2) : raw
                                        currentPageIndex = min(max(0, snapped), max(0, pages.count - 1))
                                    }
                                ),
                                in: 0...Double(max(1, pages.count - 1))
                            )
                        } else {
                            Spacer()
                        }

                        Button("下一章") {
                            currentChapterIndex = min(max(0, rawChapters.count - 1), currentChapterIndex + 1)
                            targetCharOffset = 0
                            currentPageIndex = 0
                        }
                        .font(.footnote.weight(.medium))
                        .disabled(currentChapterIndex >= rawChapters.count - 1)
                    }
                    .padding(.horizontal, 14)
                }

                HStack {
                    Spacer()
                    BottomMenuActionButton(systemImage: "list.bullet", label: "目錄/書籤", tint: barFg) {
                        showTocAndBookmarks = true
                    }
                    Spacer()
                    BottomMenuActionButton(systemImage: "textformat.size", label: "排版與字體", tint: barFg) {
                        showSettingsSheet = true
                    }
                    Spacer()
                    BottomMenuActionButton(systemImage: "square.grid.3x3", label: "點擊區域", tint: barFg) {
                        showTapZoneSheet = true
                    }
                    Spacer()
                    BottomMenuActionButton(systemImage: "xmark", label: "隱藏選單", tint: barFg) {
                        showMenu = false
                    }
                    Spacer()
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(barBg.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: - Logic & Pagination

    private func loadBookChapters() {
        isLoading = true
        let fileURL = repository.resolveBookFileURL(book)
        let format = book.format
        let fallbackTitle = book.title
        let savedCh = max(0, book.lastChapterIndex)
        let savedOff = max(0, book.lastCharOffset)

        Task.detached(priority: .userInitiated) {
            let parsed = BookParser.parseFullBook(fileURL: fileURL, format: format, fallbackTitle: fallbackTitle)
            await MainActor.run {
                self.rawChapters = parsed.chapters
                self.currentChapterIndex = min(savedCh, max(0, parsed.chapters.count - 1))
                self.targetCharOffset = savedOff
                self.isLoading = false
            }
        }
    }

    private func rescanFonts() {
        isScanningFonts = true
        let bookmark = settings.customFontFolderBookmark
        Task.detached(priority: .utility) {
            let fonts = FontManager.scanAvailableFonts(customFolderBookmark: bookmark)
            await MainActor.run {
                self.availableFonts = fonts
                self.isScanningFonts = false
            }
        }
    }

    private func paginateSingleChapter(_ index: Int) async -> PaginatedChapterData? {
        guard index >= 0 && index < rawChapters.count,
              contentWidthPt > 10 && contentHeightPt > 10 else { return nil }
        let raw = rawChapters[index]
        let curSettings = settings
        let w = contentWidthPt
        let h = contentHeightPt

        return await Task.detached(priority: .userInitiated) {
            let (font, needsSyntheticBold) = FontManager.resolveReaderFont(
                size: CGFloat(curSettings.fontSizeSp),
                bold: curSettings.fontBold,
                customFontPath: curSettings.customFontPath
            )
            let convTitle = ChineseConverter.convert(raw.title, mode: curSettings.chineseConvertMode)
            let convContent = ChineseConverter.convert(raw.content, mode: curSettings.chineseConvertMode)
            let pages = TextPaginator.paginate(
                chapterTitle: convTitle,
                chapterContent: convContent,
                writingMode: curSettings.writingMode,
                contentWidthPt: w,
                contentHeightPt: h,
                font: font,
                needsSyntheticBold: needsSyntheticBold,
                lineSpacingMultiplier: CGFloat(curSettings.lineSpacingMultiplier),
                letterSpacingEm: CGFloat(curSettings.letterSpacingEm),
                paragraphSpacingEm: CGFloat(curSettings.paragraphSpacingEm),
                paragraphIndentChars: curSettings.paragraphIndentChars
            )
            return PaginatedChapterData(title: convTitle, pages: pages)
        }.value
    }

    private func rebuildPaginationCache() async {
        guard !rawChapters.isEmpty && contentWidthPt > 10 && contentHeightPt > 10 else { return }
        let chIdx = currentChapterIndex
        let desiredOffset = targetCharOffset
        let dual = isDualPage

        guard let curData = await paginateSingleChapter(chIdx) else { return }
        if Task.isCancelled { return }

        let alignedPage = resolveMatchedPageIndex(
            chapterPages: curData.pages,
            desiredOffset: desiredOffset,
            dual: dual
        )

        var newCache: [Int: PaginatedChapterData] = [chIdx: curData]
        chapterCache = newCache
        currentPageIndex = alignedPage

        if chIdx + 1 >= 0 && chIdx + 1 < rawChapters.count, let nxt = await paginateSingleChapter(chIdx + 1) {
            if !Task.isCancelled { newCache[chIdx + 1] = nxt }
        }
        if chIdx - 1 >= 0 && chIdx - 1 < rawChapters.count, let prv = await paginateSingleChapter(chIdx - 1) {
            if !Task.isCancelled { newCache[chIdx - 1] = prv }
        }
        if !Task.isCancelled {
            chapterCache = newCache
            persistReadingProgress()
        }
    }

    private func ensureAdjacentChaptersPaginated() async {
        guard !rawChapters.isEmpty && contentWidthPt > 10 && contentHeightPt > 10 else { return }
        let chIdx = currentChapterIndex
        var working = chapterCache

        if working[chIdx] == nil, let d = await paginateSingleChapter(chIdx) {
            working[chIdx] = d
        }
        if let curPages = working[chIdx]?.pages, !curPages.isEmpty {
            currentPageIndex = resolveMatchedPageIndex(
                chapterPages: curPages,
                desiredOffset: targetCharOffset,
                dual: isDualPage
            )
        }

        if chIdx + 1 >= 0 && chIdx + 1 < rawChapters.count && working[chIdx + 1] == nil,
           let nxt = await paginateSingleChapter(chIdx + 1) {
            working[chIdx + 1] = nxt
        }
        if chIdx - 1 >= 0 && chIdx - 1 < rawChapters.count && working[chIdx - 1] == nil,
           let prv = await paginateSingleChapter(chIdx - 1) {
            working[chIdx - 1] = prv
        }

        chapterCache = working.filter { abs($0.key - chIdx) <= 2 }
        persistReadingProgress()
    }

    private func handleNextSpread() -> Bool {
        let step = isDualPage ? 2 : 1
        if pages.isEmpty { return false }
        if currentPageIndex + step < pages.count {
            currentPageIndex += step
            return true
        } else if currentChapterIndex + 1 < rawChapters.count {
            currentChapterIndex += 1
            targetCharOffset = 0
            currentPageIndex = 0
            return true
        } else {
            showToast("已經是最後一頁了")
            return false
        }
    }

    private func handlePrevSpread() -> Bool {
        let step = isDualPage ? 2 : 1
        if pages.isEmpty { return false }
        if currentPageIndex - step >= 0 {
            currentPageIndex -= step
            return true
        } else if currentChapterIndex - 1 >= 0 && currentChapterIndex - 1 < rawChapters.count {
            let prevIdx = currentChapterIndex - 1
            let prevPages = chapterCache[prevIdx]?.pages
            currentChapterIndex = prevIdx
            if let prevPages, !prevPages.isEmpty {
                let lastStart = isDualPage ? (((prevPages.count - 1) / 2) * 2) : (prevPages.count - 1)
                currentPageIndex = lastStart
                targetCharOffset = prevPages[lastStart].startOffset
            } else {
                targetCharOffset = Int.max
            }
            return true
        } else {
            showToast("已經是第一頁了")
            return false
        }
    }

    private func exitReaderSafely() {
        guard !hasExited else { return }
        hasExited = true
        if !isLoading {
            persistReadingProgress(synchronous: true)
        }
        onExitReader()
    }

    private func persistReadingProgress(synchronous: Bool = false) {
        guard !rawChapters.isEmpty,
              currentChapterIndex >= 0 && currentChapterIndex < rawChapters.count,
              currentPageIndex >= 0 && currentPageIndex < pages.count else { return }
        let page = pages[currentPageIndex]
        targetCharOffset = page.startOffset

        let prefix = chapterPrefixChars
        let totalBookChars = max(1, prefix.last ?? 1)
        let step = isDualPage ? 2 : 1
        let isAtFinalSpread = !rawChapters.isEmpty &&
            currentChapterIndex >= rawChapters.count - 1 &&
            (currentPageIndex + step) >= pages.count

        let progressFraction: Float
        if isAtFinalSpread {
            progressFraction = 1.0
        } else {
            let prevChars = (currentChapterIndex >= 0 && currentChapterIndex < prefix.count) ? prefix[currentChapterIndex] : 0
            let curChChars = max(1, rawChapters[currentChapterIndex].content.count)
            let chPageRatio = Float(min(pages.count, currentPageIndex + step)) / Float(max(1, pages.count))
            progressFraction = min(1.0, max(0.0, (Float(prevChars) + Float(curChChars) * chPageRatio) / Float(totalBookChars)))
        }

        let bookId = book.id
        let ch = currentChapterIndex
        let off = page.startOffset
        let repo = repository
        if synchronous {
            repo.updateBookProgress(bookId: bookId, chapterIndex: ch, charOffset: off, progressFraction: progressFraction)
        } else {
            Task.detached(priority: .utility) {
                repo.updateBookProgress(bookId: bookId, chapterIndex: ch, charOffset: off, progressFraction: progressFraction)
            }
        }
    }

    private func addCurrentPageBookmark() {
        guard let title = currentChapterData?.title,
              currentPageIndex >= 0 && currentPageIndex < pages.count else { return }
        let pg = pages[currentPageIndex]
        let preview = String(pg.lines.map { $0.text }.joined().prefix(45))
        let bm = BookmarkItem(
            id: UUID().uuidString.lowercased(),
            bookId: book.id,
            chapterIndex: currentChapterIndex,
            chapterTitle: title,
            charOffset: pg.startOffset,
            preview: preview
        )
        repository.addBookmark(bm)
        bookmarks = repository.loadBookmarksForBook(book.id)
        showToast("已加入書籤")
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == msg {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Typography, Fonts, TOC/Bookmarks, & Search Sheets

private struct ReaderTypographySheet: View {
    let settings: ReaderSettings
    let availableFonts: [LocalFontItem]
    let isScanningFonts: Bool
    let onSettingsChange: (ReaderSettings) -> Void
    let onRescanFonts: () -> Void
    let onImportFontFiles: () -> Void
    let onPickFontsFolder: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Font Selection
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("字體（自動讀取 Readify/Fonts 資料夾）")
                                    .font(.subheadline.weight(.semibold))
                                Text("目前：\(settings.customFontName ?? "系統預設明體（Serif）")")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            Button(action: onRescanFonts) {
                                Image(systemName: "arrow.clockwise")
                            }
                        }

                        HStack(spacing: 8) {
                            Button(action: onImportFontFiles) {
                                Label("匯入字體檔", systemImage: "plus.circle")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)

                            Button(action: onPickFontsFolder) {
                                Label("指定字體資料夾", systemImage: "folder")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)

                            Text(isScanningFonts ? "掃描中…" : "共 \(availableFonts.count) 套自訂字體")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                SelectableChip(label: "系統預設明體", selected: settings.customFontPath == nil) {
                                    var copy = settings
                                    copy.customFontPath = nil
                                    copy.customFontName = nil
                                    onSettingsChange(copy)
                                }
                                ForEach(availableFonts) { font in
                                    SelectableChip(
                                        label: font.displayName,
                                        selected: settings.customFontPath == font.pathOrUri
                                    ) {
                                        var copy = settings
                                        copy.customFontPath = font.pathOrUri
                                        copy.customFontName = font.displayName
                                        onSettingsChange(copy)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        Toggle("字體加粗（粗體渲染，適用所有自訂字體）", isOn: Binding(
                            get: { settings.fontBold },
                            set: { v in
                                var copy = settings
                                copy.fontBold = v
                                onSettingsChange(copy)
                            }
                        ))
                        .font(.subheadline)
                    }

                    Divider()

                    // Numeric Sliders
                    NumericSliderControl(label: "字體大小", unit: "pt", value: settings.fontSizeSp, range: 12...48, decimals: 0) { v in
                        var copy = settings; copy.fontSizeSp = v; onSettingsChange(copy)
                    }
                    NumericSliderControl(label: "字距", unit: "em", value: settings.letterSpacingEm, range: 0...0.50, decimals: 2) { v in
                        var copy = settings; copy.letterSpacingEm = v; onSettingsChange(copy)
                    }
                    NumericSliderControl(label: "行距倍率", unit: "x", value: settings.lineSpacingMultiplier, range: 1.10...3.00, decimals: 2) { v in
                        var copy = settings; copy.lineSpacingMultiplier = v; onSettingsChange(copy)
                    }
                    NumericSliderControl(label: "段落距", unit: "倍行高", value: settings.paragraphSpacingEm, range: 0...3.00, decimals: 2) { v in
                        var copy = settings; copy.paragraphSpacingEm = v; onSettingsChange(copy)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("段首縮排（每段開頭空幾字）")
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 8) {
                            ForEach([0, 1, 2, 3, 4], id: \.self) { chars in
                                SelectableChip(
                                    label: chars == 0 ? "不縮排" : "\(chars)字",
                                    selected: settings.paragraphIndentChars == chars
                                ) {
                                    var copy = settings
                                    copy.paragraphIndentChars = chars
                                    onSettingsChange(copy)
                                }
                            }
                        }
                    }

                    Divider()

                    NumericSliderControl(label: "每頁左右邊界", unit: "pt", value: settings.marginHorizontalDp, range: 0...80, decimals: 0) { v in
                        var copy = settings; copy.marginHorizontalDp = v; onSettingsChange(copy)
                    }
                    NumericSliderControl(label: "每頁上下邊界", unit: "pt", value: settings.marginVerticalDp, range: 0...96, decimals: 0) { v in
                        var copy = settings; copy.marginVerticalDp = v; onSettingsChange(copy)
                    }

                    Divider()

                    // Theme & Animation
                    VStack(alignment: .leading, spacing: 6) {
                        Text("背景主題")
                            .font(.subheadline.weight(.medium))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ReaderTheme.allCases) { theme in
                                    SelectableChip(
                                        label: theme.label,
                                        selected: settings.theme == theme && (!settings.eInkMode || theme == .EINK)
                                    ) {
                                        var copy = settings
                                        copy.theme = theme
                                        copy.eInkMode = (theme == .EINK)
                                        onSettingsChange(copy)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.eInkMode ? "翻頁動畫模式（電子紙模式已自動停用動畫）" : "翻頁動畫模式")
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 8) {
                            ForEach(PageTurnAnimation.allCases, id: \.rawValue) { anim in
                                SelectableChip(label: anim.label, selected: settings.pageTurnAnimation == anim) {
                                    var copy = settings
                                    copy.pageTurnAnimation = anim
                                    onSettingsChange(copy)
                                }
                            }
                        }
                    }

                    if settings.writingMode == .VERTICAL {
                        Toggle("直排依實體書方向滑動（向右滑＝下一頁）", isOn: Binding(
                            get: { settings.verticalNaturalSwipe },
                            set: { v in var copy = settings; copy.verticalNaturalSwipe = v; onSettingsChange(copy) }
                        ))
                        .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("雙頁模式（橫書與直書皆左右呈現）")
                            .font(.subheadline.weight(.medium))
                        HStack(spacing: 8) {
                            ForEach(DualPageMode.allCases, id: \.rawValue) { mode in
                                SelectableChip(label: mode.label, selected: settings.dualPageMode == mode) {
                                    var copy = settings
                                    copy.dualPageMode = mode
                                    onSettingsChange(copy)
                                }
                            }
                        }
                    }

                    Toggle("雙頁中間仿真接縫陰影", isOn: Binding(
                        get: { settings.showSpineShadow },
                        set: { v in var copy = settings; copy.showSpineShadow = v; onSettingsChange(copy) }
                    ))
                    .font(.subheadline)

                    Toggle("電子紙（E-ink）特化模式（純黑白、關閉動畫）", isOn: Binding(
                        get: { settings.eInkMode },
                        set: { v in var copy = settings; copy.eInkMode = v; onSettingsChange(copy) }
                    ))
                    .font(.subheadline)

                    Toggle("音量鍵翻頁（支援實體音量鍵與外接藍牙翻頁器）", isOn: Binding(
                        get: { settings.volumeKeyPageTurn },
                        set: { v in var copy = settings; copy.volumeKeyPageTurn = v; onSettingsChange(copy) }
                    ))
                    .font(.subheadline)
                }
                .padding(20)
            }
            .navigationTitle("排版、邊界與字體設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct TocAndBookmarksSheet: View {
    let chapters: [Chapter]
    let currentChapterIndex: Int
    let chineseConvertMode: ChineseConvertMode
    let bookmarks: [BookmarkItem]
    let onSelectChapter: (Int) -> Void
    let onSelectBookmark: (BookmarkItem) -> Void
    let onDeleteBookmark: (String) -> Void

    @State private var selectedTab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("目錄 (\(chapters.count))").tag(0)
                    Text("書籤 (\(bookmarks.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(12)

                if selectedTab == 0 {
                    ScrollViewReader { proxy in
                        List(chapters) { ch in
                            let isCurrent = ch.index == currentChapterIndex
                            Button {
                                onSelectChapter(ch.index)
                            } label: {
                                Text(ChineseConverter.convert(ch.title, mode: chineseConvertMode))
                                    .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            }
                            .id(ch.index)
                        }
                        .listStyle(.plain)
                        .onAppear {
                            proxy.scrollTo(currentChapterIndex, anchor: .center)
                        }
                    }
                } else {
                    if bookmarks.isEmpty {
                        Spacer()
                        Text("尚未加入任何書籤")
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        List {
                            ForEach(bookmarks) { bm in
                                HStack {
                                    Button {
                                        onSelectBookmark(bm)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(bm.chapterTitle)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(bm.preview)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        onDeleteBookmark(bm.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("目錄與書籤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FullBookSearchSheet: View {
    let chapters: [Chapter]
    let onSelectHit: (SearchHit) -> Void

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("輸入關鍵字搜尋全書…", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                List(hits) { hit in
                    Button {
                        onSelectHit(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.chapterTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("…\(hit.snippet)…")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("全書文字搜尋")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("關閉") { dismiss() }
                }
            }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else {
                    hits = []
                    return
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
                let chs = chapters
                let found = await Task.detached(priority: .userInitiated) {
                    var out: [SearchHit] = []
                    for ch in chs {
                        var searchStart = ch.content.startIndex
                        while out.count < 80,
                              let range = ch.content.range(
                                  of: q,
                                  options: [.caseInsensitive],
                                  range: searchStart..<ch.content.endIndex
                              ) {
                            let charOff = ch.content.distance(from: ch.content.startIndex, to: range.lowerBound)
                            let snipStart = ch.content.index(range.lowerBound, offsetBy: -15, limitedBy: ch.content.startIndex) ?? ch.content.startIndex
                            let snipEnd = ch.content.index(range.upperBound, offsetBy: 25, limitedBy: ch.content.endIndex) ?? ch.content.endIndex
                            let snippet = String(ch.content[snipStart..<snipEnd]).replacingOccurrences(of: "\n", with: " ")
                            out.append(SearchHit(chapterIndex: ch.index, chapterTitle: ch.title, charOffset: charOff, snippet: snippet))
                            searchStart = range.upperBound
                        }
                        if out.count >= 80 { break }
                    }
                    return out
                }.value
                if !Task.isCancelled {
                    hits = found
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
