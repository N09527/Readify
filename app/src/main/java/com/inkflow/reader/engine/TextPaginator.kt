package com.inkflow.reader.engine

import android.graphics.Paint
import com.inkflow.reader.model.WritingMode
import kotlin.math.floor

data class PageLine(
    val text: String,
    val startOffset: Int,
    val endOffset: Int,
    val isParagraphEnd: Boolean = false,
    val isTitleLine: Boolean = false,
    // Horizontal mode: Y distance from rect.top to line top
    // Vertical mode:   X distance from rect.right to column right edge
    val positionPx: Float = 0f
)

data class PageContent(
    val pageIndex: Int,
    val startOffset: Int,
    val endOffset: Int,
    val lines: List<PageLine>,
    val isFullPage: Boolean = false,
    val usedSpanPx: Float = 0f
)

/**
 * Pure native paginator supporting Horizontal & Vertical modes with:
 *  - Configurable letter spacing (字距)
 *  - Configurable line spacing (行距)
 *  - Configurable paragraph spacing (段落距)
 *  - Configurable first-line paragraph indent (段首縮排 0~N 字)
 */
object TextPaginator {

    fun paginate(
        chapterTitle: String,
        chapterContent: String,
        writingMode: WritingMode,
        contentWidthPx: Float,
        contentHeightPx: Float,
        textPaint: Paint,
        lineSpacingMultiplier: Float,
        letterSpacingEm: Float,
        paragraphSpacingEm: Float,
        paragraphIndentChars: Int
    ): List<PageContent> {
        if (contentWidthPx <= 20f || contentHeightPx <= 20f) return emptyList()

        val hasTitle = chapterTitle.isNotBlank()
        val fullText = buildString {
            if (hasTitle) {
                append(chapterTitle.trim())
                append("\n")
            }
            append(chapterContent)
        }

        val indentPrefix = "　".repeat(paragraphIndentChars.coerceIn(0, 6))

        return when (writingMode) {
            WritingMode.HORIZONTAL -> paginateHorizontal(
                fullText = fullText,
                hasTitle = hasTitle,
                indentPrefix = indentPrefix,
                widthPx = contentWidthPx,
                heightPx = contentHeightPx,
                paint = textPaint,
                lineSpacingMultiplier = lineSpacingMultiplier,
                paragraphSpacingEm = paragraphSpacingEm
            )
            WritingMode.VERTICAL -> paginateVertical(
                fullText = fullText,
                hasTitle = hasTitle,
                indentPrefix = indentPrefix,
                widthPx = contentWidthPx,
                heightPx = contentHeightPx,
                paint = textPaint,
                lineSpacingMultiplier = lineSpacingMultiplier,
                letterSpacingEm = letterSpacingEm,
                paragraphSpacingEm = paragraphSpacingEm
            )
        }
    }

    private fun paginateHorizontal(
        fullText: String,
        hasTitle: Boolean,
        indentPrefix: String,
        widthPx: Float,
        heightPx: Float,
        paint: Paint,
        lineSpacingMultiplier: Float,
        paragraphSpacingEm: Float
    ): List<PageContent> {
        val fm = paint.fontMetrics
        val singleLineHeight = (fm.descent - fm.ascent).coerceAtLeast(paint.textSize)
        val lineStep = singleLineHeight * lineSpacingMultiplier
        val paraExtraGap = singleLineHeight * paragraphSpacingEm.coerceAtLeast(0f)
        val titleExtraGap = (singleLineHeight * 0.8f).coerceAtLeast(paraExtraGap)

        val allLines = mutableListOf<PageLine>()
        var globalOffset = 0
        val paragraphs = fullText.split("\n")

        for ((pIdx, rawPara) in paragraphs.withIndex()) {
            val trimmed = rawPara.trim { it.isWhitespace() || it == '\u3000' }
            val paraStart = globalOffset
            globalOffset += rawPara.length + 1

            if (trimmed.isEmpty()) continue

            val isTitle = hasTitle && pIdx == 0
            val displayPara = if (isTitle) trimmed else "$indentPrefix$trimmed"

            var localStart = 0
            while (localStart < displayPara.length) {
                var count = paint.breakText(
                    displayPara, localStart, displayPara.length, true, widthPx, null
                ).coerceAtLeast(1)

                // Basic line-start punctuation禁則
                val nextIdx = localStart + count
                if (nextIdx < displayPara.length && displayPara[nextIdx] in VerticalPunctuationHelper.NO_START_CHARS && count > 2) {
                    if (paint.measureText(displayPara, localStart, nextIdx + 1) <= widthPx + paint.textSize * 0.4f) {
                        count += 1
                    } else {
                        count -= 1
                    }
                }

                val slice = displayPara.substring(localStart, (localStart + count).coerceAtMost(displayPara.length))
                val isEnd = (localStart + count) >= displayPara.length
                val approxStart = (paraStart + localStart).coerceAtMost(fullText.length)
                val approxEnd = (paraStart + localStart + slice.length).coerceAtMost(fullText.length)
                allLines.add(PageLine(slice, approxStart, approxEnd, isParagraphEnd = isEnd, isTitleLine = isTitle))
                localStart += count
            }
        }

        if (allLines.isEmpty()) {
            allLines.add(PageLine("（本章無內容）", 0, 0, isParagraphEnd = true))
        }

        // Pack lines into pages respecting exact paragraph spacing
        val pages = mutableListOf<PageContent>()
        var currentLines = mutableListOf<PageLine>()
        var curY = 0f

        fun flushPage(isFull: Boolean) {
            if (currentLines.isEmpty()) return
            val usedHeight = currentLines.last().positionPx + singleLineHeight
            pages.add(
                PageContent(
                    pageIndex = pages.size,
                    startOffset = currentLines.first().startOffset,
                    endOffset = currentLines.last().endOffset,
                    lines = currentLines,
                    isFullPage = isFull,
                    usedSpanPx = usedHeight
                )
            )
            currentLines = mutableListOf()
            curY = 0f
        }

        for (line in allLines) {
            if (currentLines.isNotEmpty() && curY + singleLineHeight > heightPx + 0.5f) {
                flushPage(isFull = true)
            }
            currentLines.add(line.copy(positionPx = curY))
            val extra = when {
                line.isTitleLine && line.isParagraphEnd -> titleExtraGap
                line.isParagraphEnd -> paraExtraGap
                else -> 0f
            }
            curY += lineStep + extra
        }
        flushPage(isFull = false)
        return pages
    }

