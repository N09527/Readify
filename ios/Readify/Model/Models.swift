import Foundation
import SwiftUI
import UIKit

enum BookFormat: String, Codable, CaseIterable {
    case TXT
    case EPUB
    case PDF
    case CBZ
    case CBR
    case ZIP
    case MOBI
    case AZW3

    var label: String { rawValue }
}

enum BookContentType: String, Codable, CaseIterable {
    case TEXT
    case COMIC
    case PDF

    var label: String {
        switch self {
        case .TEXT: return "文字"
        case .COMIC: return "漫畫"
        case .PDF: return "PDF"
        }
    }
}

enum ReadStatusFilter: String, CaseIterable, Identifiable {
    case ALL
    case UNREAD
    case READING
    case FINISHED

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ALL: return "全部"
        case .UNREAD: return "未讀"
        case .READING: return "閱讀中"
        case .FINISHED: return "已讀"
        }
    }
}

enum ShelfSortField: String, Codable, CaseIterable, Identifiable {
    case ADDED_TIME
    case TITLE
    case AUTHOR

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ADDED_TIME: return "加入時間"
        case .TITLE: return "書名"
        case .AUTHOR: return "作者"
        }
    }
}

enum ShelfCoverSize: String, Codable, CaseIterable, Identifiable {
    case COMPACT
    case STANDARD
    case MEDIUM
    case LARGE
    case EXTRA_LARGE

    var id: String { rawValue }

    var label: String {
        switch self {
        case .COMPACT: return "緊湊"
        case .STANDARD: return "標準"
        case .MEDIUM: return "中"
        case .LARGE: return "大"
        case .EXTRA_LARGE: return "特大"
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .COMPACT: return 95
        case .STANDARD: return 115
        case .MEDIUM: return 150
        case .LARGE: return 200
        case .EXTRA_LARGE: return 265
        }
    }

    var gridSpacing: CGFloat {
        switch self {
        case .COMPACT: return 10
        case .STANDARD: return 14
        case .MEDIUM: return 16
        case .LARGE: return 20
        case .EXTRA_LARGE: return 24
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .COMPACT, .STANDARD: return 7
        case .MEDIUM: return 9
        case .LARGE: return 11
        case .EXTRA_LARGE: return 13
        }
    }

    func stepLarger() -> ShelfCoverSize {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx + 1 < all.count else { return self }
        return all[idx + 1]
    }

    func stepSmaller() -> ShelfCoverSize {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx > 0 else { return self }
        return all[idx - 1]
    }
}

struct BookItem: Identifiable, Equatable {
    var id: String
    var title: String
    var author: String = "未知作者"
    var format: BookFormat
    var contentType: BookContentType = .TEXT
    var localPath: String
    var coverPath: String? = nil
    var tags: [String] = []
    var lastChapterIndex: Int = 0
    var lastCharOffset: Int = 0
    var lastPageIndex: Int = 0
    var lastReadTime: Int64 = BookItem.nowMs()
    var addedTime: Int64 = BookItem.nowMs()
    var sourceFileName: String = ""
    var fileSizeBytes: Int64 = 0
    var contentHash: String = ""
    var readingProgress: Float = 0
    var isRead: Bool = false
    var hasStartedReading: Bool = false

    var isMarkedOrFinishedRead: Bool {
        isRead || readingProgress >= 0.99
    }

    var isInProgress: Bool {
        !isMarkedOrFinishedRead && (hasStartedReading || readingProgress > 0)
    }

    var isUnread: Bool {
        !isMarkedOrFinishedRead && !isInProgress
    }

    var displayProgressPercent: Int {
        min(98, max(1, Int(readingProgress * 100.0)))
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }
}

struct BatchImportResult: Equatable {
    var importedCount: Int
    var skippedDuplicateCount: Int
    var unsupportedCount: Int
    var failedCount: Int
    var lastImportedTitle: String? = nil
}

struct LocalFontItem: Identifiable, Equatable {
    var id: String { pathOrUri }
    var displayName: String
    var pathOrUri: String
    var sourceLabel: String
}

struct Chapter: Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var title: String
    var content: String
}

struct ParsedBook {
    var title: String
    var author: String
    var chapters: [Chapter]
    var coverBytes: Data? = nil
    var contentType: BookContentType = .TEXT
}

struct BookmarkItem: Identifiable, Equatable {
    var id: String
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var charOffset: Int
    var preview: String
    var createdAt: Int64 = BookItem.nowMs()
}

struct SearchHit: Identifiable, Equatable {
    var id: String { "\(chapterIndex)-\(charOffset)" }
    var chapterIndex: Int
    var chapterTitle: String
    var charOffset: Int
    var snippet: String
}

enum WritingMode: String, Codable, CaseIterable {
    case HORIZONTAL
    case VERTICAL

    var label: String {
        switch self {
        case .HORIZONTAL: return "橫排"
        case .VERTICAL: return "直排"
        }
    }
}

enum DualPageMode: String, Codable, CaseIterable {
    case AUTO
    case SINGLE
    case DUAL

    var label: String {
        switch self {
        case .AUTO: return "自動雙頁"
        case .SINGLE: return "強制單頁"
        case .DUAL: return "強制左右雙頁"
        }
    }
}

enum PageTurnAnimation: String, Codable, CaseIterable {
    case SIMULATION
    case SLIDE
    case NONE

