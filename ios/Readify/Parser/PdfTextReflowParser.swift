import Foundation
import PDFKit
import UIKit

enum PdfTextReflowParser {
    static func parseMetadataAndCover(fileURL: URL, fallbackTitle: String) -> ParsedBook {
        let doc = PDFDocument(url: fileURL)
        let attrs = doc?.documentAttributes
        let rawTitle = (attrs?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawAuthor = (attrs?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let coverBytes = renderFirstPageCover(doc: doc)
        return ParsedBook(
            title: rawTitle.isEmpty ? fallbackTitle : rawTitle,
            author: rawAuthor.isEmpty ? "PDF 文件" : rawAuthor,
            chapters: [],
            coverBytes: coverBytes,
            contentType: .PDF
        )
    }

    static func extractReflowChapters(fileURL: URL, fallbackTitle: String) -> ParsedBook {
        guard let doc = PDFDocument(url: fileURL) else {
            return ParsedBook(
                title: fallbackTitle,
                author: "PDF 文件",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "PDF 文字重排擷取失敗：無法開啟 PDF 檔案。\n請切回原版面閱讀。")],
                contentType: .PDF
            )
        }

        let totalPages = doc.pageCount
        guard totalPages > 0 else {
            return ParsedBook(
                title: fallbackTitle,
                author: "PDF 文件",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "（此 PDF 沒有頁面）")],
                contentType: .PDF
            )
        }

        var chapters: [Chapter] = []
        let pagesPerChunk = 10
        var startP = 0
        while startP < totalPages {
            let endP = min(startP + pagesPerChunk - 1, totalPages - 1)
            var chunkRaw = ""
            for pIdx in startP...endP {
                if let pageText = doc.page(at: pIdx)?.string, !pageText.isEmpty {
                    chunkRaw.append(pageText)
                    chunkRaw.append("\n")
                }
            }
            let cleaned = cleanReflowText(chunkRaw)
            if !cleaned.isEmpty {
                let dispStart = startP + 1
                let dispEnd = endP + 1
                let title = (dispStart == dispEnd) ? "第 \(dispStart) 頁" : "第 \(dispStart) – \(dispEnd) 頁"
                chapters.append(Chapter(index: chapters.count, title: title, content: cleaned))
            }
            startP = endP + 1
        }

        if chapters.isEmpty {
            chapters.append(
                Chapter(
                    index: 0,
                    title: fallbackTitle,
                    content: "此 PDF 偵測不到內嵌文字（可能為純圖片掃描版 PDF）。請切回「原版面」並搭配「自動裁邊」模式閱讀。"
                )
            )
        }

        let attrs = doc.documentAttributes
        let docTitle = (attrs?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let docAuthor = (attrs?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ParsedBook(
            title: docTitle.isEmpty ? fallbackTitle : docTitle,
            author: docAuthor.isEmpty ? "PDF 文件" : docAuthor,
            chapters: chapters,
            contentType: .PDF
        )
    }

    private static func cleanReflowText(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }
        var paragraphs: [String] = []
        var sb = ""
        let sentenceEnders: Set<Character> = ["。", "！", "？", "」", "』", "”", "）", ".", "!", "?", ":", "："]

        for line in lines {
            if sb.isEmpty {
                sb = line
                continue
            }
            let prevLast = sb.last!
            let startsNewIndent = line.hasPrefix("　") || (line.hasPrefix("第") && line.count < 28)
            if sentenceEnders.contains(prevLast) || startsNewIndent {
                paragraphs.append(sb)
                sb = line
            } else {
                let prevAscii = prevLast.unicodeScalars.first.map { $0.value < 128 } ?? false
                let nextAscii = line.unicodeScalars.first.map { $0.value < 128 } ?? false
                if prevAscii && nextAscii {
                    sb.append(" ")
                }
                sb.append(line)
            }
        }
        if !sb.isEmpty {
            paragraphs.append(sb)
        }
        return paragraphs.joined(separator: "\n")
    }

    private static func renderFirstPageCover(doc: PDFDocument?) -> Data? {
        guard let page = doc?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let pw = max(1, bounds.width)
        let ph = max(1, bounds.height)
        let scale = 360.0 / pw
        let targetSize = CGSize(
            width: min(480, max(120, pw * scale)),
            height: min(720, max(160, ph * scale))
        )
        let thumb = page.thumbnail(of: targetSize, for: .mediaBox)
        return thumb.jpegData(compressionQuality: 0.82)
    }
}
