import CoreGraphics
import Foundation

struct SpreadLayoutMetrics: Equatable {
    var isDualPage: Bool
    var contentWidthPt: CGFloat
    var contentHeightPt: CGFloat
    var singleRect: CGRect
    var leftRect: CGRect
    var rightRect: CGRect
    var effectiveMarginH: CGFloat
    var effectiveMarginV: CGFloat
}

enum ReaderLayoutMetrics {
    static func computeDualPage(widthPt: CGFloat, heightPt: CGFloat, mode: DualPageMode) -> Bool {
        switch mode {
        case .SINGLE:
            return false
        case .DUAL:
            return true
        case .AUTO:
            return (widthPt > heightPt && widthPt >= 560) || widthPt >= 720
        }
    }

    static func compute(
        widthPt: CGFloat,
        heightPt: CGFloat,
        settings: ReaderSettings
    ) -> SpreadLayoutMetrics {
        let isDual = computeDualPage(widthPt: widthPt, heightPt: heightPt, mode: settings.dualPageMode)
        let headerZone: CGFloat = 22
        let footerZone: CGFloat = 20

        let maxMarginV = max(8, (heightPt - headerZone - footerZone) * 0.34)
        let effMarginV = min(maxMarginV, max(4, CGFloat(settings.marginVerticalDp)))

        let contentTop = effMarginV + headerZone
        let contentBottom = max(contentTop + 80, heightPt - effMarginV - footerZone)
        let contentHeight = max(80, contentBottom - contentTop)

        let pageWidth = isDual ? (widthPt / 2.0) : widthPt
        let maxMarginH = max(8, pageWidth * 0.34)
        let effMarginH = min(maxMarginH, max(4, CGFloat(settings.marginHorizontalDp)))

        let contentWidth = max(60, pageWidth - 2.0 * effMarginH)

        let singleRect = CGRect(
            x: effMarginH,
            y: contentTop,
            width: max(60, widthPt - 2.0 * effMarginH),
            height: contentHeight
        )

        let centerX = widthPt / 2.0
        let leftRect = CGRect(
            x: effMarginH,
            y: contentTop,
            width: max(60, centerX - 2.0 * effMarginH),
            height: contentHeight
        )
        let rightRect = CGRect(
            x: centerX + effMarginH,
            y: contentTop,
            width: max(60, centerX - 2.0 * effMarginH),
            height: contentHeight
        )

        return SpreadLayoutMetrics(
            isDualPage: isDual,
            contentWidthPt: contentWidth,
            contentHeightPt: contentHeight,
            singleRect: singleRect,
            leftRect: leftRect,
            rightRect: rightRect,
            effectiveMarginH: effMarginH,
            effectiveMarginV: effMarginV
        )
    }
}
