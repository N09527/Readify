package com.inkflow.reader.engine

import android.graphics.*
import com.inkflow.reader.model.ReaderSettings
import com.inkflow.reader.model.WritingMode

/**
 * Draws a single page OR a true left-right dual-page spread onto a Canvas.
 *
 * Design guarantees:
 *  - Horizontal Dual Page: Left = Page N, Right = Page N+1
 *  - Vertical Dual Page:   Right = Page N, Left = Page N+1
 *  - Symmetric Per-Page Margins: Left/right padding and top/bottom padding apply equally to EACH page.
 *  - Crisp book alignment: Full justification on horizontal lines & flush edge distribution on vertical columns.
 */
object SpreadRenderer {

    fun drawSpread(
        canvas: Canvas,
        width: Int,
        height: Int,
        density: Float,
        settings: ReaderSettings,
        bookTitle: String,
        chapterTitle: String,
        firstPage: PageContent?,
        secondPage: PageContent?,
        totalPagesInChapter: Int,
        chapterIndex: Int,
        totalChapters: Int,
        textPaint: Paint,
        headerPaint: Paint
    ) {
        val theme = settings.effectiveTheme
        canvas.drawColor(theme.bgColor)

        val metrics = ReaderLayoutMetrics.compute(width, height, density, settings)

        if (!metrics.isDualPage) {
            firstPage?.let {
                drawSinglePageContent(canvas, it, metrics.singleRect, settings, textPaint)
            }
            drawHeaderAndFooter(
                canvas = canvas,
                width = width.toFloat(),
                height = height.toFloat(),
                density = density,
                marginH = metrics.effectiveMarginH,
                marginV = metrics.effectiveMarginV,
                bookTitle = bookTitle,
                chapterTitle = chapterTitle,
                pageLabel = if (firstPage != null) "${firstPage.pageIndex + 1} / $totalPagesInChapter" else "",
                chapterProgress = "${chapterIndex + 1}/$totalChapters 章",
                headerPaint = headerPaint,
                isDualPage = false,
                writingMode = settings.writingMode
            )
        } else {
            val centerX = width / 2f

            when (settings.writingMode) {
                WritingMode.HORIZONTAL -> {
                    firstPage?.let { drawSinglePageContent(canvas, it, metrics.leftRect, settings, textPaint) }
                    secondPage?.let { drawSinglePageContent(canvas, it, metrics.rightRect, settings, textPaint) }
                }
                WritingMode.VERTICAL -> {
                    firstPage?.let { drawSinglePageContent(canvas, it, metrics.rightRect, settings, textPaint) }
                    secondPage?.let { drawSinglePageContent(canvas, it, metrics.leftRect, settings, textPaint) }
                }
            }

            if (settings.effectiveSpineShadow) {
                drawCenterSpineShadow(canvas, centerX, height.toFloat(), density, theme.bgColor)
            } else if (settings.eInkMode) {
                val dividerPaint = Paint().apply {
                    color = Color.parseColor("#CCCCCC")
                    strokeWidth = 1f * density
                }
                canvas.drawLine(centerX, metrics.effectiveMarginV, centerX, height - metrics.effectiveMarginV, dividerPaint)
            }

            val pageLabel = when {
                firstPage != null && secondPage != null ->
                    "${firstPage.pageIndex + 1}-${secondPage.pageIndex + 1} / $totalPagesInChapter"
                firstPage != null ->
                    "${firstPage.pageIndex + 1} / $totalPagesInChapter"
                else -> ""
            }
            drawHeaderAndFooter(
                canvas = canvas,
                width = width.toFloat(),
                height = height.toFloat(),
                density = density,
                marginH = metrics.effectiveMarginH,
                marginV = metrics.effectiveMarginV,
                bookTitle = bookTitle,
                chapterTitle = chapterTitle,
                pageLabel = pageLabel,
                chapterProgress = "${chapterIndex + 1}/$totalChapters 章",
                headerPaint = headerPaint,
                isDualPage = true,
                writingMode = settings.writingMode
            )
        }
    }

