import SwiftUI
import UIKit

struct VisualReaderScreen: View {
    let book: BookItem
    let repository: AppRepository
    let settings: ReaderSettings
    let onSettingsChange: (ReaderSettings) -> Void
    let onSwitchToPdfReflow: (() -> Void)?
    let onMenuVisibilityChange: (Bool) -> Void
    let onExitReader: () -> Void

    @StateObject private var turnController = ReaderTurnController()

    @State private var source: VisualBookSource?
    @State private var isLoading = true
    @State private var totalPages: Int = 0
    @State private var currentPageIndex: Int = 0

    @State private var viewportW: CGFloat = 0
    @State private var viewportH: CGFloat = 0
    @State private var isDualPage = false

    @State private var imageCache: [Int: UIImage] = [:]
    @State private var cacheEpoch: Int = 0

    @State private var showMenu = false
    @State private var showSettingsSheet = false
    @State private var showTapZoneSheet = false
    @State private var toastMessage: String?
    @State private var hasExited = false

    private var isPdf: Bool { book.format == .PDF }
    private var isRtlFlow: Bool { isPdf ? false : settings.comicRtl }
    private var pageStep: Int { isDualPage ? 2 : 1 }

    private var prefetchKey: String {
        "\(source != nil)|\(currentPageIndex)|\(isDualPage)|\(Int(viewportW))x\(Int(viewportH))|\(cacheEpoch)"
    }

    private func buildSpread(startIdx: Int) -> VisualSpreadImages? {
        guard totalPages > 0 && startIdx >= 0 && startIdx < totalPages else { return nil }
        let secondIdx = (isDualPage && startIdx + 1 < totalPages) ? (startIdx + 1) : nil
        return VisualSpreadImages(
            firstPageIndex: startIdx,
            secondPageIndex: secondIdx,
            firstImage: imageCache[startIdx],
            secondImage: secondIdx.flatMap { imageCache[$0] },
            totalPages: totalPages
        )
    }

    private var canvasBgColor: Color {
        if settings.eInkMode { return .white }
        if isPdf && settings.pdfNightInvert { return Color(uiColor: UIColor(hex: 0x121212)) }
        return Color(uiColor: UIColor(hex: 0x1A1D21))
    }

