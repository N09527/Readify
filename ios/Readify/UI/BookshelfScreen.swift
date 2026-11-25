import SwiftUI
import UIKit

struct BookshelfScreen: View {
    let books: [BookItem]
    let repository: AppRepository
    let eInkMode: Bool
    let sortField: ShelfSortField
    let sortAscending: Bool
    let isImporting: Bool
    let importStatusMessage: String?
    let onDismissStatus: () -> Void
    let onImportFilesClick: () -> Void
    let onImportFolderClick: () -> Void
    let onScanFilesAppClick: () -> Void
    let onOpenBook: (BookItem) -> Void
    let onDeleteBook: (BookItem) -> Void
    let onBatchDeleteBooks: (Set<String>) -> Void
    let onUpdateBookTags: (BookItem, [String]) -> Void
    let onBatchAddTags: (Set<String>, [String]) -> Void
    let onBatchRemoveTags: (Set<String>, [String]) -> Void
    let onSetBookReadStatus: (BookItem, Bool) -> Void
    let onBatchSetReadStatus: (Set<String>, Bool) -> Void
    let onUpdateBookContentType: (BookItem, BookContentType) -> Void
    let onSortChange: (ShelfSortField, Bool) -> Void
    let onToggleEInkMode: () -> Void

    @State private var isGridView = true
    @State private var selectedStatus: ReadStatusFilter = .ALL
    @State private var selectedTags: Set<String> = []
    @State private var isSearchActive = false
    @State private var searchQuery = ""

    @State private var editingBook: BookItem?
    @State private var isSelectionMode = false
    @State private var selectedBookIds: Set<String> = []
    @State private var showBatchTagSheet = false
    @State private var showBatchDeleteConfirm = false
    @State private var showImportSheet = false