    private fun drawSinglePageContent(
        canvas: Canvas,
        page: PageContent,
        rect: RectF,
        settings: ReaderSettings,
        paint: Paint
    ) {
        when (settings.writingMode) {
            WritingMode.HORIZONTAL -> drawHorizontalPage(canvas, page, rect, paint)
            WritingMode.VERTICAL -> drawVerticalPage(canvas, page, rect, settings, paint)
        }
    }

    private fun drawHorizontalPage(
        canvas: Canvas,
        page: PageContent,
        rect: RectF,
        paint: Paint
    ) {
        val fm = paint.fontMetrics
        val singleLineHeight = (fm.descent - fm.ascent).coerceAtLeast(paint.textSize)

        // Symmetrically distribute minor vertical slack on full pages so top & bottom margins stay flush
        val extraScaleY = if (page.isFullPage && page.lines.size >= 2) {
            val slackY = (rect.height() - page.usedSpanPx).coerceAtLeast(0f)
            if (slackY > 0.5f && slackY < singleLineHeight * 1.5f) {
                slackY / (page.lines.size - 1)
            } else 0f
        } else 0f

        for ((lineIdx, line) in page.lines.withIndex()) {
            val topY = rect.top + line.positionPx + extraScaleY * lineIdx
            val baselineY = topY - fm.ascent
            if (topY > rect.bottom + 2f) break
            if (line.text.isEmpty()) continue

            val text = line.text
            if (!line.isParagraphEnd && !line.isTitleLine && text.length >= 2) {
                // Full-justify non-ending lines so BOTH left and right margins are razor-sharp
                val widths = FloatArray(text.length)
                paint.getTextWidths(text, widths)
                val naturalWidth = widths.sum()
                val slackX = rect.width() - naturalWidth
                if (slackX > 0.5f && slackX < paint.textSize * 2.8f) {
                    val extraGap = slackX / (text.length - 1)
                    var drawX = rect.left
                    for (i in text.indices) {
                        canvas.drawText(text, i, i + 1, drawX, baselineY, paint)
                        drawX += widths[i] + extraGap
                    }
                    continue
                }
            }
            canvas.drawText(text, rect.left, baselineY, paint)
        }
    }

    private fun drawVerticalPage(
        canvas: Canvas,
        page: PageContent,
        rect: RectF,
        settings: ReaderSettings,
        paint: Paint
    ) {
        val textSize = paint.textSize
        val baseCharStepY = textSize * (1.06f + settings.letterSpacingEm.coerceAtLeast(0f))
        val fm = paint.fontMetrics
        val charCenterOffsetY = -(fm.ascent + fm.descent) / 2f

        val originalAlign = paint.textAlign
        val originalLetterSpacing = paint.letterSpacing
        paint.textAlign = Paint.Align.CENTER
        // Disable horizontal letterSpacing while drawing single centered vertical glyphs
        paint.letterSpacing = 0f

        // Distribute minor horizontal slack across columns on full pages so BOTH right and left margins align flush
        val extraColGapX = if (page.isFullPage && page.lines.size >= 2) {
            val slackX = (rect.width() - page.usedSpanPx).coerceAtLeast(0f)
            if (slackX > 0.5f && slackX < textSize * settings.lineSpacingMultiplier * 1.4f) {
                slackX / (page.lines.size - 1)
            } else 0f
        } else 0f

        for ((colIdx, col) in page.lines.withIndex()) {
            val colRightX = rect.right - col.positionPx - extraColGapX * colIdx
            val colCenterX = colRightX - textSize / 2f
            if (colCenterX < rect.left - textSize * 0.25f) break

            val text = col.text
            if (text.isEmpty()) continue

            // Flush vertical top & bottom margin alignment on full non-paragraph-end columns
            val charStepY = if (!col.isParagraphEnd && !col.isTitleLine && text.length >= 2) {
                val naturalH = (text.length - 1) * baseCharStepY + textSize
                val slackY = rect.height() - naturalH
                if (slackY > 0.5f && slackY < baseCharStepY * 1.6f) {
                    baseCharStepY + slackY / (text.length - 1)
                } else baseCharStepY
            } else {
                baseCharStepY
            }

            var charCenterY = rect.top + textSize / 2f
            for (rawCh in text) {
                val ch = VerticalPunctuationHelper.mapForVertical(rawCh)
                val chStr = ch.toString()

                if (VerticalPunctuationHelper.shouldRotate90InVertical(rawCh)) {
                    canvas.save()
                    canvas.rotate(90f, colCenterX, charCenterY)
                    canvas.drawText(chStr, colCenterX, charCenterY + charCenterOffsetY, paint)
                    canvas.restore()
                } else if (VerticalPunctuationHelper.needsTopRightShift(rawCh)) {
                    canvas.drawText(
                        chStr,
                        colCenterX + textSize * 0.24f,
                        charCenterY + charCenterOffsetY - textSize * 0.22f,
                        paint
                    )
                } else {
                    canvas.drawText(chStr, colCenterX, charCenterY + charCenterOffsetY, paint)
                }

                charCenterY += charStepY
            }
        }

        paint.textAlign = originalAlign
        paint.letterSpacing = originalLetterSpacing
    }

