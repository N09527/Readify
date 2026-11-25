import CoreFoundation
import Foundation
import SwiftSoup
import ZIPFoundation

struct EpubComicInfo {
    var isComic: Bool
    var imagePaths: [String]
    var isRtl: Bool
    var title: String
    var author: String
    var coverBytes: Data?
}

enum BookParser {
    private static let chapterRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[\\s\\u3000]*((第[零〇一二三四五六七八九十百千萬两兩0-9]{1,7}[章回節节卷部集篇幕].*)|((Chapter|CHAPTER|Part|PART)\\s+[0-9IVXLC]+.*)|(序章|楔子|前言|後記|后记|尾聲|尾声|番外).*)$",
        options: []
    )

    private static let selfClosingRawTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<(script|style|title|textarea)(\\b[^>]*?)/>",
        options: [.caseInsensitive]
    )

    private static let skipTags: Set<String> = ["script", "style", "noscript", "head", "title", "rp", "rt"]

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "aside", "header", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "ul", "ol", "dl", "dt", "dd",
        "blockquote", "pre", "figure", "figcaption",
        "table", "tr", "hr", "address"
    ]

    static func parseMetadataAndCover(fileURL: URL, format: BookFormat, fallbackTitle: String) -> ParsedBook {
        switch format {
        case .TXT:
            return ParsedBook(
                title: fallbackTitle,
                author: "本機 TXT",
                chapters: [],
                coverBytes: nil,
                contentType: .TEXT
            )
        case .EPUB:
            let comicInfo = inspectEpubComic(fileURL: fileURL, fallbackTitle: fallbackTitle)
            return ParsedBook(
                title: comicInfo.title,
                author: comicInfo.author,
                chapters: [],
                coverBytes: comicInfo.coverBytes,
                contentType: comicInfo.isComic ? .COMIC : .TEXT
            )
        case .PDF:
            return PdfTextReflowParser.parseMetadataAndCover(fileURL: fileURL, fallbackTitle: fallbackTitle)
        case .CBZ, .ZIP:
            let cover = VisualBookSourceFactory.extractZipComicCover(fileURL: fileURL)
            return ParsedBook(
                title: fallbackTitle,
                author: "\(format.label) 漫畫",
                chapters: [],
                coverBytes: cover,
                contentType: .COMIC
            )
        case .CBR:
            let cover = VisualBookSourceFactory.extractRarComicCover(fileURL: fileURL)
            return ParsedBook(
                title: fallbackTitle,
                author: "CBR 漫畫",
                chapters: [],
                coverBytes: cover,
                contentType: .COMIC
            )
        case .MOBI, .AZW3:
            return MobiAzw3Parser.parseMetadataAndCover(fileURL: fileURL, fallbackTitle: fallbackTitle)
        }
    }

    static func parseFullBook(fileURL: URL, format: BookFormat, fallbackTitle: String) -> ParsedBook {
        switch format {
        case .TXT:
            return parseTxt(fileURL: fileURL, fallbackTitle: fallbackTitle)
        case .EPUB:
            return parseEpub(fileURL: fileURL, fallbackTitle: fallbackTitle)
        case .PDF:
            return PdfTextReflowParser.extractReflowChapters(fileURL: fileURL, fallbackTitle: fallbackTitle)
        case .MOBI, .AZW3:
            return MobiAzw3Parser.parseFullBook(fileURL: fileURL, fallbackTitle: fallbackTitle)
        case .CBZ, .CBR, .ZIP:
            return ParsedBook(
                title: fallbackTitle,
                author: "漫畫壓縮檔",
                chapters: [],
                contentType: .COMIC
            )
        }
    }

    private static func parseTxt(fileURL: URL, fallbackTitle: String) -> ParsedBook {
        let rawData = (try? Data(contentsOf: fileURL)) ?? Data()
        let text = decodeBytesSmart(rawData)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let chapters = splitPlainTextIntoChapters(text: text, fallbackTitle: fallbackTitle)
        return ParsedBook(
            title: fallbackTitle,
            author: "本機 TXT",
            chapters: chapters,
            contentType: .TEXT
        )
    }

    static func splitPlainTextIntoChapters(text: String, fallbackTitle: String) -> [Chapter] {
        let lines = text.components(separatedBy: "\n")
        var chapters: [Chapter] = []
        var currentTitle = "開始閱讀"
        var buffer: [String] = []

        func flushChapter() {
            let content = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                chapters.append(Chapter(index: chapters.count, title: currentTitle, content: content))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = trimmed.count
            if count >= 2 && count <= 45 && matchesChapterHeading(trimmed) {
                if !buffer.isEmpty {
                    flushChapter()
                }
                currentTitle = trimmed
            } else if !trimmed.isEmpty {
                buffer.append(trimmed)
            }
        }
        flushChapter()

        if chapters.count <= 1 {
            let fullText = chapters.first?.content ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
            let utf16Len = fullText.utf16.count
            if utf16Len > 12000 {
                chapters.removeAll()
                let chars = Array(fullText)
                let chunkSize = 8000
                var start = 0
                var partIdx = 1
                while start < chars.count {
                    var end = min(start + chunkSize, chars.count)
                    if end < chars.count {
                        let searchLimit = min(end + 400, chars.count)
                        if let nlIdx = chars[end..<searchLimit].firstIndex(of: "\n") {
                            end = nlIdx + 1
                        }
                    }
                    let slice = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !slice.isEmpty {
                        chapters.append(Chapter(index: chapters.count, title: "第 \(partIdx) 節", content: slice))
                    }
                    start = end
                    partIdx += 1
                }
            } else if chapters.isEmpty {
                let safe = fullText.isEmpty ? "（空白檔案）" : fullText
                chapters.append(Chapter(index: 0, title: fallbackTitle, content: safe))
            }
        }
        return chapters
    }

    private static func matchesChapterHeading(_ line: String) -> Bool {
        guard let regex = chapterRegex else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }

    static func decodeBytesSmart(_ data: Data) -> String {
        if data.isEmpty { return "" }
        let bytes = [UInt8](data)

        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            if let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return s
            }
        }
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            if let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return s
            }
        }

        // Strict UTF-8 check
        if let utf8Str = String(data: data, encoding: .utf8) {
            return utf8Str
        }

        let big5Hkscs = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))
        )
        let big5 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        )
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )

        var bestCandidate: String?
        var bestScore: Double = -Double.infinity
        for enc in [big5Hkscs, big5, gb18030, .shiftJIS, .windowsCP1252] {
            if let decoded = String(data: data, encoding: enc) {
                let score = scoreDecodedTextQuality(decoded)
                if score > bestScore {
                    bestScore = score
                    bestCandidate = decoded
                }
            }
        }
        return bestCandidate ?? String(decoding: data, as: UTF8.self)
    }

    private static func scoreDecodedTextQuality(_ text: String) -> Double {
        var goodCount = 0
        var suspiciousCount = 0
        var sampleCount = 0
        for scalar in text.unicodeScalars {
            if sampleCount >= 6000 { break }
            sampleCount += 1
            let v = scalar.value
            if (v >= 0x4E00 && v <= 0x9FFF) || // Common CJK Unified Ideographs
               (v >= 0x3000 && v <= 0x303F) || // CJK Punctuation
               (v >= 0xFF00 && v <= 0xFFEF) || // Fullwidth forms
               (v >= 0x20 && v <= 0x7E) ||
               v == 0x0A || v == 0x0D || v == 0x09 {
                goodCount += 1
            } else if v == 0xFFFD || (v >= 0xE000 && v <= 0xF8FF) || (v < 0x20) {
                suspiciousCount += 4
            } else {
                suspiciousCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }
        return Double(goodCount - suspiciousCount) / Double(sampleCount)
    }

    // MARK: - EPUB Comic & Text Parsing

    static func inspectEpubComic(fileURL: URL, fallbackTitle: String) -> EpubComicInfo {
        guard let archive = try? Archive(url: fileURL, accessMode: .read) else {
            return EpubComicInfo(isComic: false, imagePaths: [], isRtl: true, title: fallbackTitle, author: "未知作者", coverBytes: nil)
        }

        let entryIndex = buildZipEntryIndex(archive)
        guard let containerEntry = findZipEntry(entryIndex, path: "META-INF/container.xml"),
              let containerXml = readEntryText(archive, entry: containerEntry),
              let containerDoc = try? SwiftSoup.parse(containerXml, "", Parser.xmlParser()),
              let rootfileEl = try? containerDoc.select("rootfile, *|rootfile").first(),
              let opfPathRaw = try? rootfileEl.attr("full-path"),
              !opfPathRaw.isEmpty else {
            return EpubComicInfo(isComic: false, imagePaths: [], isRtl: true, title: fallbackTitle, author: "未知作者", coverBytes: nil)
        }

        let opfPath = normalizeZipPath(opfPathRaw)
        let opfDir = substringBeforeLast(opfPath, delimiter: "/")
        guard let opfEntry = findZipEntry(entryIndex, path: opfPath),
              let opfXml = readEntryText(archive, entry: opfEntry),
              let opfDoc = try? SwiftSoup.parse(opfXml, "", Parser.xmlParser()) else {
            return EpubComicInfo(isComic: false, imagePaths: [], isRtl: true, title: fallbackTitle, author: "未知作者", coverBytes: nil)
        }

        let rawTitle = (try? opfDoc.select("dc|title, *|title, title").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? fallbackTitle : rawTitle
        let rawAuthor = (try? opfDoc.select("dc|creator, *|creator, creator").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = rawAuthor.isEmpty ? "未知作者" : rawAuthor

        var manifestHref: [String: String] = [:]
        var manifestProperties: [String: String] = [:]
        var manifestMediaType: [String: String] = [:]
        if let items = try? opfDoc.select("manifest > item, *|manifest > *|item, item[id][href]") {
            for item in items.array() {
                let id = (try? item.attr("id")) ?? ""
                let href = (try? item.attr("href")) ?? ""
                if !id.isEmpty && !href.isEmpty && manifestHref[id] == nil {
                    manifestHref[id] = href
                    manifestProperties[id] = (try? item.attr("properties")) ?? ""
                    manifestMediaType[id] = (try? item.attr("media-type")) ?? ""
                }
            }
        }

        let spineEl = try? opfDoc.select("spine, *|spine").first()
        let pageProgression = ((try? spineEl?.attr("page-progression-direction")) ?? "").lowercased()
        let isRtl = pageProgression != "ltr"

        var isPrePaginated = false
        if let metas = try? opfDoc.select("meta, *|meta") {
            for meta in metas.array() {
                let prop = ((try? meta.attr("property")) ?? "").lowercased()
                let txt = ((try? meta.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if prop == "rendition:layout" && txt == "pre-paginated" {
                    isPrePaginated = true
                    break
                }
                let nameAttr = ((try? meta.attr("name")) ?? "").lowercased()
                let contentAttr = ((try? meta.attr("content")) ?? "").lowercased()
                if nameAttr == "fixed-layout" && contentAttr == "true" {
                    isPrePaginated = true
                    break
                }
            }
        }

        let spineItems = (try? opfDoc.select("spine > itemref, *|spine > *|itemref, itemref[idref]").array()) ?? []
        var orderedImages: [String] = []
        var seenImages = Set<String>()
        var imageOnlySpineCount = 0
        var totalTextChars = 0

        func addUniqueImage(_ path: String) {
            if seenImages.insert(path).inserted {
                orderedImages.append(path)
            }
        }

        for itemRef in spineItems {
            let idRef = (try? itemRef.attr("idref")) ?? ""
            guard let rawHref = manifestHref[idRef] else { continue }
            let cleanHref = substringBefore(rawHref, delimiter: "#")
            let fullPath = resolveZipPath(baseDir: opfDir, relativeHref: cleanHref)
            let mediaType = (manifestMediaType[idRef] ?? "").lowercased()

            if mediaType.hasPrefix("image/") || NaturalSort.isSupportedImageName(fullPath) {
                if let entry = findZipEntry(entryIndex, path: fullPath) {
                    addUniqueImage(entry.path)
                    imageOnlySpineCount += 1
                }
                continue
            }

            guard let entry = findZipEntry(entryIndex, path: fullPath),
                  let xhtml = readEntryText(archive, entry: entry),
                  let doc = parseXhtmlSafely(xhtml) else { continue }

            let xhtmlDir = substringBeforeLast(fullPath, delimiter: "/")
            let pageImgs = extractImageRefsFromXhtml(doc: doc, xhtmlDir: xhtmlDir, entryIndex: entryIndex)
            let textLen = extractReadableText(doc).count
            totalTextChars += textLen

            if !pageImgs.isEmpty {
                for p in pageImgs { addUniqueImage(p) }
                if textLen < 45 {
                    imageOnlySpineCount += 1
                }
            }
        }

        if orderedImages.isEmpty && (isPrePaginated || totalTextChars < 120) {
            let allZipImgs = Array(Set(entryIndex.exact.values.map { $0.path }))
                .filter { NaturalSort.isSupportedImageName($0) }
                .sorted(by: NaturalSort.lessThan)
            for p in allZipImgs { addUniqueImage(p) }
        }

        let spineCount = max(1, spineItems.count)
        let isComic = orderedImages.count >= 2 && (
            isPrePaginated ||
            totalTextChars < 300 ||
            (Float(imageOnlySpineCount) / Float(spineCount) >= 0.55 && orderedImages.count >= 4)
        )

        var coverBytes = extractCoverBytes(
            archive: archive,
            entryIndex: entryIndex,
            opfDoc: opfDoc,
            opfDir: opfDir,
            manifestHref: manifestHref,
            manifestProperties: manifestProperties,
            manifestMediaType: manifestMediaType
        )
        if coverBytes == nil, let firstImg = orderedImages.first, let e = findZipEntry(entryIndex, path: firstImg) {
            coverBytes = readEntryData(archive, entry: e)
        }

        return EpubComicInfo(
            isComic: isComic,
            imagePaths: orderedImages,
            isRtl: isRtl,
            title: title,
            author: author,
            coverBytes: coverBytes
        )
    }

    private static func extractImageRefsFromXhtml(
        doc: Document,
        xhtmlDir: String,
        entryIndex: ZipEntryIndex
    ) -> [String] {
        var found: [String] = []
        if let imgs = try? doc.select("img[src]") {
            for img in imgs.array() {
                let rawSrc = (try? img.attr("src")) ?? ""
                let src = substringBefore(rawSrc, delimiter: "#").trimmingCharacters(in: .whitespacesAndNewlines)
                if src.isEmpty || src.hasPrefix("data:") || src.hasPrefix("http") { continue }
                let resolved = resolveZipPath(baseDir: xhtmlDir, relativeHref: src)
                if let e = findZipEntry(entryIndex, path: resolved) {
                    found.append(e.path)
                }
            }
        }
        if let svgImgs = try? doc.select("image, *|image") {
            for svgImg in svgImgs.array() {
                var href = (try? svgImg.attr("xlink:href")) ?? ""
                if href.isEmpty { href = (try? svgImg.attr("href")) ?? "" }
                if href.isEmpty { href = (try? svgImg.attr("l:href")) ?? "" }
                href = substringBefore(href, delimiter: "#").trimmingCharacters(in: .whitespacesAndNewlines)
                if href.isEmpty || href.hasPrefix("data:") || href.hasPrefix("http") { continue }
                let resolved = resolveZipPath(baseDir: xhtmlDir, relativeHref: href)
                if let e = findZipEntry(entryIndex, path: resolved) {
                    found.append(e.path)
                }
            }
        }
        return found
    }

    private static func parseEpub(fileURL: URL, fallbackTitle: String) -> ParsedBook {
        guard let archive = try? Archive(url: fileURL, accessMode: .read) else {
            return ParsedBook(
                title: fallbackTitle,
                author: "未知作者",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "無法開啟 EPUB 壓縮檔案。")]
            )
        }

        let entryIndex = buildZipEntryIndex(archive)
        guard let containerEntry = findZipEntry(entryIndex, path: "META-INF/container.xml"),
              let containerXml = readEntryText(archive, entry: containerEntry),
              let containerDoc = try? SwiftSoup.parse(containerXml, "", Parser.xmlParser()) else {
            return ParsedBook(
                title: fallbackTitle,
                author: "未知作者",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "無法解析 EPUB：缺少 META-INF/container.xml")]
            )
        }

        guard let rootfileEl = try? containerDoc.select("rootfile, *|rootfile").first(),
              let opfPathRaw = try? rootfileEl.attr("full-path"),
              !opfPathRaw.isEmpty else {
            return ParsedBook(
                title: fallbackTitle,
                author: "未知作者",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "無法解析 EPUB：找不到 OPF 路徑")]
            )
        }

        let opfPath = normalizeZipPath(opfPathRaw)
        let opfDir = substringBeforeLast(opfPath, delimiter: "/")
        guard let opfEntry = findZipEntry(entryIndex, path: opfPath),
              let opfXml = readEntryText(archive, entry: opfEntry),
              let opfDoc = try? SwiftSoup.parse(opfXml, "", Parser.xmlParser()) else {
            return ParsedBook(
                title: fallbackTitle,
                author: "未知作者",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "無法解析 EPUB：OPF 檔案不存在 (\(opfPath))")]
            )
        }

        let rawTitle = (try? opfDoc.select("dc|title, *|title, title").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? fallbackTitle : rawTitle
        let rawAuthor = (try? opfDoc.select("dc|creator, *|creator, creator").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = rawAuthor.isEmpty ? "未知作者" : rawAuthor

        var manifestHref: [String: String] = [:]
        var manifestProperties: [String: String] = [:]
        var manifestMediaType: [String: String] = [:]
        if let items = try? opfDoc.select("manifest > item, *|manifest > *|item, item[id][href]") {
            for item in items.array() {
                let id = (try? item.attr("id")) ?? ""
                let href = (try? item.attr("href")) ?? ""
                if !id.isEmpty && !href.isEmpty && manifestHref[id] == nil {
                    manifestHref[id] = href
                    manifestProperties[id] = (try? item.attr("properties")) ?? ""
                    manifestMediaType[id] = (try? item.attr("media-type")) ?? ""
                }
            }
        }

        let coverBytes = extractCoverBytes(
            archive: archive,
            entryIndex: entryIndex,
            opfDoc: opfDoc,
            opfDir: opfDir,
            manifestHref: manifestHref,
            manifestProperties: manifestProperties,
            manifestMediaType: manifestMediaType
        )
        let drmEncryptedPaths = detectDrmEncryptedPaths(archive: archive, entryIndex: entryIndex)
        let tocTitleMap = extractTocTitles(
            archive: archive,
            entryIndex: entryIndex,
            opfDoc: opfDoc,
            opfDir: opfDir,
            manifestHref: manifestHref,
            manifestProperties: manifestProperties
        )

        var chapters: [Chapter] = []
        let spineItems = (try? opfDoc.select("spine > itemref, *|spine > *|itemref, itemref[idref]").array()) ?? []
        var skippedDrmCount = 0

        for itemRef in spineItems {
            let idRef = (try? itemRef.attr("idref")) ?? ""
            guard let rawHref = manifestHref[idRef] else { continue }
            let cleanHref = substringBefore(rawHref, delimiter: "#")
            let fullPath = resolveZipPath(baseDir: opfDir, relativeHref: cleanHref)

            if drmEncryptedPaths.contains(fullPath.lowercased()) {
                skippedDrmCount += 1
                continue
            }

            guard let entry = findZipEntry(entryIndex, path: fullPath),
                  let xhtml = readEntryText(archive, entry: entry),
                  let doc = parseXhtmlSafely(xhtml) else { continue }

            let headingInDoc = ((try? doc.select("h1, h2, h3, title").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let decodedHref = decodePercentPath(cleanHref)
            let baseClean = substringAfterLast(cleanHref, delimiter: "/")
            let baseDecoded = substringAfterLast(decodedHref, delimiter: "/")

            let chapterTitle = tocTitleMap[cleanHref]
                ?? tocTitleMap[decodedHref]
                ?? tocTitleMap[baseClean]
                ?? tocTitleMap[baseDecoded]
                ?? ((!headingInDoc.isEmpty && headingInDoc.count <= 60) ? headingInDoc : nil)
                ?? "第 \(chapters.count + 1) 章"

            let extractedBody = extractReadableText(doc)
            if extractedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let cleanedContent = removeLeadingDuplicateTitle(body: extractedBody, chapterTitle: chapterTitle)
            chapters.append(
                Chapter(
                    index: chapters.count,
                    title: chapterTitle,
                    content: cleanedContent.isEmpty ? extractedBody : cleanedContent
                )
            )
        }

        if chapters.isEmpty {
            let fallbackMsg = skippedDrmCount > 0
                ? "此 EPUB 檔案受 DRM 加密保護，無法直接讀取內文。請匯入無 DRM 的 EPUB 檔案。"
                : "此 EPUB 未偵測到可讀取的文字章節。若為漫畫 EPUB，可於書架點擊該書右上角選單切換為「漫畫模式」。"
            chapters.append(Chapter(index: 0, title: title, content: fallbackMsg))
        }

        return ParsedBook(
            title: title,
            author: author,
            chapters: chapters,
            coverBytes: coverBytes,
            contentType: .TEXT
        )
    }

    static func parseXhtmlSafely(_ rawHtml: String) -> Document? {
        var sanitized = rawHtml
        if let regex = selfClosingRawTagRegex {
            let nsRange = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: nsRange, withTemplate: "<$1$2></$1>")
        }
        if let htmlDoc = try? SwiftSoup.parse(sanitized) {
            let bodyText = ((try? htmlDoc.body()?.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasImages = ((try? htmlDoc.select("img, image, *|image").isEmpty()) == false)
            if !bodyText.isEmpty || hasImages {
                return htmlDoc
            }
        }
        return try? SwiftSoup.parse(rawHtml, "", Parser.xmlParser())
    }

    static func extractReadableText(_ doc: Document) -> String {
        let root: Element = doc.body() ?? (try? doc.select("body, *|body").first()) ?? doc
        var sb = ""
        sb.reserveCapacity(4096)
        walkNode(root, sb: &sb, inPre: false)
        return sb.components(separatedBy: "\n")
            .map { line in
                line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}")))
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func walkNode(_ node: Node, sb: inout String, inPre: Bool) {
        if let textNode = node as? TextNode {
            let text = inPre ? textNode.getWholeText() : textNode.text()
            if text.isEmpty { return }
            if inPre {
                sb.append(text)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let last = sb.last, last != "\n" && last != " " && last != "\u{3000}" {
                    sb.append(" ")
                }
            } else {
                sb.append(text)
            }
        } else if let element = node as? Element {
            let rawTag = element.tagName()
            let tag = substringAfterLast(rawTag, delimiter: ":").lowercased()
            if skipTags.contains(tag) { return }
            if tag == "br" {
                sb.append("\n")
                return
            }
            let isBlock = blockTags.contains(tag)
            let nextInPre = inPre || tag == "pre"
            if isBlock { ensureNewline(&sb) }
            for child in element.getChildNodes() {
                walkNode(child, sb: &sb, inPre: nextInPre)
            }
            if isBlock { ensureNewline(&sb) }
        }
    }

    private static func ensureNewline(_ sb: inout String) {
        if let last = sb.last, last != "\n" {
            sb.append("\n")
        }
    }

    private static func removeLeadingDuplicateTitle(body: String, chapterTitle: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard lines.count > 1 else { return body }
        let wsSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}"))
        let firstNorm = lines[0].components(separatedBy: wsSet).joined()
        let titleNorm = chapterTitle.components(separatedBy: wsSet).joined()
        if !firstNorm.isEmpty && firstNorm == titleNorm {
            return lines.dropFirst().joined(separator: "\n")
        }
        return body
    }

    private static func detectDrmEncryptedPaths(archive: Archive, entryIndex: ZipEntryIndex) -> Set<String> {
        guard let encEntry = findZipEntry(entryIndex, path: "META-INF/encryption.xml"),
              let xml = readEntryText(archive, entry: encEntry),
              let doc = try? SwiftSoup.parse(xml, "", Parser.xmlParser()),
              let encItems = try? doc.select("EncryptedData, *|EncryptedData") else {
            return []
        }
        var result = Set<String>()
        for encData in encItems.array() {
            let algo = ((try? encData.select("EncryptionMethod, *|EncryptionMethod").first()?.attr("Algorithm")) ?? "").lowercased()
            if algo.contains("embedding") || algo.contains("adobe.com/pdf/enc") { continue }
            let uri = (try? encData.select("CipherReference, *|CipherReference").first()?.attr("URI")) ?? ""
            if !uri.isEmpty {
                result.insert(normalizeZipPath(uri).lowercased())
            }
        }
        return result
    }

    private static func extractCoverBytes(
        archive: Archive,
        entryIndex: ZipEntryIndex,
        opfDoc: Document,
        opfDir: String,
        manifestHref: [String: String],
        manifestProperties: [String: String],
        manifestMediaType: [String: String]
    ) -> Data? {
        var coverId = manifestProperties.first(where: { $0.value.contains("cover-image") })?.key
        if coverId == nil {
            coverId = try? opfDoc.select("meta[name=cover], *|meta[name=cover]").first()?.attr("content")
            if coverId?.isEmpty == true { coverId = nil }
        }
        if coverId == nil {
            coverId = manifestHref.first(where: { id, href in
                (id.localizedCaseInsensitiveContains("cover") || href.localizedCaseInsensitiveContains("cover")) &&
                    (manifestMediaType[id]?.hasPrefix("image/") == true)
            })?.key
        }
        guard let cid = coverId,
              let href = manifestHref[cid],
              let entry = findZipEntry(entryIndex, path: resolveZipPath(baseDir: opfDir, relativeHref: href)) else {
            return nil
        }
        return readEntryData(archive, entry: entry)
    }

    private static func extractTocTitles(
        archive: Archive,
        entryIndex: ZipEntryIndex,
        opfDoc: Document,
        opfDir: String,
        manifestHref: [String: String],
        manifestProperties: [String: String]
    ) -> [String: String] {
        var map: [String: String] = [:]

        func insertIfAbsent(_ key: String, _ value: String) {
            if !key.isEmpty && map[key] == nil {
                map[key] = value
            }
        }

        if let navId = manifestProperties.first(where: { $0.value.contains("nav") })?.key,
           let navHref = manifestHref[navId],
           let entry = findZipEntry(entryIndex, path: resolveZipPath(baseDir: opfDir, relativeHref: navHref)),
           let navHtml = readEntryText(archive, entry: entry),
           let navDoc = parseXhtmlSafely(navHtml),
           let links = try? navDoc.select("nav a[href]") {
            for a in links.array() {
                let href = substringBefore((try? a.attr("href")) ?? "", delimiter: "#")
                let label = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !href.isEmpty && !label.isEmpty {
                    let dec = decodePercentPath(href)
                    insertIfAbsent(href, label)
                    insertIfAbsent(dec, label)
                    insertIfAbsent(substringAfterLast(href, delimiter: "/"), label)
                    insertIfAbsent(substringAfterLast(dec, delimiter: "/"), label)
                }
            }
        }

        let tocId = try? opfDoc.select("spine, *|spine").first()?.attr("toc")
        let ncxHref = (tocId.flatMap { manifestHref[$0] })
            ?? manifestHref.values.first(where: { $0.lowercased().hasSuffix(".ncx") })

        if let ncxHref,
           let entry = findZipEntry(entryIndex, path: resolveZipPath(baseDir: opfDir, relativeHref: ncxHref)),
           let ncxXml = readEntryText(archive, entry: entry),
           let ncxDoc = try? SwiftSoup.parse(ncxXml, "", Parser.xmlParser()),
           let navPoints = try? ncxDoc.select("navPoint, *|navPoint") {
            for navPoint in navPoints.array() {
                let label = ((try? navPoint.select("navLabel > text, *|navLabel > *|text").first()?.text()) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let srcRaw = (try? navPoint.select("content, *|content").first()?.attr("src")) ?? ""
                let src = substringBefore(srcRaw, delimiter: "#")
                if !label.isEmpty && !src.isEmpty {
                    let dec = decodePercentPath(src)
                    insertIfAbsent(src, label)
                    insertIfAbsent(dec, label)
                    insertIfAbsent(substringAfterLast(src, delimiter: "/"), label)
                    insertIfAbsent(substringAfterLast(dec, delimiter: "/"), label)
                }
            }
        }

        return map
    }

    // MARK: - ZIP Entry Helpers

    private struct ZipEntryIndex {
        var exact: [String: ZIPFoundation.Entry] = [:]
        var lower: [String: ZIPFoundation.Entry] = [:]
    }

    private static func buildZipEntryIndex(_ archive: Archive) -> ZipEntryIndex {
        var idx = ZipEntryIndex()
        for entry in archive {
            let norm = normalizeZipPath(entry.path)
            idx.exact[norm] = entry
            let low = norm.lowercased()
            if idx.lower[low] == nil {
                idx.lower[low] = entry
            }
        }
        return idx
    }

    private static func findZipEntry(_ index: ZipEntryIndex, path: String) -> ZIPFoundation.Entry? {
        let norm = normalizeZipPath(path)
        if let e = index.exact[norm] { return e }
        if let e = index.lower[norm.lowercased()] { return e }
        return index.lower[decodePercentPath(norm).lowercased()]
    }

    static func readEntryData(_ archive: Archive, entry: ZIPFoundation.Entry) -> Data? {
        guard entry.type == .file else { return nil }
        var out = Data()
        out.reserveCapacity(Int(min(entry.uncompressedSize, 16 * 1024 * 1024)))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                out.append(chunk)
            }
            return out
        } catch {
            return nil
        }
    }

    private static func readEntryText(_ archive: Archive, entry: ZIPFoundation.Entry) -> String? {
        guard let data = readEntryData(archive, entry: entry) else { return nil }
        return decodeBytesSmart(data)
    }

    private static func normalizeZipPath(_ path: String) -> String {
        var s = path.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    private static func decodePercentPath(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }

    private static func resolveZipPath(baseDir: String, relativeHref: String) -> String {
        let decoded = decodePercentPath(relativeHref).replacingOccurrences(of: "\\", with: "/")
        if baseDir.isEmpty { return normalizeZipPath(decoded) }
        let parts = (baseDir.components(separatedBy: "/") + decoded.components(separatedBy: "/"))
            .filter { !$0.isEmpty }
        var stack: [String] = []
        for p in parts {
            if p == "." { continue }
            if p == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(p)
            }
        }
        return stack.joined(separator: "/")
    }

    private static func substringBefore(_ s: String, delimiter: Character) -> String {
        guard let idx = s.firstIndex(of: delimiter) else { return s }
        return String(s[..<idx])
    }

    private static func substringBeforeLast(_ s: String, delimiter: Character) -> String {
        guard let idx = s.lastIndex(of: delimiter) else { return "" }
        return String(s[..<idx])
    }

    private static func substringAfterLast(_ s: String, delimiter: Character) -> String {
        guard let idx = s.lastIndex(of: delimiter) else { return s }
        return String(s[s.index(after: idx)...])
    }
}
