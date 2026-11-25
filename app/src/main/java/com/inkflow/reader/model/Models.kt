package com.inkflow.reader.model

import android.graphics.Color

enum class BookFormat(val label: String) {
    TXT("TXT"),
    EPUB("EPUB"),
    PDF("PDF"),
    CBZ("CBZ"),
    CBR("CBR"),
    ZIP("ZIP"),
    MOBI("MOBI"),
    AZW3("AZW3")
}

enum class BookContentType(val label: String) {
    TEXT("文字"),
    COMIC("漫畫"),
    PDF("PDF")
}

enum class ReadStatusFilter(val label: String) {
    ALL("全部"),
    UNREAD("未讀"),
    READING("閱讀中"),
    FINISHED("已讀")
}

enum class ShelfSortField(val label: String) {
    ADDED_TIME("加入時間"),
    TITLE("書名"),
    AUTHOR("作者")
}

enum class ShelfCoverSize(val label: String, val minWidthDp: Int) {
    COMPACT("緊湊", 95),
    STANDARD("標準", 115),
    MEDIUM("中", 150),
    LARGE("大", 200),
    EXTRA_LARGE("特大", 265);

    fun stepLarger(): ShelfCoverSize {
        val idx = entries.indexOf(this)
        return if (idx in 0 until entries.lastIndex) entries[idx + 1] else this
    }

    fun stepSmaller(): ShelfCoverSize {
        val idx = entries.indexOf(this)
        return if (idx > 0) entries[idx - 1] else this
    }
}

data class BookItem(
    val id: String,
    val title: String,
    val author: String = "未知作者",
    val format: BookFormat,
    val contentType: BookContentType = BookContentType.TEXT,
    val localPath: String,
    val coverPath: String? = null,
    val tags: List<String> = emptyList(),
    val lastChapterIndex: Int = 0,
    val lastCharOffset: Int = 0,
    val lastPageIndex: Int = 0,
    val lastReadTime: Long = System.currentTimeMillis(),
    val addedTime: Long = System.currentTimeMillis(),
    val sourceFileName: String = "",
    val fileSizeBytes: Long = 0L,
    val contentHash: String = "",
    val readingProgress: Float = 0f,
    val isRead: Boolean = false,
    val hasStartedReading: Boolean = false
) {
    val isMarkedOrFinishedRead: Boolean
        get() = isRead || readingProgress >= 0.99f

    val isInProgress: Boolean
        get() = !isMarkedOrFinishedRead && (hasStartedReading || readingProgress > 0f)

    val isUnread: Boolean
        get() = !isMarkedOrFinishedRead && !isInProgress

    val displayProgressPercent: Int
        get() = (readingProgress * 100f).toInt().coerceIn(1, 98)
}

data class BatchImportResult(
    val importedCount: Int,
    val skippedDuplicateCount: Int,
    val unsupportedCount: Int,
    val failedCount: Int,
    val lastImportedTitle: String? = null
)

data class LocalFontItem(
    val displayName: String,
    val pathOrUri: String,
    val sourceLabel: String
)

data class Chapter(
    val index: Int,
    val title: String,
    val content: String
)

data class ParsedBook(
    val title: String,
    val author: String,
    val chapters: List<Chapter>,
    val coverBytes: ByteArray? = null,
    val contentType: BookContentType = BookContentType.TEXT
)

data class BookmarkItem(
    val id: String,
    val bookId: String,
    val chapterIndex: Int,
    val chapterTitle: String,
    val charOffset: Int,
    val preview: String,
    val createdAt: Long = System.currentTimeMillis()
)

data class SearchHit(
    val chapterIndex: Int,
    val chapterTitle: String,
    val charOffset: Int,
    val snippet: String
)

enum class WritingMode(val label: String) {
    HORIZONTAL("橫排"),
    VERTICAL("直排")
}

enum class DualPageMode(val label: String) {
    AUTO("自動雙頁"),
    SINGLE("強制單頁"),
    DUAL("強制左右雙頁")
}

enum class PageTurnAnimation(val label: String) {
    SIMULATION("仿真翻頁"),
    SLIDE("左右滑動"),
    NONE("無動畫")
}

enum class ChineseConvertMode(val label: String) {
    ORIGINAL("原文"),
    TO_TRADITIONAL_TW("轉繁體(台灣)"),
    TO_SIMPLIFIED("轉簡體")
}

