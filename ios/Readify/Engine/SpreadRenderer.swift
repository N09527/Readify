import CoreGraphics
import Foundation
import UIKit

enum SpreadRenderer {
    static func renderSpreadImage(
        size: CGSize,
        scale: CGFloat,
        settings: ReaderSettings,
        bookTitle: String,
        chapterTitle: String,
        firstPage: PageContent?,
        secondPage: PageContent?,
        totalPagesInChapter: Int,
        chapterIndex: Int,
        totalChapters: Int,
        font: UIFont,
        needsSyntheticBold: Bool
    ) -> UIImage? {
        guard size.width > 10 && size.height > 10 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1.0, scale)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            drawSpread(
                ctx: ctx,
                size: size,
                settings: settings,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                firstPage: firstPage,
                secondPage: secondPage,
                totalPagesInChapter: totalPagesInChapter,
                chapterIndex: chapterIndex,
                totalChapters: totalChapters,
                font: font,
                needsSyntheticBold: needsSyntheticBold
            )
        }
    }

    static func drawSpread(
        ctx: CGContext,
        size: CGSize,
        settings: ReaderSettings,
        bookTitle: String,
        chapterTitle: String,
        firstPage: PageContent?,
        secondPage: PageContent?,
        totalPagesInChapter: Int,
        chapterIndex: Int,
        totalChapters: Int,
        font: UIFont,
        needsSyntheticBold: Bool
    ) {
        let theme = settings.effectiveTheme
        ctx.setFillColor(theme.bgUIColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        let metrics = ReaderLayoutMetrics.compute(widthPt: size.width, heightPt: size.height, settings: settings)
        let headerFont = UIFont.systemFont(ofSize: 11.5, weight: .regular)

        if !metrics.isDualPage {
            if let firstPage {
                drawSinglePageContent(
                    ctx: ctx,
                    page: firstPage,
                    rect: metrics.singleRect,
                    settings: settings,
                    font: font,
                    needsSyntheticBold: needsSyntheticBold,
                    textColor: theme.textUIColor
                )
            }
            let pageLabel = firstPage != nil ? "\(firstPage!.pageIndex + 1) / \(totalPagesInChapter)" : ""
            drawHeaderAndFooter(
                size: size,
                marginH: metrics.effectiveMarginH,
                marginV: metrics.effectiveMarginV,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                pageLabel: pageLabel,
                chapterProgress: "\(chapterIndex + 1)/\(totalChapters) 章",
                headerFont: headerFont,
                subTextColor: theme.subTextUIColor,
                isDualPage: false,
                writingMode: settings.writingMode
            )
        } else {
            let centerX = size.width / 2.0
            switch settings.writingMode {
            case .HORIZONTAL:
                if let firstPage {
                    drawSinglePageContent(
                        ctx: ctx, page: firstPage, rect: metrics.leftRect,
                        settings: settings, font: font, needsSyntheticBold: needsSyntheticBold, textColor: theme.textUIColor
                    )
                }
                if let secondPage {
                    drawSinglePageContent(
                        ctx: ctx, page: secondPage, rect: metrics.rightRect,
                        settings: settings, font: font, needsSyntheticBold: needsSyntheticBold, textColor: theme.textUIColor
                    )
                }
            case .VERTICAL:
                if let firstPage {
                    drawSinglePageContent(
                        ctx: ctx, page: firstPage, rect: metrics.rightRect,
                        settings: settings, font: font, needsSyntheticBold: needsSyntheticBold, textColor: theme.textUIColor
                    )
                }
                if let secondPage {
                    drawSinglePageContent(
                        ctx: ctx, page: secondPage, rect: metrics.leftRect,
                        settings: settings, font: font, needsSyntheticBold: needsSyntheticBold, textColor: theme.textUIColor
                    )
                }
            }

            if settings.effectiveSpineShadow {
                drawCenterSpineShadow(ctx: ctx, centerX: centerX, height: size.height, isDark: theme.isDark)
            } else if settings.eInkMode {
                ctx.saveGState()
                ctx.setStrokeColor(UIColor(hex: 0xCCCCCC).cgColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: centerX, y: metrics.effectiveMarginV))
                ctx.addLine(to: CGPoint(x: centerX, y: size.height - metrics.effectiveMarginV))
                ctx.strokePath()
                ctx.restoreGState()
            }

            let pageLabel: String
            if let firstPage, let secondPage {
                pageLabel = "\(firstPage.pageIndex + 1)-\(secondPage.pageIndex + 1) / \(totalPagesInChapter)"
            } else if let firstPage {
                pageLabel = "\(firstPage.pageIndex + 1) / \(totalPagesInChapter)"
            } else {
                pageLabel = ""
            }

            drawHeaderAndFooter(
                size: size,
                marginH: metrics.effectiveMarginH,
                marginV: metrics.effectiveMarginV,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                pageLabel: pageLabel,
                chapterProgress: "\(chapterIndex + 1)/\(totalChapters) 章",
                headerFont: headerFont,
                subTextColor: theme.subTextUIColor,
                isDualPage: true,
                writingMode: settings.writingMode
            )
        }
    }

    private static func drawSinglePageContent(
        ctx: CGContext,
        page: PageContent,
        rect: CGRect,
        settings: ReaderSettings,
        font: UIFont,
        needsSyntheticBold: Bool,
        textColor: UIColor
    ) {
        switch settings.writingMode {
        case .HORIZONTAL:
            drawHorizontalPage(page: page, rect: rect, settings: settings, font: font, needsSyntheticBold: needsSyntheticBold, textColor: textColor)
        case .VERTICAL:
            drawVerticalPage(ctx: ctx, page: page, rect: rect, settings: settings, font: font, needsSyntheticBold: needsSyntheticBold, textColor: textColor)
        }
    }

    private static func drawHorizontalPage(
        page: PageContent,
        rect: CGRect,
        settings: ReaderSettings,
        font: UIFont,
        needsSyntheticBold: Bool,
        textColor: UIColor
    ) {
        let fontSize = font.pointSize
        let singleLineHeight = max(fontSize, font.ascender - font.descender)
        let kernPt = fontSize * CGFloat(max(0, settings.letterSpacingEm))

        var baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        if needsSyntheticBold {
            baseAttrs[.strokeWidth] = -2.8
            baseAttrs[.strokeColor] = textColor
        }

        var lineAttrs = baseAttrs
        if kernPt > 0.001 {
            lineAttrs[.kern] = kernPt
        }

        let extraScaleY: CGFloat = {
            guard page.isFullPage && page.lines.count >= 2 else { return 0 }
            let slackY = max(0, rect.height - page.usedSpanPt)
            if slackY > 0.5 && slackY < singleLineHeight * 1.5 {
                return slackY / CGFloat(page.lines.count - 1)
            }
            return 0
        }()

        var charWidthCache: [Character: CGFloat] = [:]
        func glyphWidth(_ ch: Character) -> CGFloat {
            if let c = charWidthCache[ch] { return c }
            let w = (String(ch) as NSString).size(withAttributes: baseAttrs).width
            charWidthCache[ch] = w
            return w
        }

        for (lineIdx, line) in page.lines.enumerated() {
            let topY = rect.minY + line.positionPt + extraScaleY * CGFloat(lineIdx)
            if topY > rect.maxY + 2 { break }
            if line.text.isEmpty { continue }

            let chars = Array(line.text)
            if !line.isParagraphEnd && !line.isTitleLine && chars.count >= 2 {
                let widths = chars.map { glyphWidth($0) }
                let naturalWidth = widths.reduce(0, +)
                let slackX = rect.width - naturalWidth
                if slackX > 0.5 && slackX < fontSize * 2.8 + kernPt * CGFloat(chars.count) {
                    let extraGap = slackX / CGFloat(chars.count - 1)
                    var drawX = rect.minX
                    for i in 0..<chars.count {
                        let s = String(chars[i]) as NSString
                        s.draw(at: CGPoint(x: drawX, y: topY), withAttributes: baseAttrs)
                        drawX += widths[i] + extraGap
                    }
                    continue
                }
            }

            (line.text as NSString).draw(at: CGPoint(x: rect.minX, y: topY), withAttributes: lineAttrs)
        }
    }

    private static func drawVerticalPage(
        ctx: CGContext,
        page: PageContent,
        rect: CGRect,
        settings: ReaderSettings,
        font: UIFont,
        needsSyntheticBold: Bool,
        textColor: UIColor
    ) {
        let textSize = font.pointSize
        let baseCharStepY = textSize * (1.06 + CGFloat(max(0, settings.letterSpacingEm)))

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        if needsSyntheticBold {
            attrs[.strokeWidth] = -2.8
            attrs[.strokeColor] = textColor
        }

        let extraColGapX: CGFloat = {
            guard page.isFullPage && page.lines.count >= 2 else { return 0 }
            let slackX = max(0, rect.width - page.usedSpanPt)
            if slackX > 0.5 && slackX < textSize * CGFloat(settings.lineSpacingMultiplier) * 1.4 {
                return slackX / CGFloat(page.lines.count - 1)
            }
            return 0
        }()

        var sizeCache: [Character: CGSize] = [:]
        func glyphSize(_ ch: Character) -> CGSize {
            if let s = sizeCache[ch] { return s }
            let sz = (String(ch) as NSString).size(withAttributes: attrs)
            sizeCache[ch] = sz
            return sz
        }

        for (colIdx, col) in page.lines.enumerated() {
            let colRightX = rect.maxX - col.positionPt - extraColGapX * CGFloat(colIdx)
            let colCenterX = colRightX - textSize / 2.0
            if colCenterX < rect.minX - textSize * 0.25 { break }

            let chars = Array(col.text)
            if chars.isEmpty { continue }

            let charStepY: CGFloat = {
                if !col.isParagraphEnd && !col.isTitleLine && chars.count >= 2 {
                    let naturalH = CGFloat(chars.count - 1) * baseCharStepY + textSize
                    let slackY = rect.height - naturalH
                    if slackY > 0.5 && slackY < baseCharStepY * 1.6 {
                        return baseCharStepY + slackY / CGFloat(chars.count - 1)
                    }
                }
                return baseCharStepY
            }()

            var charCenterY = rect.minY + textSize / 2.0
            for rawCh in chars {
                let mappedCh = VerticalPunctuationHelper.mapForVertical(rawCh)
                let nsStr = String(mappedCh) as NSString
                let sz = glyphSize(mappedCh)

                if VerticalPunctuationHelper.shouldRotate90InVertical(rawCh) {
                    ctx.saveGState()
                    ctx.translateBy(x: colCenterX, y: charCenterY)
                    ctx.rotate(by: .pi / 2.0)
                    nsStr.draw(at: CGPoint(x: -sz.width / 2.0, y: -sz.height / 2.0), withAttributes: attrs)
                    ctx.restoreGState()
                } else if VerticalPunctuationHelper.needsTopRightShift(rawCh) {
                    let drawOrigin = CGPoint(
                        x: colCenterX - sz.width / 2.0 + textSize * 0.24,
                        y: charCenterY - sz.height / 2.0 - textSize * 0.22
                    )
                    nsStr.draw(at: drawOrigin, withAttributes: attrs)
                } else {
                    let drawOrigin = CGPoint(
                        x: colCenterX - sz.width / 2.0,
                        y: charCenterY - sz.height / 2.0
                    )
                    nsStr.draw(at: drawOrigin, withAttributes: attrs)
                }

                charCenterY += charStepY
            }
        }
    }

    static func drawCenterSpineShadow(
        ctx: CGContext,
        centerX: CGFloat,
        height: CGFloat,
        isDark: Bool
    ) {
        let leftShadowWidth: CGFloat = 26
        let rightShadowWidth: CGFloat = 18
        let maxDarkAlpha: CGFloat = isDark ? (130.0 / 255.0) : (58.0 / 255.0)
        let midDarkAlpha: CGFloat = isDark ? (45.0 / 255.0) : (20.0 / 255.0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let leftLocations: [CGFloat] = [0.0, 0.72, 1.0]
        ctx.saveGState()
        ctx.clip(to: CGRect(x: centerX - leftShadowWidth, y: 0, width: leftShadowWidth, height: height))
        if let leftGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(midDarkAlpha).cgColor,
                UIColor.black.withAlphaComponent(maxDarkAlpha).cgColor
            ] as CFArray,
            locations: leftLocations
        ) {
            ctx.drawLinearGradient(
                leftGrad,
                start: CGPoint(x: centerX - leftShadowWidth, y: 0),
                end: CGPoint(x: centerX, y: 0),
                options: []
            )
        }
        ctx.restoreGState()

        let rightLocations: [CGFloat] = [0.0, 0.35, 1.0]
        ctx.saveGState()
        ctx.clip(to: CGRect(x: centerX, y: 0, width: rightShadowWidth, height: height))
        if let rightGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                UIColor.black.withAlphaComponent(maxDarkAlpha * 0.85).cgColor,
                UIColor.black.withAlphaComponent(midDarkAlpha).cgColor,
                UIColor.black.withAlphaComponent(0).cgColor
            ] as CFArray,
            locations: rightLocations
        ) {
            ctx.drawLinearGradient(
                rightGrad,
                start: CGPoint(x: centerX, y: 0),
                end: CGPoint(x: centerX + rightShadowWidth, y: 0),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(isDark ? (160.0 / 255.0) : (70.0 / 255.0)).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: centerX, y: 0))
        ctx.addLine(to: CGPoint(x: centerX, y: height))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawHeaderAndFooter(
        size: CGSize,
        marginH: CGFloat,
        marginV: CGFloat,
        bookTitle: String,
        chapterTitle: String,
        pageLabel: String,
        chapterProgress: String,
        headerFont: UIFont,
        subTextColor: UIColor,
        isDualPage: Bool,
        writingMode: WritingMode
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: subTextColor
        ]
        let lineH = headerFont.lineHeight
        let topY = max(6, marginV * 0.45)
        let bottomY = size.height - max(6, marginV * 0.45) - lineH

        let truncTitle = bookTitle.count > 18 ? String(bookTitle.prefix(18)) + "…" : bookTitle
        let truncChapter = chapterTitle.count > 20 ? String(chapterTitle.prefix(20)) + "…" : chapterTitle

        let leftTop = (isDualPage && writingMode == .VERTICAL) ? truncChapter : truncTitle
        let rightTop = (isDualPage && writingMode == .VERTICAL) ? truncTitle : truncChapter

        (leftTop as NSString).draw(at: CGPoint(x: marginH, y: topY), withAttributes: attrs)
        let rightTopW = (rightTop as NSString).size(withAttributes: attrs).width
        (rightTop as NSString).draw(at: CGPoint(x: max(marginH, size.width - marginH - rightTopW), y: topY), withAttributes: attrs)

        (chapterProgress as NSString).draw(at: CGPoint(x: marginH, y: bottomY), withAttributes: attrs)
        let pageLabelW = (pageLabel as NSString).size(withAttributes: attrs).width
        (pageLabel as NSString).draw(at: CGPoint(x: max(marginH, size.width - marginH - pageLabelW), y: bottomY), withAttributes: attrs)
    }
}
