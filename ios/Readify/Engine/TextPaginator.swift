import CoreGraphics
import Foundation
import UIKit

struct PageLine: Equatable {
    var text: String
    var startOffset: Int
    var endOffset: Int
    var isParagraphEnd: Bool = false
    var isTitleLine: Bool = false
    // Horizontal mode: Y distance from rect.minY to line top
    // Vertical mode:   X distance from rect.maxX to column right edge
    var positionPt: CGFloat = 0
}

struct PageContent: Equatable {
    var pageIndex: Int
    var startOffset: Int
    var endOffset: Int
    var lines: [PageLine]
    var isFullPage: Bool = false
    var usedSpanPt: CGFloat = 0
}

enum TextPaginator {
    static func paginate(
        chapterTitle: String,
        chapterContent: String,
        writingMode: WritingMode,
        contentWidthPt: CGFloat,
        contentHeightPt: CGFloat,
        font: UIFont,
        needsSyntheticBold: Bool,
        lineSpacingMultiplier: CGFloat,
        letterSpacingEm: CGFloat,
        paragraphSpacingEm: CGFloat,
        paragraphIndentChars: Int
    ) -> [PageContent] {
        guard contentWidthPt > 20 && contentHeightPt > 20 else { return [] }

        let trimmedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = !trimmedTitle.isEmpty
        let fullText = hasTitle ? "\(trimmedTitle)\n\(chapterContent)" : chapterContent

        let clampedIndent = min(6, max(0, paragraphIndentChars))
        let indentPrefix = String(repeating: "　", count: clampedIndent)

        switch writingMode {
        case .HORIZONTAL:
            return paginateHorizontal(
                fullText: fullText,
                hasTitle: hasTitle,
                indentPrefix: indentPrefix,
                widthPt: contentWidthPt,
                heightPt: contentHeightPt,
                font: font,
                needsSyntheticBold: needsSyntheticBold,
                letterSpacingEm: letterSpacingEm,
                lineSpacingMultiplier: lineSpacingMultiplier,
                paragraphSpacingEm: paragraphSpacingEm
            )
        case .VERTICAL:
            return paginateVertical(
                fullText: fullText,
                hasTitle: hasTitle,
                indentPrefix: indentPrefix,
                widthPt: contentWidthPt,
                heightPt: contentHeightPt,
                font: font,
                lineSpacingMultiplier: lineSpacingMultiplier,
                letterSpacingEm: letterSpacingEm,
                paragraphSpacingEm: paragraphSpacingEm
            )
        }
    }

    private static func paginateHorizontal(
        fullText: String,
        hasTitle: Bool,
        indentPrefix: String,
        widthPt: CGFloat,
        heightPt: CGFloat,
        font: UIFont,
        needsSyntheticBold: Bool,
        letterSpacingEm: CGFloat,
        lineSpacingMultiplier: CGFloat,
        paragraphSpacingEm: CGFloat
    ) -> [PageContent] {
        let fontSize = font.pointSize
        let singleLineHeight = max(fontSize, font.ascender - font.descender)
        let lineStep = singleLineHeight * lineSpacingMultiplier
        let paraExtraGap = singleLineHeight * max(0, paragraphSpacingEm)
        let titleExtraGap = max(paraExtraGap, singleLineHeight * 0.8)
        let kernPt = fontSize * max(0, letterSpacingEm)

        var measureAttrs: [NSAttributedString.Key: Any] = [.font: font]
        if kernPt > 0.001 {
            measureAttrs[.kern] = kernPt
        }
        if needsSyntheticBold {
            measureAttrs[.strokeWidth] = -2.8
        }

        // Cache single-character widths for O(N) CJK + ASCII line breaking
        var charWidthCache: [Character: CGFloat] = [:]
        func charAdvance(_ ch: Character) -> CGFloat {
            if let cached = charWidthCache[ch] { return cached }
            let w = (String(ch) as NSString).size(withAttributes: measureAttrs).width
            charWidthCache[ch] = w
            return w
        }

        let totalCharsCount = fullText.count
        var allLines: [PageLine] = []
        var globalOffset = 0
        let paragraphs = fullText.components(separatedBy: "\n")
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}"))

        for (pIdx, rawPara) in paragraphs.enumerated() {
            let paraCharLen = rawPara.count
            let paraStart = globalOffset
            globalOffset += paraCharLen + 1

            let trimmed = rawPara.trimmingCharacters(in: trimSet)
            if trimmed.isEmpty { continue }

            let isTitle = hasTitle && pIdx == 0
            let displayPara = isTitle ? trimmed : "\(indentPrefix)\(trimmed)"
            let chars = Array(displayPara)
            let n = chars.count

            var localStart = 0
            while localStart < n {
                var accWidth: CGFloat = 0
                var count = 0
                while localStart + count < n {
                    let ch = chars[localStart + count]
                    let w = charAdvance(ch)
                    if count > 0 && accWidth + w > widthPt + 0.2 {
                        break
                    }
                    accWidth += w
                    count += 1
                }
                count = max(1, count)

                // Line-start punctuation kinsoku (行頭禁則)
                let nextIdx = localStart + count
                if nextIdx < n && VerticalPunctuationHelper.noStartChars.contains(chars[nextIdx]) && count > 2 {
                    let nextW = charAdvance(chars[nextIdx])
                    if accWidth + nextW <= widthPt + fontSize * 0.42 {
                        count += 1
                    } else {
                        count -= 1
                    }
                }

                let endIdx = min(n, localStart + count)
                let slice = String(chars[localStart..<endIdx])
                let isEnd = endIdx >= n
                let approxStart = min(totalCharsCount, paraStart + localStart)
                let approxEnd = min(totalCharsCount, paraStart + endIdx)
                allLines.append(
                    PageLine(
                        text: slice,
                        startOffset: approxStart,
                        endOffset: approxEnd,
                        isParagraphEnd: isEnd,
                        isTitleLine: isTitle
                    )
                )
                localStart = endIdx
            }
        }

