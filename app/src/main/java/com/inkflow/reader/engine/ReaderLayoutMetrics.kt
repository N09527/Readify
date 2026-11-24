package com.inkflow.reader.engine

import android.graphics.RectF
import com.inkflow.reader.model.DualPageMode
import com.inkflow.reader.model.ReaderSettings

data class SpreadLayoutMetrics(
    val isDualPage: Boolean,
    val contentWidthPx: Float,
    val contentHeightPx: Float,
    val singleRect: RectF,
    val leftRect: RectF,
    val rightRect: RectF,
    val effectiveMarginH: Float,
    val effectiveMarginV: Float
)

/**
 * Single source of truth for per-page horizontal & vertical margin calculations.
 *
 * Guarantees:
 * - Single Page: marginH is applied equally to BOTH left and right of the page.
 * - Dual Page:   marginH is applied equally to BOTH left and right of EACH page
 *                (outer edge AND center spine edge of left page & right page).
 * - Vertical:    marginV is applied equally to BOTH top and bottom of every page.
 */
object ReaderLayoutMetrics {

    fun computeDualPage(widthPx: Int, heightPx: Int, density: Float, mode: DualPageMode): Boolean {
        val widthDp = widthPx / density.coerceAtLeast(0.5f)
        return when (mode) {
            DualPageMode.SINGLE -> false
            DualPageMode.DUAL -> true
            DualPageMode.AUTO -> (widthPx > heightPx && widthDp >= 560f) || widthDp >= 720f
        }
    }

    fun compute(
        widthPx: Int,
        heightPx: Int,
        density: Float,
        settings: ReaderSettings
    ): SpreadLayoutMetrics {
        val isDual = computeDualPage(widthPx, heightPx, density, settings.dualPageMode)
        val headerZone = 22f * density
        val footerZone = 20f * density

        val maxMarginV = ((heightPx - headerZone - footerZone) * 0.34f).coerceAtLeast(8f * density)
        val effMarginV = (settings.marginVerticalDp * density).coerceIn(4f * density, maxMarginV)

        val contentTop = effMarginV + headerZone
        val contentBottom = (heightPx - effMarginV - footerZone).coerceAtLeast(contentTop + 80f)
        val contentHeight = (contentBottom - contentTop).coerceAtLeast(80f)

        val pageWidth = if (isDual) widthPx / 2f else widthPx.toFloat()
        val maxMarginH = (pageWidth * 0.34f).coerceAtLeast(8f * density)
        val effMarginH = (settings.marginHorizontalDp * density).coerceIn(4f * density, maxMarginH)

        val contentWidth = (pageWidth - 2f * effMarginH).coerceAtLeast(60f)

        val singleRect = RectF(
            effMarginH,
            contentTop,
            widthPx - effMarginH,
            contentBottom
        )

        val centerX = widthPx / 2f
        val leftRect = RectF(
            effMarginH,
            contentTop,
            centerX - effMarginH,
            contentBottom
        )
        val rightRect = RectF(
            centerX + effMarginH,
            contentTop,
            widthPx - effMarginH,
            contentBottom
        )

        return SpreadLayoutMetrics(
            isDualPage = isDual,
            contentWidthPx = contentWidth,
            contentHeightPx = contentHeight,
            singleRect = singleRect,
            leftRect = leftRect,
            rightRect = rightRect,
            effectiveMarginH = effMarginH,
            effectiveMarginV = effMarginV
        )
    }
}