    var body: some View {
        ZStack {
            VisualPageCanvasRepresentable(
                settings: settings,
                rtlFlow: isRtlFlow,
                invertPdfColors: isPdf && settings.pdfNightInvert,
                currentSpread: buildSpread(startIdx: currentPageIndex),
                nextSpread: buildSpread(startIdx: currentPageIndex + pageStep),
                prevSpread: buildSpread(startIdx: currentPageIndex - pageStep),
                turnController: turnController,
                onRequestNextSpread: {
                    if currentPageIndex + pageStep < totalPages {
                        currentPageIndex += pageStep
                        return true
                    } else {
                        showToast("已經是最後一頁了")
                        return false
                    }
                },
                onRequestPrevSpread: {
                    if currentPageIndex - pageStep >= 0 {
                        currentPageIndex -= pageStep
                        return true
                    } else {
                        showToast("已經是第一頁了")
                        return false
                    }
                },
                onToggleMenu: {
                    showMenu.toggle()
                },
                onBoundaryReached: { isEnd in
                    if isEnd {
                        showToast("已經是最後一頁了")
                    } else if isRtlFlow {
                        showToast("已經是第一頁（漫畫右翻左模式：向右滑＝下一頁）")
                    } else {
                        showToast("已經是第一頁了")
                    }
                },
                onViewportReady: { w, h, dual in
                    viewportW = w
                    viewportH = h
                    isDualPage = dual
                }
            )

            VolumePageTurnBridge(
                enabled: settings.volumeKeyPageTurn,
                onVolumeNext: { turnController.triggerNext?() },
                onVolumePrev: { turnController.triggerPrev?() }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)

            if isLoading {
                ZStack {
                    canvasBgColor.ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(settings.eInkMode ? .black : .white)
                        Text(book.format == .CBR ? "正在解壓漫畫檔…" : "正在開啟頁面…")
                            .font(.subheadline)
                            .foregroundStyle(settings.eInkMode ? .black : .white)
                    }
                }
            } else if totalPages == 0 {
                ZStack {
                    canvasBgColor.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("此檔案內找不到可顯示的圖片或頁面")
                            .foregroundStyle(settings.eInkMode ? .black : .white)
                        Button("返回書架", action: exitReaderSafely)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if let toast = toastMessage {
                VStack {
                    Spacer()
                    ToastBannerView(message: toast)
                        .padding(.bottom, showMenu ? 120 : 48)
                }
            }

            if showMenu {
                menuOverlay
            }
        }
        .background(canvasBgColor.ignoresSafeArea())
        .preferredColorScheme(settings.eInkMode ? .light : .dark)
        .onAppear {
            onMenuVisibilityChange(showMenu)
            openVisualSource()
        }
        .onDisappear {
            source?.close()
            imageCache.removeAll()
        }
        .onChange(of: showMenu) { vis in
            onMenuVisibilityChange(vis)
        }
        .onChange(of: settings.pdfAutoCrop) { _ in
            if isPdf {
                imageCache.removeAll()
                cacheEpoch += 1
            }
        }
        .onChange(of: isDualPage) { dual in
            if dual && currentPageIndex % 2 == 1 {
                currentPageIndex = max(0, currentPageIndex - 1)
            }
            persistVisualProgress()
        }
        .onChange(of: currentPageIndex) { _ in
            persistVisualProgress()
        }
        .task(id: prefetchKey) {
            await prefetchNeededPages()
        }
        .sheet(isPresented: $showSettingsSheet) {
            VisualSettingsSheet(
                isPdf: isPdf,
                settings: settings,
                onSettingsChange: onSettingsChange,
                onSwitchToPdfReflow: onSwitchToPdfReflow.map { cb in
                    {
                        showSettingsSheet = false
                        showMenu = false
                        cb()
                    }
                }
            )
        }
        .sheet(isPresented: $showTapZoneSheet) {
            TapZoneEditorSheet(
                tapZones: settings.tapZones,
                leftPresetTitle: "左翻右預設",
                rightPresetTitle: "日漫右翻左",
                onUpdateTapZones: { updated in
                    var copy = settings
                    copy.tapZones = updated
                    onSettingsChange(copy)
                }
            )
        }
    }

    private var menuOverlay: some View {
        let barBg: Color = settings.eInkMode ? .white : Color(uiColor: .systemBackground).opacity(0.96)
        let barFg: Color = settings.eInkMode ? .black : .primary

        return VStack {
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
                        Text("\(book.format.label) · 第 \(currentPageIndex + 1) / \(totalPages) 頁（支援雙指縮放）")
                            .font(.caption2)
                            .foregroundStyle(barFg.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if isPdf {
                            SelectableChip(
                                label: settings.pdfAutoCrop ? "自動裁邊:開" : "自動裁邊",
                                selected: settings.pdfAutoCrop,
                                eInkMode: settings.eInkMode
                            ) {
                                var copy = settings
                                copy.pdfAutoCrop.toggle()
                                onSettingsChange(copy)
                            }

                            if let onSwitchToPdfReflow {
                                SelectableChip(label: "文字重排", selected: false, eInkMode: settings.eInkMode) {
                                    showMenu = false
                                    onSwitchToPdfReflow()
                                }
                            }

                            SelectableChip(
                                label: "夜間反白",
                                selected: settings.pdfNightInvert,
                                eInkMode: settings.eInkMode
                            ) {
                                var copy = settings
                                copy.pdfNightInvert.toggle()
                                onSettingsChange(copy)
                            }
                        } else {
                            SelectableChip(
                                label: settings.comicRtl ? "右翻左(日漫)" : "左翻右",
                                selected: settings.comicRtl,
                                eInkMode: settings.eInkMode
                            ) {
                                var copy = settings
                                copy.comicRtl.toggle()
                                onSettingsChange(copy)
                            }
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
            .padding(.top, 4)
            .background(barBg.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) { Divider() }

            Spacer()

            VStack(spacing: 10) {
                if totalPages > 1 {
                    HStack(spacing: 8) {
                        Text("\(currentPageIndex + 1)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(barFg)
                        Slider(
                            value: Binding(
                                get: { Double(min(max(0, currentPageIndex), max(1, totalPages - 1))) },
                                set: { v in
                                    let raw = Int(v.rounded())
                                    let snapped = isDualPage ? ((raw / 2) * 2) : raw
                                    currentPageIndex = min(max(0, snapped), max(0, totalPages - 1))
                                }
                            ),
                            in: 0...Double(max(1, totalPages - 1))
                        )
                        Text("\(totalPages)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(barFg)
                    }
                    .padding(.horizontal, 14)
                }

                HStack {
                    Spacer()
                    BottomMenuActionButton(systemImage: "slider.horizontal.3", label: "閱讀設定", tint: barFg) {
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

    // MARK: - Source Loading & Prefetching

    private func openVisualSource() {
        isLoading = true
        let resolvedURL = repository.resolveBookFileURL(book)
        Task {
            let opened = await VisualBookSourceFactory.open(book: book, resolvedFileURL: resolvedURL)
            await MainActor.run {
                self.source = opened
                self.totalPages = opened.pageCount
                self.currentPageIndex = min(max(0, book.lastPageIndex), max(0, opened.pageCount - 1))
                self.isLoading = false
                self.persistVisualProgress()
            }
        }
    }

    private func prefetchNeededPages() async {
        guard let src = source, totalPages > 0, viewportW > 10, viewportH > 10 else { return }
        let scale = UIScreen.main.scale
        let pixelW = Int(viewportW * scale)
        let pixelH = Int(viewportH * scale)
        let step = isDualPage ? 2 : 1

        let targetMaxDim = isDualPage
            ? min(2000, max(800, max(pixelW / 2, pixelH)))
            : min(2200, max(900, max(pixelW, pixelH)))

        var candidates: [Int] = [currentPageIndex]
        if isDualPage { candidates.append(currentPageIndex + 1) }
        candidates.append(currentPageIndex + step)
        if isDualPage { candidates.append(currentPageIndex + step + 1) }
        candidates.append(currentPageIndex - step)
        if isDualPage { candidates.append(currentPageIndex - step + 1) }

        var neededIndices: [Int] = []
        var seen = Set<Int>()
        for idx in candidates where idx >= 0 && idx < totalPages {
            if seen.insert(idx).inserted {
                neededIndices.append(idx)
            }
        }

        let autoCrop = isPdf && settings.pdfAutoCrop
        for idx in neededIndices {
            if Task.isCancelled { return }
            if imageCache[idx] == nil {
                if let rendered = await src.renderPage(pageIndex: idx, targetMaxDim: targetMaxDim, autoCrop: autoCrop) {
                    if Task.isCancelled { return }
                    imageCache[idx] = rendered
                }
            }
        }

        let keepSet = Set(neededIndices)
        for key in Array(imageCache.keys) where !keepSet.contains(key) {
            imageCache.removeValue(forKey: key)
        }
    }

    private func exitReaderSafely() {
        guard !hasExited else { return }
        hasExited = true
        if !isLoading && totalPages > 0 {
            persistVisualProgress(synchronous: true)
        }
        onExitReader()
    }

    private func persistVisualProgress(synchronous: Bool = false) {
        guard totalPages > 0 else { return }
        let step = isDualPage ? 2 : 1
        let reached = min(totalPages, currentPageIndex + step)
        let fraction: Float = (reached >= totalPages)
            ? 1.0
            : min(1.0, max(0.0, Float(reached) / Float(totalPages)))
        let bookId = book.id
        let pg = currentPageIndex
        let repo = repository
        if synchronous {
            repo.updateVisualBookProgress(bookId: bookId, pageIndex: pg, progressFraction: fraction)
        } else {
            Task.detached(priority: .utility) {
                repo.updateVisualBookProgress(bookId: bookId, pageIndex: pg, progressFraction: fraction)
            }
        }
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

private struct VisualSettingsSheet: View {
    let isPdf: Bool
    let settings: ReaderSettings
    let onSettingsChange: (ReaderSettings) -> Void
    let onSwitchToPdfReflow: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if isPdf {
                    Section("PDF 版面與增強") {
                        Toggle("PDF 自動裁切白邊", isOn: Binding(
                            get: { settings.pdfAutoCrop },
                            set: { v in var c = settings; c.pdfAutoCrop = v; onSettingsChange(c) }
                        ))
                        Toggle("PDF 夜間深色反白", isOn: Binding(
                            get: { settings.pdfNightInvert },
                            set: { v in var c = settings; c.pdfNightInvert = v; onSettingsChange(c) }
                        ))
                        if let onSwitchToPdfReflow {
                            Button(action: onSwitchToPdfReflow) {
                                Label("切換至 PDF 文字重排模式（可調字體／直橫排）", systemImage: "doc.plaintext")
                            }
                        }
                    }
                } else {
                    Section("漫畫翻頁方向") {
                        Toggle("日漫右翻左順序（右頁→左頁，向右滑下一頁）", isOn: Binding(
                            get: { settings.comicRtl },
                            set: { v in var c = settings; c.comicRtl = v; onSettingsChange(c) }
                        ))
                    }
                }

                Section("翻頁與雙頁顯示") {
                    Picker("翻頁動畫", selection: Binding(
                        get: { settings.pageTurnAnimation },
                        set: { v in var c = settings; c.pageTurnAnimation = v; onSettingsChange(c) }
                    )) {
                        ForEach(PageTurnAnimation.allCases, id: \.rawValue) { anim in
                            Text(anim.label).tag(anim)
                        }
                    }

                    Picker("雙頁模式", selection: Binding(
                        get: { settings.dualPageMode },
                        set: { v in var c = settings; c.dualPageMode = v; onSettingsChange(c) }
                    )) {
                        ForEach(DualPageMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Toggle("雙頁中間仿真接縫陰影", isOn: Binding(
                        get: { settings.showSpineShadow },
                        set: { v in var c = settings; c.showSpineShadow = v; onSettingsChange(c) }
                    ))
                    Toggle("電子紙（E-ink）模式（關閉動畫）", isOn: Binding(
                        get: { settings.eInkMode },
                        set: { v in var c = settings; c.eInkMode = v; onSettingsChange(c) }
                    ))
                    Toggle("音量鍵翻頁", isOn: Binding(
                        get: { settings.volumeKeyPageTurn },
                        set: { v in var c = settings; c.volumeKeyPageTurn = v; onSettingsChange(c) }
                    ))
                }
            }
            .navigationTitle(isPdf ? "PDF 閱讀設定" : "漫畫閱讀設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