    private fun paginateVertical(
        fullText: String,
        hasTitle: Boolean,
        indentPrefix: String,
        widthPx: Float,
        heightPx: Float,
        paint: Paint,
        lineSpacingMultiplier: Float,
        letterSpacingEm: Float,
        paragraphSpacingEm: Float
    ): List<PageContent> {
        val textSize = paint.textSize
        val charStepY = textSize * (1.06f + letterSpacingEm.coerceAtLeast(0f))
        val colStepX = textSize * lineSpacingMultiplier
        val paraExtraGap = textSize * paragraphSpacingEm.coerceAtLeast(0f)
        val titleExtraGap = (textSize * 0.8f).coerceAtLeast(paraExtraGap)

        val maxCharsPerCol = floor((heightPx + (charStepY - textSize)) / charStepY)
            .toInt().coerceAtLeast(1)

        val allColumns = mutableListOf<PageLine>()
        var globalOffset = 0
        val paragraphs = fullText.split("\n")

        for ((pIdx, rawPara) in paragraphs.withIndex()) {
            val trimmed = rawPara.trim { it.isWhitespace() || it == '\u3000' }
            val paraStart = globalOffset
            globalOffset += rawPara.length + 1

            if (trimmed.isEmpty()) continue

            val isTitle = hasTitle && pIdx == 0
            val displayPara = if (isTitle) trimmed else "$indentPrefix$trimmed"

            var localStart = 0
            while (localStart < displayPara.length) {
                var count = maxCharsPerCol.coerceAtMost(displayPara.length - localStart)
                val nextIdx = localStart + count
                if (nextIdx < displayPara.length && displayPara[nextIdx] in VerticalPunctuationHelper.NO_START_CHARS) {
                    if (count > 2) {
                        count -= 1
                    }
                }
                val slice = displayPara.substring(localStart, localStart + count)
                val isEnd = (localStart + count) >= displayPara.length
                val approxStart = (paraStart + localStart).coerceAtMost(fullText.length)
                val approxEnd = (paraStart + localStart + slice.length).coerceAtMost(fullText.length)
                allColumns.add(PageLine(slice, approxStart, approxEnd, isParagraphEnd = isEnd, isTitleLine = isTitle))
                localStart += count
            }
        }

        if (allColumns.isEmpty()) {
            allColumns.add(PageLine("（本章無內容）", 0, 0, isParagraphEnd = true))
        }

        // Pack columns into pages from right to left respecting exact paragraph spacing
        val pages = mutableListOf<PageContent>()
        var currentCols = mutableListOf<PageLine>()
        var curX = 0f

        fun flushPage(isFull: Boolean) {
            if (currentCols.isEmpty()) return
            val usedWidth = currentCols.last().positionPx + textSize
            pages.add(
                PageContent(
                    pageIndex = pages.size,
                    startOffset = currentCols.first().startOffset,
                    endOffset = currentCols.last().endOffset,
                    lines = currentCols,
                    isFullPage = isFull,
                    usedSpanPx = usedWidth
                )
            )
            currentCols = mutableListOf()
            curX = 0f
        }

        for (col in allColumns) {
            if (currentCols.isNotEmpty() && curX + textSize > widthPx + 0.5f) {
                flushPage(isFull = true)
            }
            currentCols.add(col.copy(positionPx = curX))
            val extra = when {
                col.isTitleLine && col.isParagraphEnd -> titleExtraGap
                col.isParagraphEnd -> paraExtraGap
                else -> 0f
            }
            curX += colStepX + extra
        }
        flushPage(isFull = false)
        return pages
    }
}