enum class ReaderTheme(
    val label: String,
    val bgColor: Int,
    val textColor: Int,
    val subTextColor: Int,
    val pageBackColor: Int
) {
    DAY(
        label = "日間白",
        bgColor = Color.parseColor("#FFFFFF"),
        textColor = Color.parseColor("#1F2328"),
        subTextColor = Color.parseColor("#6E7781"),
        pageBackColor = Color.parseColor("#EFEFEF")
    ),
    SEPIA(
        label = "護眼米黃",
        bgColor = Color.parseColor("#F5EFE0"),
        textColor = Color.parseColor("#3B2F23"),
        subTextColor = Color.parseColor("#7C6B5A"),
        pageBackColor = Color.parseColor("#E6DBC2")
    ),
    NIGHT(
        label = "夜間深色",
        bgColor = Color.parseColor("#14171A"),
        textColor = Color.parseColor("#C9D1D9"),
        subTextColor = Color.parseColor("#7D8590"),
        pageBackColor = Color.parseColor("#20262D")
    ),
    EINK(
        label = "電子紙高對比",
        bgColor = Color.parseColor("#FFFFFF"),
        textColor = Color.parseColor("#000000"),
        subTextColor = Color.parseColor("#222222"),
        pageBackColor = Color.parseColor("#FFFFFF")
    )
}

enum class TapAction(val label: String) {
    PREV_PAGE("上一頁"),
    NEXT_PAGE("下一頁"),
    TOGGLE_MENU("選單")
}

data class ReaderSettings(
    val writingMode: WritingMode = WritingMode.VERTICAL,
    val verticalNaturalSwipe: Boolean = true,
    val dualPageMode: DualPageMode = DualPageMode.AUTO,
    val showSpineShadow: Boolean = true,
    val pageTurnAnimation: PageTurnAnimation = PageTurnAnimation.SIMULATION,
    val eInkMode: Boolean = false,
    val theme: ReaderTheme = ReaderTheme.SEPIA,
    val fontSizeSp: Float = 20f,
    val fontBold: Boolean = false,
    val letterSpacingEm: Float = 0.04f,
    val lineSpacingMultiplier: Float = 1.65f,
    val paragraphSpacingEm: Float = 0.45f,
    val paragraphIndentChars: Int = 2,
    val marginHorizontalDp: Float = 20f,
    val marginVerticalDp: Float = 24f,
    val customFontPath: String? = null,
    val customFontName: String? = null,
    val customFontFolderUri: String? = null,
    val chineseConvertMode: ChineseConvertMode = ChineseConvertMode.ORIGINAL,
    val volumeKeyPageTurn: Boolean = true,
    val comicRtl: Boolean = true,
    val pdfAutoCrop: Boolean = false,
    val pdfReflowMode: Boolean = false,
    val pdfNightInvert: Boolean = false,
    val shelfSortField: ShelfSortField = ShelfSortField.ADDED_TIME,
    val shelfSortAscending: Boolean = false,
    val shelfCoverSize: ShelfCoverSize = ShelfCoverSize.STANDARD,
    val tapZones: List<TapAction> = defaultVerticalTapZones()
) {
    val effectiveTheme: ReaderTheme
        get() = if (eInkMode) ReaderTheme.EINK else theme

    val effectiveAnimation: PageTurnAnimation
        get() = if (eInkMode) PageTurnAnimation.NONE else pageTurnAnimation

    val effectiveSpineShadow: Boolean
        get() = showSpineShadow && !eInkMode

    companion object {
        fun defaultHorizontalTapZones(): List<TapAction> = listOf(
            TapAction.PREV_PAGE, TapAction.TOGGLE_MENU, TapAction.NEXT_PAGE,
            TapAction.PREV_PAGE, TapAction.TOGGLE_MENU, TapAction.NEXT_PAGE,
            TapAction.PREV_PAGE, TapAction.NEXT_PAGE,   TapAction.NEXT_PAGE
        )

        fun defaultVerticalTapZones(): List<TapAction> = listOf(
            TapAction.NEXT_PAGE, TapAction.TOGGLE_MENU, TapAction.PREV_PAGE,
            TapAction.NEXT_PAGE, TapAction.TOGGLE_MENU, TapAction.PREV_PAGE,
            TapAction.NEXT_PAGE, TapAction.NEXT_PAGE,   TapAction.PREV_PAGE
        )
    }
}