    private var allAvailableTags: [String] {
        Array(
            Set(
                books.flatMap { $0.tags }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "未分類" }
            )
        ).sorted(by: NaturalSort.lessThan)
    }

    private var filteredBooks: [BookItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = books.filter { book in
            let statusMatches: Bool = {
                switch selectedStatus {
                case .ALL: return true
                case .UNREAD: return book.isUnread
                case .READING: return book.isInProgress
                case .FINISHED: return book.isMarkedOrFinishedRead
                }
            }()
            let tagsMatch = selectedTags.isEmpty || selectedTags.allSatisfy { book.tags.contains($0) }
            let queryMatches = q.isEmpty ||
                book.title.localizedCaseInsensitiveContains(q) ||
                book.author.localizedCaseInsensitiveContains(q)
            return statusMatches && tagsMatch && queryMatches
        }

        return filtered.sorted { a, b in
            let cmp: Int = {
                switch sortField {
                case .ADDED_TIME:
                    if a.addedTime == b.addedTime { return 0 }
                    return a.addedTime < b.addedTime ? -1 : 1
                case .TITLE:
                    return NaturalSort.compareNatural(a.title.lowercased(), b.title.lowercased())
                case .AUTHOR:
                    let c = NaturalSort.compareNatural(a.author.lowercased(), b.author.lowercased())
                    return c != 0 ? c : NaturalSort.compareNatural(a.title.lowercased(), b.title.lowercased())
                }
            }()
            let ordered = sortAscending ? cmp : -cmp
            if ordered != 0 { return ordered < 0 }
            return a.id < b.id
        }
    }

    private var allVisibleSelected: Bool {
        !filteredBooks.isEmpty && filteredBooks.allSatisfy { selectedBookIds.contains($0.id) }
    }

    private var bgColor: Color {
        eInkMode ? .white : Color(uiColor: .systemBackground)
    }

    private var fgColor: Color {
        eInkMode ? .black : .primary
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                bgColor.ignoresSafeArea()

                VStack(spacing: 6) {
                    if isSearchActive && !isSelectionMode {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("搜尋書名或作者…", text: $searchQuery)
                                .textFieldStyle(.plain)
                            Button {
                                if !searchQuery.isEmpty {
                                    searchQuery = ""
                                } else {
                                    isSearchActive = false
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                    }

                    if let msg = importStatusMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(msg)
                                    .font(.footnote)
                                    .foregroundStyle(fgColor)
                                Spacer()
                                if !isImporting {
                                    Button(action: onDismissStatus) {
                                        Image(systemName: "xmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(fgColor)
                                    }
                                }
                            }
                            if isImporting {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(eInkMode ? Color(white: 0.93) : Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 14)
                    }

                    // Row 1: Reading Status Filter
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ReadStatusFilter.allCases) { status in
                                SelectableChip(
                                    label: status.label,
                                    selected: selectedStatus == status,
                                    eInkMode: eInkMode
                                ) {
                                    selectedStatus = status
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                    }

                    // Row 2: Multi-Tag Filter
                    if !allAvailableTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Image(systemName: "tag")
                                    .font(.caption)
                                    .foregroundStyle(fgColor.opacity(0.6))
                                if !selectedTags.isEmpty {
                                    Button {
                                        selectedTags.removeAll()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "xmark")
                                            Text("清除標籤 (\(selectedTags.count))")
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color(uiColor: .tertiarySystemFill))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                ForEach(allAvailableTags, id: \.self) { tag in
                                    let active = selectedTags.contains(tag)
                                    SelectableChip(
                                        label: "#\(tag)",
                                        selected: active,
                                        eInkMode: eInkMode
                                    ) {
                                        if active { selectedTags.remove(tag) }
                                        else { selectedTags.insert(tag) }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 2)
                        }
                    }

                    // Main Content
                    if filteredBooks.isEmpty {
                        Spacer()
                        emptyShelfView
                        Spacer()
                    } else if isGridView {
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 116), spacing: 14)],
                                spacing: 16
                            ) {
                                ForEach(filteredBooks) { book in
                                    let selected = selectedBookIds.contains(book.id)
                                    BookGridCardView(
                                        book: book,
                                        coverURL: repository.resolveCoverFileURL(book),
                                        eInkMode: eInkMode,
                                        isSelectionMode: isSelectionMode,
                                        isSelected: selected,
                                        onTap: {
                                            if isSelectionMode { toggleSelection(book.id) }
                                            else { onOpenBook(book) }
                                        },
                                        onLongPress: {
                                            if !isSelectionMode {
                                                isSelectionMode = true
                                                selectedBookIds = [book.id]
                                            } else {
                                                toggleSelection(book.id)
                                            }
                                        },
                                        onMoreTap: { editingBook = book }
                                    )
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                            .padding(.bottom, 96)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredBooks) { book in
                                    let selected = selectedBookIds.contains(book.id)
                                    BookListRowView(
                                        book: book,
                                        coverURL: repository.resolveCoverFileURL(book),
                                        eInkMode: eInkMode,
                                        isSelectionMode: isSelectionMode,
                                        isSelected: selected,
                                        onTap: {
                                            if isSelectionMode { toggleSelection(book.id) }
                                            else { onOpenBook(book) }
                                        },
                                        onLongPress: {
                                            if !isSelectionMode {
                                                isSelectionMode = true
                                                selectedBookIds = [book.id]
                                            } else {
                                                toggleSelection(book.id)
                                            }
                                        },
                                        onMoreTap: { editingBook = book }
                                    )
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                            .padding(.bottom, 96)
                        }
                    }
                }

                // Floating Import Button
                if !isSelectionMode {
                    Button {
                        if !isImporting { showImportSheet = true }
                    } label: {
                        HStack(spacing: 8) {
                            if isImporting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "plus")
                                    .font(.headline)
                            }
                            Text(isImporting ? "匯入中…" : "匯入電子書 / 漫畫")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .background(eInkMode ? Color.black : Color.accentColor)
                        .clipShape(Capsule())
                        .shadow(color: eInkMode ? .clear : .black.opacity(0.22), radius: 6, y: 3)
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        Button {
                            exitSelectionMode()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Readify 書架")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(fgColor)
                            let countText = filteredBooks.count != books.count
                                ? "\(filteredBooks.count)/\(books.count) 本"
                                : "\(books.count) 本"
                            let arrow = sortAscending ? "↑" : "↓"
                            Text("\(countText) · \(sortField.label)\(arrow)\(eInkMode ? " · 電子紙" : "")")
                                .font(.caption2)
                                .foregroundStyle(fgColor.opacity(0.65))
                        }
                    }
                }

                ToolbarItem(placement: .principal) {
                    if isSelectionMode {
                        Text("已選取 \(selectedBookIds.count) 本")
                            .font(.headline)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSelectionMode {
                        Button(allVisibleSelected ? "取消全選" : "全選") {
                            let visibleIds = Set(filteredBooks.map { $0.id })
                            if allVisibleSelected {
                                selectedBookIds.subtract(visibleIds)
                            } else {
                                selectedBookIds.formUnion(visibleIds)
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                if isSearchActive {
                                    isSearchActive = false
                                    searchQuery = ""
                                } else {
                                    isSearchActive = true
                                }
                            } label: {
                                Image(systemName: isSearchActive ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            }

                            Menu {
                                ForEach(ShelfSortField.allCases) { field in
                                    Button {
                                        let defaultAsc = (field != .ADDED_TIME)
                                        let nextAsc = (sortField == field) ? sortAscending : defaultAsc
                                        onSortChange(field, nextAsc)
                                    } label: {
                                        if sortField == field {
                                            Label("依\(field.label)", systemImage: "checkmark")
                                        } else {
                                            Text("依\(field.label)")
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    onSortChange(sortField, true)
                                } label: {
                                    if sortAscending {
                                        Label("升序（↑）", systemImage: "checkmark")
                                    } else {
                                        Text("升序（↑）")
                                    }
                                }
                                Button {
                                    onSortChange(sortField, false)
                                } label: {
                                    if !sortAscending {
                                        Label("降序（↓）", systemImage: "checkmark")
                                    } else {
                                        Text("降序（↓）")
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                            }

                            if !books.isEmpty {
                                Button {
                                    isSelectionMode = true
                                    selectedBookIds = []
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                }
                            }

                            Button(action: onToggleEInkMode) {
                                Image(systemName: eInkMode ? "circle.lefthalf.filled.inverse" : "circle.lefthalf.filled")
                            }

                            Button {
                                isGridView.toggle()
                            } label: {
                                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    batchBottomBar
                }
            }
        }
        .onChange(of: allAvailableTags) { valid in
            selectedTags = selectedTags.intersection(Set(valid))
        }
        .onChange(of: books) { newBooks in
            let validIds = Set(newBooks.map { $0.id })
            selectedBookIds = selectedBookIds.intersection(validIds)
            if newBooks.isEmpty { isSelectionMode = false }
        }
        .sheet(isPresented: $showImportSheet) {
            importMethodSheet
        }
        .sheet(isPresented: $showBatchTagSheet) {
            BatchTagEditorSheet(
                selectedCount: selectedBookIds.count,
                allAvailableTags: allAvailableTags,
                onAddTags: { tags in
                    onBatchAddTags(selectedBookIds, tags)
                    exitSelectionMode()
                },
                onRemoveTags: { tags in
                    onBatchRemoveTags(selectedBookIds, tags)
                    exitSelectionMode()
                }
            )
        }
        .sheet(item: $editingBook) { book in
            SingleBookManageSheet(
                book: book,
                allAvailableTags: allAvailableTags,
                onSetReadStatus: { isRead in onSetBookReadStatus(book, isRead) },
                onUpdateTags: { tags in onUpdateBookTags(book, tags) },
                onUpdateContentType: { ct in onUpdateBookContentType(book, ct) },
                onDeleteBook: { onDeleteBook(book) }
            )
        }
        .alert("確定要刪除 \(selectedBookIds.count) 本書嗎？", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("確定刪除", role: .destructive) {
                onBatchDeleteBooks(selectedBookIds)
                exitSelectionMode()
            }
        } message: {
            Text("刪除後會移除 App 內匯入的書檔與對應書籤（不會影響「檔案」App 其他資料夾裡的原始檔）。")
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedBookIds.contains(id) {
            selectedBookIds.remove(id)
        } else {
            selectedBookIds.insert(id)
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedBookIds.removeAll()
    }

    private var emptyShelfView: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(fgColor.opacity(0.35))
            if books.isEmpty {
                Text("書架目前是空的")
                    .font(.headline)
                    .foregroundStyle(fgColor)
                Text("支援 TXT / EPUB(文字+漫畫) / PDF / CBZ / CBR / ZIP / MOBI / AZW3")
                    .font(.caption)
                    .foregroundStyle(fgColor.opacity(0.65))
                    .multilineTextAlignment(.center)
                Text("可點右下角選擇單檔、多檔或整個資料夾匯入，或從「檔案」App 分享至 Readify")
                    .font(.caption2)
                    .foregroundStyle(fgColor.opacity(0.5))
                    .multilineTextAlignment(.center)
            } else {
                Text("符合目前篩選條件的書籍為 0 本")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(fgColor)
                Button("重設篩選條件") {
                    selectedStatus = .ALL
                    selectedTags.removeAll()
                    searchQuery = ""
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
    }

    private var batchBottomBar: some View {
        let hasSelection = !selectedBookIds.isEmpty
        let tint: Color = eInkMode ? .black : .primary
        return HStack {
            Spacer()
            BottomMenuActionButton(
                systemImage: "checkmark.circle",
                label: "設為已讀",
                tint: hasSelection ? tint : tint.opacity(0.35)
            ) {
                guard hasSelection else { return }
                onBatchSetReadStatus(selectedBookIds, true)
                exitSelectionMode()
            }
            Spacer()
            BottomMenuActionButton(
                systemImage: "circle",
                label: "設為未讀",
                tint: hasSelection ? tint : tint.opacity(0.35)
            ) {
                guard hasSelection else { return }
                onBatchSetReadStatus(selectedBookIds, false)
                exitSelectionMode()
            }
            Spacer()
            BottomMenuActionButton(
                systemImage: "tag",
                label: "批次標籤",
                tint: hasSelection ? tint : tint.opacity(0.35)
            ) {
                guard hasSelection else { return }
                showBatchTagSheet = true
            }
            Spacer()
            BottomMenuActionButton(
                systemImage: "trash",
                label: "刪除選取",
                tint: hasSelection ? (eInkMode ? .black : .red) : .gray.opacity(0.35)
            ) {
                guard hasSelection else { return }
                showBatchDeleteConfirm = true
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(eInkMode ? Color.white : Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var importMethodSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("支援 TXT、EPUB（文字與漫畫）、PDF、CBZ、CBR（RAR4/RAR5）、ZIP、MOBI、AZW3")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    showImportSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onImportFilesClick()
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("選擇檔案匯入（支援單選 / 多選）")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("從「檔案」App、iCloud Drive 或外接隨身碟一次選取多本電子書")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button {
                    showImportSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onImportFolderClick()
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("選擇整個資料夾匯入")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("自動遞迴掃描資料夾與子資料夾內所有支援格式，並自動略過重複書籍")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button {
                    showImportSheet = false
                    onScanFilesAppClick()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("掃描「檔案 → Readify」資料夾")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("透過 Mac Finder 檔案共享或「檔案」App 放入 Readify 根目錄的書籍可一鍵匯入")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(20)
            .navigationTitle("匯入電子書 / 漫畫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { showImportSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Grid Card & List Row

private struct BookGridCardView: View {
    let book: BookItem
    let coverURL: URL?
    let eInkMode: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onMoreTap: () -> Void

    private var formatBadgeLabel: String {
        if book.contentType == .COMIC && [.EPUB, .MOBI, .AZW3].contains(book.format) {
            return "\(book.format.label)·漫"
        }
        return book.format.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(0.70, contentMode: .fit)
                .overlay {
                    ZStack {
                        BookCoverView(title: book.title, coverURL: coverURL, eInkMode: eInkMode)

                        if isSelected && !eInkMode {
                            Color.accentColor.opacity(0.22)
                        }

                        // Top-left format badge
                        VStack {
                            HStack {
                                Text(formatBadgeLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.72))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(4)

                        // Bottom-right read status badge
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                ReadStatusBadgeView(book: book, eInkMode: eInkMode)
                            }
                        }

                        // Top-right selection or menu button
                        VStack {
                            HStack {
                                Spacer()
                                if isSelectionMode {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(isSelected ? (eInkMode ? .black : Color.accentColor) : .gray)
                                        .padding(2)
                                        .background(Color.white.opacity(0.92))
                                        .clipShape(Circle())
                                        .padding(5)
                                } else {
                                    Button(action: onMoreTap) {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 26, height: 26)
                                            .background(Color.black.opacity(0.50))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(5)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(borderColor, lineWidth: isSelected ? 2.5 : (eInkMode ? 1 : 0.4))
                )

            Text(book.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(eInkMode ? .black : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(book.author.isEmpty ? "未知作者" : book.author)
                .font(.caption2)
                .foregroundStyle(eInkMode ? .black.opacity(0.7) : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
    }

    private var borderColor: Color {
        if isSelected { return eInkMode ? .black : Color.accentColor }
        return eInkMode ? .black : Color.secondary.opacity(0.25)
    }
}

private struct BookListRowView: View {
    let book: BookItem
    let coverURL: URL?
    let eInkMode: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onMoreTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? (eInkMode ? .black : Color.accentColor) : .gray)
            }

            BookCoverView(title: book.title, coverURL: coverURL, eInkMode: eInkMode)
                .frame(width: 48, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(eInkMode ? .black : .primary)
                    .lineLimit(1)

                let tagsSuffix = book.tags.isEmpty ? "" : " · " + book.tags.map { "#\($0)" }.joined(separator: " ")
                Text("\(book.author.isEmpty ? "未知作者" : book.author) · \(book.format.label)\(tagsSuffix)")
                    .font(.caption)
                    .foregroundStyle(eInkMode ? .black.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if book.isMarkedOrFinishedRead {
                Text("已讀")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(eInkMode ? .white : Color(uiColor: UIColor(hex: 0x166534)))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(eInkMode ? Color.black : Color(uiColor: UIColor(hex: 0xDCFCE7)))
                    .clipShape(Capsule())
            } else if book.isInProgress {
                Text("\(book.displayProgressPercent)%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(Capsule())
            }

            if !isSelectionMode {
                Button(action: onMoreTap) {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            isSelected
                ? (eInkMode ? Color(white: 0.93) : Color.accentColor.opacity(0.12))
                : (eInkMode ? Color.white : Color(uiColor: .secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? (eInkMode ? Color.black : Color.accentColor) : (eInkMode ? Color.black : Color.secondary.opacity(0.2)),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
    }
}

private struct ReadStatusBadgeView: View {
    let book: BookItem
    let eInkMode: Bool

    var body: some View {
        if book.isMarkedOrFinishedRead {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                Text("已讀")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(eInkMode ? Color.black : Color(uiColor: UIColor(hex: 0x15803D)).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(4)
        } else if book.isInProgress {
            Text("\(book.displayProgressPercent)%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(eInkMode ? .black : .white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(eInkMode ? Color.white : Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(eInkMode ? Color.black : .clear, lineWidth: 1)
                )
                .padding(4)
        }
    }
}

private struct BookCoverView: View {
    let title: String
    let coverURL: URL?
    let eInkMode: Bool

    var body: some View {
        if let url = coverURL, let uiImg = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImg)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            ZStack {
                (eInkMode ? Color.white : Color(uiColor: UIColor(hex: 0x334155)))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(eInkMode ? .black : Color(uiColor: UIColor(hex: 0xF8FAFC)))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(8)
            }
        }
    }
}

// MARK: - Dialog Sheets

private struct BatchTagEditorSheet: View {
    let selectedCount: Int
    let allAvailableTags: [String]
    let onAddTags: ([String]) -> Void
    let onRemoveTags: ([String]) -> Void

    @State private var newTagInput = ""
    @State private var pickedTags: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var combinedTags: [String] {
        let typed = newTagInput
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty && $0 != "未分類" }
        return Array(pickedTags.union(typed))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("輸入新標籤（多個可用逗號分隔）") {
                    TextField("例如：科幻, 最愛", text: $newTagInput)
                }

                if !allAvailableTags.isEmpty {
                    Section("點選現有標籤（可複選）") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(allAvailableTags, id: \.self) { tag in
                                    let active = pickedTags.contains(tag)
                                    SelectableChip(label: "#\(tag)", selected: active) {
                                        if active { pickedTags.remove(tag) }
                                        else { pickedTags.insert(tag) }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    Button {
                        onAddTags(combinedTags)
                        dismiss()
                    } label: {
                        Text("加入標籤至選取書籍")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fontWeight(.semibold)
                    }
                    .disabled(combinedTags.isEmpty)

                    Button(role: .destructive) {
                        onRemoveTags(combinedTags)
                        dismiss()
                    } label: {
                        Text("從選取書籍移除這些標籤")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(combinedTags.isEmpty)
                }
            }
            .navigationTitle("批次標籤（\(selectedCount) 本）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SingleBookManageSheet: View {
    let book: BookItem
    let allAvailableTags: [String]
    let onSetReadStatus: (Bool) -> Void
    let onUpdateTags: ([String]) -> Void
    let onUpdateContentType: (BookContentType) -> Void
    let onDeleteBook: () -> Void

    @State private var currentTags: [String] = []
    @State private var tagInput: String = ""
    @State private var isReadState: Bool = false
    @State private var isComicMode: Bool = false
    @Environment(\.dismiss) private var dismiss

    private func appendTypedTags() {
        let added = tagInput
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty && $0 != "未分類" }
        for t in added where !currentTags.contains(t) {
            currentTags.append(t)
        }
        tagInput = ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                        Text("作者：\(book.author.isEmpty ? "未知作者" : book.author) · \(book.format.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            isReadState = true
                            onSetReadStatus(true)
                        } label: {
                            Label("標記已讀", systemImage: isReadState ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isReadState ? .green : .gray)

                        Button {
                            isReadState = false
                            onSetReadStatus(false)
                        } label: {
                            Label("重設未讀", systemImage: !isReadState && book.isUnread ? "checkmark.circle.fill" : "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("標籤分類（可設定多個 Tag）") {
                    if currentTags.isEmpty {
                        Text("目前無標籤")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(currentTags, id: \.self) { tag in
                                    Button {
                                        currentTags.removeAll { $0 == tag }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text("#\(tag)")
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("新增標籤（例：推理, 收藏）", text: $tagInput)
                        Button("加入") {
                            appendTypedTags()
                        }
                        .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    let suggested = allAvailableTags.filter { !currentTags.contains($0) }
                    if !suggested.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggested, id: \.self) { tag in
                                    Button("+#\(tag)") {
                                        if !currentTags.contains(tag) {
                                            currentTags.append(tag)
                                        }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                if [.EPUB, .MOBI, .AZW3].contains(book.format) {
                    Section("閱讀模式") {
                        Toggle("以漫畫圖片模式閱讀", isOn: $isComicMode)
                            .onChange(of: isComicMode) { val in
                                onUpdateContentType(val ? .COMIC : .TEXT)
                            }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDeleteBook()
                        dismiss()
                    } label: {
                        Label("刪除此書", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("書籍管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        appendTypedTags()
                        onUpdateTags(currentTags)
                        dismiss()
                    }
                }
            }
            .onAppear {
                currentTags = book.tags
                isReadState = book.isMarkedOrFinishedRead
                isComicMode = (book.contentType == .COMIC)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