        if allLines.isEmpty {
            allLines.append(PageLine(text: "（本章無內容）", startOffset: 0, endOffset: 0, isParagraphEnd: true))
        }

        var pages: [PageContent] = []
        var currentLines: [PageLine] = []
        var curY: CGFloat = 0

        func flushPage(isFull: Bool) {
            guard let first = currentLines.first, let last = currentLines.last else { return }
            let usedHeight = last.positionPt + singleLineHeight
            pages.append(
                PageContent(
                    pageIndex: pages.count,
                    startOffset: first.startOffset,
                    endOffset: last.endOffset,
                    lines: currentLines,
                    isFullPage: isFull,
                    usedSpanPt: usedHeight
                )
            )
            currentLines.removeAll(keepingCapacity: true)
            curY = 0
        }

        for line in allLines {
            if !currentLines.isEmpty && curY + singleLineHeight > heightPt + 0.5 {
                flushPage(isFull: true)
            }
            var positioned = line
            positioned.positionPt = curY
            currentLines.append(positioned)

            let extra: CGFloat
            if line.isTitleLine && line.isParagraphEnd {
                extra = titleExtraGap
            } else if line.isParagraphEnd {
                extra = paraExtraGap
            } else {
                extra = 0
            }
            curY += lineStep + extra
        }
        flushPage(isFull: false)
        return pages
    }

    private static func paginateVertical(
        fullText: String,
        hasTitle: Bool,
        indentPrefix: String,
        widthPt: CGFloat,
        heightPt: CGFloat,
        font: UIFont,
        lineSpacingMultiplier: CGFloat,
        letterSpacingEm: CGFloat,
        paragraphSpacingEm: CGFloat
    ) -> [PageContent] {
        let textSize = font.pointSize
        let charStepY = textSize * (1.06 + max(0, letterSpacingEm))
        let colStepX = textSize * lineSpacingMultiplier
        let paraExtraGap = textSize * max(0, paragraphSpacingEm)
        let titleExtraGap = max(paraExtraGap, textSize * 0.8)

        let maxCharsPerCol = max(1, Int(floor((heightPt + (charStepY - textSize)) / charStepY)))

        let totalCharsCount = fullText.count
        var allColumns: [PageLine] = []
        var globalOffset = 0
        let paragraphs = fullText.components(separatedBy: "\n")
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}"))

        for (pIdx, rawPara) in paragraphs.enumerated() {
            let paraCharLen = rawPara.count
            let paraStart = globalOffset
            globalOffset += paraCharLen + 1

            let trimmed = rawPara.trimmingCharacters(in: trimSet)
            if trimmed.isEmpty { continue }

            let isTitle = hasTitle && pIdx == 0
            let displayPara = isTitle ? trimmed : "\(indentPrefix)\(trimmed)"
            let chars = Array(displayPara)
            let n = chars.count

            var localStart = 0
            while localStart < n {
                var count = min(maxCharsPerCol, n - localStart)
                let nextIdx = localStart + count
                if nextIdx < n && VerticalPunctuationHelper.noStartChars.contains(chars[nextIdx]) && count > 2 {
                    count -= 1
                }
                let endIdx = min(n, localStart + count)
                let slice = String(chars[localStart..<endIdx])
                let isEnd = endIdx >= n
                let approxStart = min(totalCharsCount, paraStart + localStart)
                let approxEnd = min(totalCharsCount, paraStart + endIdx)
                allColumns.append(
                    PageLine(
                        text: slice,
                        startOffset: approxStart,
                        endOffset: approxEnd,
                        isParagraphEnd: isEnd,
                        isTitleLine: isTitle
                    )
                )
                localStart = endIdx
            }
        }

        if allColumns.isEmpty {
            allColumns.append(PageLine(text: "（本章無內容）", startOffset: 0, endOffset: 0, isParagraphEnd: true))
        }

        var pages: [PageContent] = []
        var currentCols: [PageLine] = []
        var curX: CGFloat = 0

        func flushPage(isFull: Bool) {
            guard let first = currentCols.first, let last = currentCols.last else { return }
            let usedWidth = last.positionPt + textSize
            pages.append(
                PageContent(
                    pageIndex: pages.count,
                    startOffset: first.startOffset,
                    endOffset: last.endOffset,
                    lines: currentCols,
                    isFullPage: isFull,
                    usedSpanPt: usedWidth
                )
            )
            currentCols.removeAll(keepingCapacity: true)
            curX = 0
        }

        for col in allColumns {
            if !currentCols.isEmpty && curX + textSize > widthPt + 0.5 {
                flushPage(isFull: true)
            }
            var positioned = col
            positioned.positionPt = curX
            currentCols.append(positioned)

            let extra: CGFloat
            if col.isTitleLine && col.isParagraphEnd {
                extra = titleExtraGap
            } else if col.isParagraphEnd {
                extra = paraExtraGap
            } else {
                extra = 0
            }
            curX += colStepX + extra
        }
        flushPage(isFull: false)
        return pages
    }
}