    var label: String {
        switch self {
        case .SIMULATION: return "仿真翻頁"
        case .SLIDE: return "左右滑動"
        case .NONE: return "無動畫"
        }
    }
}

enum ChineseConvertMode: String, Codable, CaseIterable {
    case ORIGINAL
    case TO_TRADITIONAL_TW
    case TO_SIMPLIFIED

    var label: String {
        switch self {
        case .ORIGINAL: return "原文"
        case .TO_TRADITIONAL_TW: return "轉繁體(台灣)"
        case .TO_SIMPLIFIED: return "轉簡體"
        }
    }
}

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case DAY
    case SEPIA
    case NIGHT
    case EINK

    var id: String { rawValue }

    var label: String {
        switch self {
        case .DAY: return "日間白"
        case .SEPIA: return "護眼米黃"
        case .NIGHT: return "夜間深色"
        case .EINK: return "電子紙高對比"
        }
    }

    var bgUIColor: UIColor {
        switch self {
        case .DAY: return UIColor(hex: 0xFFFFFF)
        case .SEPIA: return UIColor(hex: 0xF5EFE0)
        case .NIGHT: return UIColor(hex: 0x14171A)
        case .EINK: return UIColor(hex: 0xFFFFFF)
        }
    }

    var textUIColor: UIColor {
        switch self {
        case .DAY: return UIColor(hex: 0x1F2328)
        case .SEPIA: return UIColor(hex: 0x3B2F23)
        case .NIGHT: return UIColor(hex: 0xC9D1D9)
        case .EINK: return UIColor(hex: 0x000000)
        }
    }

    var subTextUIColor: UIColor {
        switch self {
        case .DAY: return UIColor(hex: 0x6E7781)
        case .SEPIA: return UIColor(hex: 0x7C6B5A)
        case .NIGHT: return UIColor(hex: 0x7D8590)
        case .EINK: return UIColor(hex: 0x222222)
        }
    }

    var pageBackUIColor: UIColor {
        switch self {
        case .DAY: return UIColor(hex: 0xEFEFEF)
        case .SEPIA: return UIColor(hex: 0xE6DBC2)
        case .NIGHT: return UIColor(hex: 0x20262D)
        case .EINK: return UIColor(hex: 0xFFFFFF)
        }
    }

    var bgSwiftUIColor: Color { Color(uiColor: bgUIColor) }
    var textSwiftUIColor: Color { Color(uiColor: textUIColor) }

    var isDark: Bool {
        self == .NIGHT
    }
}

enum TapAction: String, Codable, CaseIterable {
    case PREV_PAGE
    case NEXT_PAGE
    case TOGGLE_MENU

    var label: String {
        switch self {
        case .PREV_PAGE: return "上一頁"
        case .NEXT_PAGE: return "下一頁"
        case .TOGGLE_MENU: return "選單"
        }
    }
}

struct ReaderSettings: Equatable {
    var writingMode: WritingMode = .VERTICAL
    var verticalNaturalSwipe: Bool = true
    var dualPageMode: DualPageMode = .AUTO
    var showSpineShadow: Bool = true
    var pageTurnAnimation: PageTurnAnimation = .SIMULATION
    var eInkMode: Bool = false
    var theme: ReaderTheme = .SEPIA
    var fontSizeSp: Float = 20
    var fontBold: Bool = false
    var letterSpacingEm: Float = 0.04
    var lineSpacingMultiplier: Float = 1.65
    var paragraphSpacingEm: Float = 0.45
    var paragraphIndentChars: Int = 2
    var marginHorizontalDp: Float = 20
    var marginVerticalDp: Float = 24
    var customFontPath: String? = nil
    var customFontName: String? = nil
    var customFontFolderBookmark: String? = nil
    var chineseConvertMode: ChineseConvertMode = .ORIGINAL
    var volumeKeyPageTurn: Bool = true
    var comicRtl: Bool = true
    var pdfAutoCrop: Bool = false
    var pdfReflowMode: Bool = false
    var pdfNightInvert: Bool = false
    var shelfSortField: ShelfSortField = .ADDED_TIME
    var shelfSortAscending: Bool = false
    var shelfCoverSize: ShelfCoverSize = .STANDARD
    var tapZones: [TapAction] = ReaderSettings.defaultVerticalTapZones()

    var effectiveTheme: ReaderTheme {
        eInkMode ? .EINK : theme
    }

    var effectiveAnimation: PageTurnAnimation {
        eInkMode ? .NONE : pageTurnAnimation
    }

    var effectiveSpineShadow: Bool {
        showSpineShadow && !eInkMode
    }

    static func defaultHorizontalTapZones() -> [TapAction] {
        [
            .PREV_PAGE, .TOGGLE_MENU, .NEXT_PAGE,
            .PREV_PAGE, .TOGGLE_MENU, .NEXT_PAGE,
            .PREV_PAGE, .NEXT_PAGE,   .NEXT_PAGE
        ]
    }

    static func defaultVerticalTapZones() -> [TapAction] {
        [
            .NEXT_PAGE, .TOGGLE_MENU, .PREV_PAGE,
            .NEXT_PAGE, .TOGGLE_MENU, .PREV_PAGE,
            .NEXT_PAGE, .NEXT_PAGE,   .PREV_PAGE
        ]
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }

    var relativeLuminance: CGFloat {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