    private fun drawCenterSpineShadow(
        canvas: Canvas,
        centerX: Float,
        height: Float,
        density: Float,
        bgColor: Int
    ) {
        val isDark = Color.luminance(bgColor) < 0.25f
        val leftShadowWidth = 26f * density
        val rightShadowWidth = 18f * density

        val maxDarkAlpha = if (isDark) 130 else 58
        val midDarkAlpha = if (isDark) 45 else 20

        val leftPaint = Paint().apply {
            shader = LinearGradient(
                centerX - leftShadowWidth, 0f,
                centerX, 0f,
                intArrayOf(
                    Color.argb(0, 0, 0, 0),
                    Color.argb(midDarkAlpha, 0, 0, 0),
                    Color.argb(maxDarkAlpha, 0, 0, 0)
                ),
                floatArrayOf(0f, 0.72f, 1f),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(centerX - leftShadowWidth, 0f, centerX, height, leftPaint)

        val rightPaint = Paint().apply {
            shader = LinearGradient(
                centerX, 0f,
                centerX + rightShadowWidth, 0f,
                intArrayOf(
                    Color.argb((maxDarkAlpha * 0.85f).toInt(), 0, 0, 0),
                    Color.argb(midDarkAlpha, 0, 0, 0),
                    Color.argb(0, 0, 0, 0)
                ),
                floatArrayOf(0f, 0.35f, 1f),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(centerX, 0f, centerX + rightShadowWidth, height, rightPaint)

        val creaseLine = Paint().apply {
            color = Color.argb(if (isDark) 160 else 70, 0, 0, 0)
            strokeWidth = 1f * density
        }
        canvas.drawLine(centerX, 0f, centerX, height, creaseLine)
    }

    private fun drawHeaderAndFooter(
        canvas: Canvas,
        width: Float,
        height: Float,
        density: Float,
        marginH: Float,
        marginV: Float,
        bookTitle: String,
        chapterTitle: String,
        pageLabel: String,
        chapterProgress: String,
        headerPaint: Paint,
        isDualPage: Boolean,
        writingMode: WritingMode
    ) {
        val topY = (marginV * 0.55f).coerceAtLeast(8f * density) + headerPaint.textSize
        val bottomY = height - (marginV * 0.45f).coerceAtLeast(8f * density)

        val truncatedTitle = if (bookTitle.length > 18) bookTitle.take(18) + "…" else bookTitle
        val truncatedChapter = if (chapterTitle.length > 20) chapterTitle.take(20) + "…" else chapterTitle

        headerPaint.textAlign = Paint.Align.LEFT
        if (isDualPage && writingMode == WritingMode.VERTICAL) {
            canvas.drawText(truncatedChapter, marginH, topY, headerPaint)
            headerPaint.textAlign = Paint.Align.RIGHT
            canvas.drawText(truncatedTitle, width - marginH, topY, headerPaint)
        } else {
            canvas.drawText(truncatedTitle, marginH, topY, headerPaint)
            headerPaint.textAlign = Paint.Align.RIGHT
            canvas.drawText(truncatedChapter, width - marginH, topY, headerPaint)
        }

        headerPaint.textAlign = Paint.Align.LEFT
        canvas.drawText(chapterProgress, marginH, bottomY, headerPaint)
        headerPaint.textAlign = Paint.Align.RIGHT
        canvas.drawText(pageLabel, width - marginH, bottomY, headerPaint)
    }
}
