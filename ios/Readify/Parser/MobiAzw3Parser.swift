import Foundation
import ImageIO
import SwiftSoup

struct MobiImageIndex {
    var imageRecordIndices: [Int]
    var coverRecordIndex: Int?
}

enum MobiAzw3Parser {
    private struct PdbInfo {
        var pdbTitle: String
        var recordOffsets: [UInt64]
        var fileLength: UInt64
    }

    private struct MobiHeaderInfo {
        var compression: Int
        var textRecordCount: Int
        var encryptionType: Int
        var encoding: Int
        var firstImageIndex: Int
        var fullTitle: String
        var author: String
        var coverOffset: Int?
        var thumbOffset: Int?
        var kf8BoundaryRecord: Int?
        var huffRecordOffset: Int
        var huffRecordCount: Int
        var extraDataFlags: Int
    }

    private struct Kf8Resolved {
        var baseRecord: Int
        var header: MobiHeaderInfo
    }

    static func parseMetadataAndCover(fileURL: URL, fallbackTitle: String) -> ParsedBook {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            return ParsedBook(title: fallbackTitle, author: "Kindle 電子書", chapters: [])
        }
        defer { try? fh.close() }

        let pdb = readPdbInfo(fh)
        guard !pdb.recordOffsets.isEmpty else {
            return ParsedBook(title: fallbackTitle, author: "Kindle 電子書", chapters: [])
        }

        let rec0 = readRecord(fh, pdb: pdb, index: 0)
        let baseTitle = pdb.pdbTitle.isEmpty ? fallbackTitle : pdb.pdbTitle
        let header0 = parseMobiHeader(rec0, fallbackTitle: baseTitle)
        let kf8 = resolveKf8Header(fh, pdb: pdb, header0: header0)

        let imgIndex = scanAllImageRecords(fh, pdb: pdb, header0: header0, kf8: kf8)
        let coverBytes = resolveBestCoverBytes(fh, pdb: pdb, header0: header0, kf8: kf8, imgIndex: imgIndex)

        let bestTitle = nonEmpty(kf8?.header.fullTitle)
            ?? nonEmpty(header0.fullTitle)
            ?? fallbackTitle
        let bestAuthor = nonEmpty(kf8?.header.author)
            ?? nonEmpty(header0.author)
            ?? "Kindle 電子書"

        let contentType = detectContentTypeQuick(fh, pdb: pdb, header: header0, imgIndex: imgIndex)

        return ParsedBook(
            title: bestTitle,
            author: bestAuthor,
            chapters: [],
            coverBytes: coverBytes,
            contentType: contentType
        )
    }

    static func parseFullBook(fileURL: URL, fallbackTitle: String) -> ParsedBook {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            return ParsedBook(
                title: fallbackTitle,
                author: "Kindle 電子書",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "無法開啟此 Kindle 檔案。")]
            )
        }
        defer { try? fh.close() }

        let pdb = readPdbInfo(fh)
        guard !pdb.recordOffsets.isEmpty else {
            return ParsedBook(
                title: fallbackTitle,
                author: "Kindle 電子書",
                chapters: [Chapter(index: 0, title: fallbackTitle, content: "無法解析此 Kindle 檔案：PDB 結構無效。")]
            )
        }

        let rec0 = readRecord(fh, pdb: pdb, index: 0)
        let header0 = parseMobiHeader(rec0, fallbackTitle: pdb.pdbTitle.isEmpty ? fallbackTitle : pdb.pdbTitle)

        if header0.encryptionType != 0 {
            return ParsedBook(
                title: nonEmpty(header0.fullTitle) ?? fallbackTitle,
                author: nonEmpty(header0.author) ?? "Kindle 電子書",
                chapters: [
                    Chapter(
                        index: 0,
                        title: "DRM 加密檔案",
                        content: "此 Kindle 檔案（MOBI/AZW3）受到 DRM 加密保護（encryptionType=\(header0.encryptionType)），無法直接讀取內文。請匯入無 DRM 加密的檔案。"
                    )
                ]
            )
        }

        let kf8 = resolveKf8Header(fh, pdb: pdb, header0: header0)
        let baseRecord = kf8?.baseRecord ?? 0
        var activeHeader = kf8?.header ?? header0
        if activeHeader.fullTitle.isEmpty { activeHeader.fullTitle = header0.fullTitle }
        if activeHeader.author.isEmpty { activeHeader.author = header0.author }

        if activeHeader.encryptionType != 0 {
            return ParsedBook(
                title: nonEmpty(activeHeader.fullTitle) ?? fallbackTitle,
                author: nonEmpty(activeHeader.author) ?? "Kindle 電子書",
                chapters: [Chapter(index: 0, title: "DRM 加密檔案", content: "此 AZW3 (KF8) 檔案受到 DRM 加密保護，無法直接讀取內文。")]
            )
        }

        let huffDecoder = (activeHeader.compression == 17480)
            ? buildHuffCdicDecoder(fh, pdb: pdb, baseRecord: baseRecord, header: activeHeader)
            : nil

        var htmlBytes = Data()
        let maxAvail = max(0, pdb.recordOffsets.count - baseRecord - 1)
        let textCount = min(activeHeader.textRecordCount, maxAvail)
        if textCount >= 1 {
            for i in 1...textCount {
                let recIdx = baseRecord + i
                if recIdx >= pdb.recordOffsets.count { break }
                var rawRec = readRecord(fh, pdb: pdb, index: recIdx)
                rawRec = stripTrailingData(rawRec, flags: activeHeader.extraDataFlags)
                let decompressed: Data
                switch activeHeader.compression {
                case 1:
                    decompressed = rawRec
                case 2:
                    decompressed = decompressPalmDoc(rawRec)
                case 17480:
                    decompressed = huffDecoder?.decompress(rawRec) ?? Data()
                default:
                    decompressed = rawRec
                }
                htmlBytes.append(decompressed)
            }
        }

        let encoding: String.Encoding = (activeHeader.encoding == 1252) ? .windowsCP1252 : .utf8
        let rawHtml = String(data: htmlBytes, encoding: encoding) ?? BookParser.decodeBytesSmart(htmlBytes)
        let resolvedTitle = nonEmpty(activeHeader.fullTitle) ?? fallbackTitle
        let chapters = splitHtmlIntoChapters(rawHtml: rawHtml, fallbackTitle: resolvedTitle)

        let imgIndex = scanAllImageRecords(fh, pdb: pdb, header0: header0, kf8: kf8)
        let coverBytes = resolveBestCoverBytes(fh, pdb: pdb, header0: header0, kf8: kf8, imgIndex: imgIndex)

        let totalChars = chapters.reduce(0) { $0 + $1.content.count }
        let isComic = imgIndex.imageRecordIndices.count >= 4 && totalChars < 350

        return ParsedBook(
            title: resolvedTitle,
            author: nonEmpty(activeHeader.author) ?? "Kindle 電子書",
            chapters: chapters.isEmpty
                ? [Chapter(index: 0, title: resolvedTitle, content: "（未能從此 Kindle 檔案中擷取到文字內容）")]
                : chapters,
            coverBytes: coverBytes,
            contentType: isComic ? .COMIC : .TEXT
        )
    }

    static func getImageIndex(fileURL: URL) -> MobiImageIndex {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            return MobiImageIndex(imageRecordIndices: [], coverRecordIndex: nil)
        }
        defer { try? fh.close() }

        let pdb = readPdbInfo(fh)
        guard !pdb.recordOffsets.isEmpty else {
            return MobiImageIndex(imageRecordIndices: [], coverRecordIndex: nil)
        }
        let rec0 = readRecord(fh, pdb: pdb, index: 0)
        let header0 = parseMobiHeader(rec0, fallbackTitle: pdb.pdbTitle)
        let kf8 = resolveKf8Header(fh, pdb: pdb, header0: header0)
        return scanAllImageRecords(fh, pdb: pdb, header0: header0, kf8: kf8)
    }

    static func readImageRecordBytes(fileURL: URL, recordIndex: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }

        let pdb = readPdbInfo(fh)
        guard recordIndex >= 0 && recordIndex < pdb.recordOffsets.count else { return nil }
        let raw = readRecord(fh, pdb: pdb, index: recordIndex)
        return extractImagePayload(raw) ?? raw
    }

    // MARK: - KF8 & Cover Resolution

    private static func resolveKf8Header(_ fh: FileHandle, pdb: PdbInfo, header0: MobiHeaderInfo) -> Kf8Resolved? {
        guard let boundary = header0.kf8BoundaryRecord,
              boundary >= 1 && boundary < pdb.recordOffsets.count else { return nil }

        let recAtBoundary = readRecord(fh, pdb: pdb, index: boundary)
        let isBoundaryMarker = recAtBoundary.count >= 8 &&
            String(bytes: recAtBoundary.prefix(8), encoding: .ascii) == "BOUNDARY"

        let actualKf8RecIdx = isBoundaryMarker ? (boundary + 1) : boundary
        guard actualKf8RecIdx >= 1 && actualKf8RecIdx < pdb.recordOffsets.count else { return nil }

        let kf8Rec = isBoundaryMarker ? readRecord(fh, pdb: pdb, index: actualKf8RecIdx) : recAtBoundary
        guard kf8Rec.count >= 24,
              String(bytes: kf8Rec.subdata(in: 16..<20), encoding: .ascii) == "MOBI" else {
            return nil
        }

        let parsed = parseMobiHeader(kf8Rec, fallbackTitle: header0.fullTitle)
        return Kf8Resolved(baseRecord: actualKf8RecIdx, header: parsed)
    }

    private static func resolveBestCoverBytes(
        _ fh: FileHandle,
        pdb: PdbInfo,
        header0: MobiHeaderInfo,
        kf8: Kf8Resolved?,
        imgIndex: MobiImageIndex
    ) -> Data? {
        var candidates: [Int] = []
        var seen = Set<Int>()

        func addCandidate(_ baseIdx: Int, _ offset: Int?) {
            guard baseIdx > 0, let off = offset, off >= 0 else { return }
            let idx = baseIdx + off
            if idx >= 1 && idx < pdb.recordOffsets.count && seen.insert(idx).inserted {
                candidates.append(idx)
            }
        }

        addCandidate(header0.firstImageIndex, header0.coverOffset)
        if let kf8 {
            addCandidate(kf8.header.firstImageIndex, kf8.header.coverOffset)
            addCandidate(header0.firstImageIndex, kf8.header.coverOffset)
            if kf8.header.firstImageIndex > 0 {
                addCandidate(kf8.baseRecord + kf8.header.firstImageIndex, kf8.header.coverOffset)
            }
        }

        addCandidate(header0.firstImageIndex, header0.thumbOffset)
        if let kf8 {
            addCandidate(kf8.header.firstImageIndex, kf8.header.thumbOffset)
            addCandidate(header0.firstImageIndex, kf8.header.thumbOffset)
        }

        for idx in candidates {
            let raw = readRecord(fh, pdb: pdb, index: idx)
            guard let payload = extractImagePayload(raw),
                  let dims = probeImageDimensions(payload),
                  dims.0 >= 24 && dims.1 >= 24 else { continue }
            return payload
        }

        var bestFallback: Data?
        var bestArea: Int64 = 0
        for idx in imgIndex.imageRecordIndices.prefix(40) {
            let raw = readRecord(fh, pdb: pdb, index: idx)
            guard let payload = extractImagePayload(raw),
                  let (w, h) = probeImageDimensions(payload) else { continue }
            if w >= 120 && h >= 120 {
                return payload
            }
            let area = Int64(w) * Int64(h)
            if area > bestArea {
                bestArea = area
                bestFallback = payload
            }
        }
        return bestFallback
    }

    private static func probeImageDimensions(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0 && h > 0 else {
            return nil
        }
        return (w, h)
    }

    private static func scanAllImageRecords(
        _ fh: FileHandle,
        pdb: PdbInfo,
        header0: MobiHeaderInfo,
        kf8: Kf8Resolved?
    ) -> MobiImageIndex {
        let total = pdb.recordOffsets.count
        let candidateStarts = [
            header0.firstImageIndex,
            kf8?.header.firstImageIndex ?? -1,
            header0.textRecordCount + 1
        ].filter { $0 >= 1 && $0 < total }
        let primaryStart = candidateStarts.min() ?? 1

        var images: [Int] = []

        func scanRange(_ from: Int, _ toExclusive: Int) {
            guard from < toExclusive else { return }
            for i in from..<toExclusive {
                let recLen = recordLength(pdb, index: i)
                if recLen < 24 { continue }
                let toRead = min(48, recLen)
                try? fh.seek(toOffset: pdb.recordOffsets[i])
                guard let probe = try? fh.read(upToCount: toRead), probe.count >= 4 else { continue }
                let bytes = [UInt8](probe)
                if findImageStartOffset(bytes, limit: bytes.count) >= 0 {
                    images.append(i)
                }
            }
        }

        scanRange(primaryStart, total)
        if images.isEmpty && primaryStart > 1 {
            scanRange(1, primaryStart)
        }

        var explicitCover: Int?
        if let off = header0.coverOffset {
            let idx = header0.firstImageIndex + off
            if images.contains(idx) { explicitCover = idx }
        }
        if explicitCover == nil, let kf8, let off = kf8.header.coverOffset {
            let idx = kf8.header.firstImageIndex + off
            if images.contains(idx) { explicitCover = idx }
        }

        return MobiImageIndex(imageRecordIndices: images, coverRecordIndex: explicitCover)
    }

    private static func extractImagePayload(_ raw: Data) -> Data? {
        guard raw.count >= 24 else { return nil }
        let limit = min(raw.count, 64)
        let head = [UInt8](raw.prefix(limit))
        let startOffset = findImageStartOffset(head, limit: head.count)
        guard startOffset >= 0 else { return nil }
        return startOffset == 0 ? raw : raw.subdata(in: startOffset..<raw.count)
    }

    private static func findImageStartOffset(_ buf: [UInt8], limit: Int) -> Int {
        guard limit >= 4 else { return -1 }
        if matchesImageMagicAt(buf, off: 0, limit: limit) { return 0 }

        let isCres = buf[0] == 0x43 && buf[1] == 0x52 && buf[2] == 0x45 && buf[3] == 0x53 // "CRES"
        let maxScan = isCres ? min(limit - 4, 48) : min(limit - 4, 16)
        guard maxScan >= 1 else { return -1 }
        for off in 1...maxScan {
            if matchesImageMagicAt(buf, off: off, limit: limit) {
                return off
            }
        }
        return -1
    }

    private static func matchesImageMagicAt(_ b: [UInt8], off: Int, limit: Int) -> Bool {
        if off + 4 > limit { return false }
        // JPEG
        if b[off] == 0xFF && b[off + 1] == 0xD8 && b[off + 2] == 0xFF { return true }
        // PNG
        if b[off] == 0x89 && b[off + 1] == 0x50 && b[off + 2] == 0x4E && b[off + 3] == 0x47 { return true }
        // GIF87a / GIF89a
        if off + 6 <= limit &&
            b[off] == 0x47 && b[off + 1] == 0x49 && b[off + 2] == 0x46 &&
            b[off + 3] == 0x38 && (b[off + 4] == 0x37 || b[off + 4] == 0x39) &&
            b[off + 5] == 0x61 {
            return true
        }
        // WebP: RIFF....WEBP
        if off + 12 <= limit &&
            b[off] == 0x52 && b[off + 1] == 0x49 && b[off + 2] == 0x46 && b[off + 3] == 0x46 &&
            b[off + 8] == 0x57 && b[off + 9] == 0x45 && b[off + 10] == 0x42 && b[off + 11] == 0x50 {
            return true
        }
        // BMP
        if off + 18 <= limit && b[off] == 0x42 && b[off + 1] == 0x4D {
            let dibSize = Int(b[off + 14]) |
                (Int(b[off + 15]) << 8) |
                (Int(b[off + 16]) << 16) |
                (Int(b[off + 17]) << 24)
            if [12, 40, 52, 56, 108, 124].contains(dibSize) { return true }
        }
        return false
    }

    private static func detectContentTypeQuick(
        _ fh: FileHandle,
        pdb: PdbInfo,
        header: MobiHeaderInfo,
        imgIndex: MobiImageIndex
    ) -> BookContentType {
        if header.encryptionType != 0 { return .TEXT }
        if imgIndex.imageRecordIndices.count < 6 { return .TEXT }
        let sampleCount = min(header.textRecordCount, 3)
        var textChars = 0
        if sampleCount >= 1 {
            for i in 1...sampleCount {
                if i >= pdb.recordOffsets.count { break }
                let rec = stripTrailingData(readRecord(fh, pdb: pdb, index: i), flags: header.extraDataFlags)
                let data: Data
                switch header.compression {
                case 1: data = rec
                case 2: data = decompressPalmDoc(rec)
                default: data = Data()
                }
                if !data.isEmpty,
                   let html = String(data: data, encoding: .utf8),
                   let doc = try? SwiftSoup.parse(html),
                   let txt = try? doc.text() {
                    textChars += txt.trimmingCharacters(in: .whitespacesAndNewlines).count
                }
            }
        }
        return (header.compression != 17480 && textChars < 80 && imgIndex.imageRecordIndices.count >= 8)
            ? .COMIC
            : .TEXT
    }

    private static func splitHtmlIntoChapters(rawHtml: String, fallbackTitle: String) -> [Chapter] {
        var rawSegments = [rawHtml]
        if let regex = try? NSRegularExpression(pattern: "<mbp:pagebreak\\s*/?>", options: [.caseInsensitive]) {
            let ns = rawHtml as NSString
            let matches = regex.matches(in: rawHtml, options: [], range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                rawSegments.removeAll()
                var lastEnd = 0
                for m in matches {
                    if m.range.location > lastEnd {
                        rawSegments.append(ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
                    }
                    lastEnd = m.range.location + m.range.length
                }
                if lastEnd < ns.length {
                    rawSegments.append(ns.substring(from: lastEnd))
                }
            }
        }

        var cleanedSegments: [(String, String)] = []
        for seg in rawSegments {
            if seg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let doc = try? SwiftSoup.parse(seg) else { continue }
            let bodyText = BookParser.extractReadableText(doc)
            if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let headingRaw = ((try? doc.select("h1, h2, h3").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = String((bodyText.components(separatedBy: "\n").first ?? "").prefix(36))
            let heading = (!headingRaw.isEmpty && headingRaw.count <= 60) ? headingRaw : firstLine
            cleanedSegments.append((heading, bodyText))
        }

        if cleanedSegments.count >= 2 && cleanedSegments.count <= 800 {
            return cleanedSegments.enumerated().map { idx, pair in
                Chapter(
                    index: idx,
                    title: pair.0.isEmpty ? "第 \(idx + 1) 章" : pair.0,
                    content: pair.1
                )
            }
        }

        guard let fullDoc = try? SwiftSoup.parse(rawHtml) else { return [] }
        let fullText = BookParser.extractReadableText(fullDoc)
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return BookParser.splitPlainTextIntoChapters(text: fullText, fallbackTitle: fallbackTitle)
    }

    // MARK: - PDB & MOBI Header Binary Parsing

    private static func readPdbInfo(_ fh: FileHandle) -> PdbInfo {
        let fileLen = (try? fh.seekToEnd()) ?? 0
        guard fileLen >= 78 else { return PdbInfo(pdbTitle: "", recordOffsets: [], fileLength: fileLen) }
        try? fh.seek(toOffset: 0)
        guard let header = try? fh.read(upToCount: 78), header.count == 78 else {
            return PdbInfo(pdbTitle: "", recordOffsets: [], fileLength: fileLen)
        }

        let hdrBytes = [UInt8](header)
        let titleSlice = hdrBytes[0..<32]
        let nullIdx = titleSlice.firstIndex(of: 0) ?? 32
        let pdbTitle = String(decoding: hdrBytes[0..<nullIdx], as: UTF8.self)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let numRecords = readU16(hdrBytes, 76)
        guard numRecords > 0 else { return PdbInfo(pdbTitle: pdbTitle, recordOffsets: [], fileLength: fileLen) }
        let tableBytesCount = numRecords * 8
        guard let tableData = try? fh.read(upToCount: tableBytesCount) else {
            return PdbInfo(pdbTitle: pdbTitle, recordOffsets: [], fileLength: fileLen)
        }
        let tBytes = [UInt8](tableData)
        let actualRecords = min(numRecords, tBytes.count / 8)
        var offsets: [UInt64] = []
        offsets.reserveCapacity(actualRecords)
        for i in 0..<actualRecords {
            offsets.append(UInt64(readU32(tBytes, i * 8)))
        }
        return PdbInfo(pdbTitle: pdbTitle, recordOffsets: offsets, fileLength: fileLen)
    }

    private static func recordLength(_ pdb: PdbInfo, index: Int) -> Int {
        let start = pdb.recordOffsets[index]
        let end = (index + 1 < pdb.recordOffsets.count) ? pdb.recordOffsets[index + 1] : pdb.fileLength
        if end <= start { return 0 }
        return Int(min(end - start, 64 * 1024 * 1024))
    }

    private static func readRecord(_ fh: FileHandle, pdb: PdbInfo, index: Int) -> Data {
        let len = recordLength(pdb, index: index)
        guard len > 0 else { return Data() }
        try? fh.seek(toOffset: pdb.recordOffsets[index])
        return (try? fh.read(upToCount: len)) ?? Data()
    }

    private static func parseMobiHeader(_ recData: Data, fallbackTitle: String) -> MobiHeaderInfo {
        let rec = [UInt8](recData)
        if rec.count < 16 {
            return MobiHeaderInfo(
                compression: 1, textRecordCount: 0, encryptionType: 0, encoding: 65001,
                firstImageIndex: -1, fullTitle: fallbackTitle, author: "",
                coverOffset: nil, thumbOffset: nil, kf8BoundaryRecord: nil,
                huffRecordOffset: 0, huffRecordCount: 0, extraDataFlags: 0
            )
        }
        let compression = readU16(rec, 0)
        let textRecordCount = readU16(rec, 8)
        let encryptionType = readU16(rec, 12)

        var encoding = 65001
        var firstImageIndex = -1
        var fullTitle = fallbackTitle
        var author = ""
        var coverOffset: Int?
        var thumbOffset: Int?
        var kf8Boundary: Int?
        var huffOffset = 0
        var huffCount = 0
        var extraDataFlags = 0

        if rec.count >= 36 && String(bytes: rec[16..<20], encoding: .ascii) == "MOBI" {
            let mobiHeaderLen = Int(readU32(rec, 20))
            encoding = Int(readU32(rec, 28))
            let strEnc: String.Encoding = (encoding == 1252) ? .windowsCP1252 : .utf8

            if rec.count >= 92 {
                let fnOffset = Int(readU32(rec, 84))
                let fnLen = Int(readU32(rec, 88))
                if fnOffset > 0 && fnLen > 0 && fnOffset + fnLen <= rec.count {
                    let slice = Data(rec[fnOffset..<(fnOffset + fnLen)])
                    if let t = String(data: slice, encoding: strEnc)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty {
                        fullTitle = t
                    }
                }
            }
            if rec.count >= 112 {
                let fii = readU32(rec, 108)
                if fii >= 1 && fii <= 1_000_000 { firstImageIndex = Int(fii) }
            }
            if rec.count >= 120 {
                huffOffset = Int(readU32(rec, 112))
                huffCount = Int(readU32(rec, 116))
            }
            if mobiHeaderLen >= 228 && rec.count >= 244 {
                extraDataFlags = Int(readU32(rec, 240))
            }

            let exthStart = 16 + mobiHeaderLen
            if exthStart >= 16 && exthStart + 12 <= rec.count &&
               String(bytes: rec[exthStart..<(exthStart + 4)], encoding: .ascii) == "EXTH" {
                let exthCount = Int(readU32(rec, exthStart + 8))
                var pos = exthStart + 12
                for _ in 0..<exthCount {
                    if pos + 8 > rec.count { break }
                    let recType = Int(readU32(rec, pos))
                    let recLen = Int(readU32(rec, pos + 4))
                    if recLen < 8 || pos + recLen > rec.count { break }
                    let dataStart = pos + 8
                    let dataLen = recLen - 8
                    switch recType {
                    case 100:
                        if author.isEmpty && dataLen > 0 {
                            let slice = Data(rec[dataStart..<(dataStart + dataLen)])
                            author = (String(data: slice, encoding: strEnc) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    case 121:
                        if dataLen == 4 {
                            let boundary = readU32(rec, dataStart)
                            if boundary >= 1 && boundary <= 1_000_000 { kf8Boundary = Int(boundary) }
                        }
                    case 201:
                        if dataLen == 4 {
                            let off = readU32(rec, dataStart)
                            if off <= 1_000_000 { coverOffset = Int(off) }
                        }
                    case 202:
                        if dataLen == 4 {
                            let off = readU32(rec, dataStart)
                            if off <= 1_000_000 { thumbOffset = Int(off) }
                        }
                    case 503:
                        if dataLen > 0 {
                            let slice = Data(rec[dataStart..<(dataStart + dataLen)])
                            if let updated = String(data: slice, encoding: strEnc)?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !updated.isEmpty {
                                fullTitle = updated
                            }
                        }
                    default:
                        break
                    }
                    pos += recLen
                }
            }
        }

        return MobiHeaderInfo(
            compression: compression,
            textRecordCount: textRecordCount,
            encryptionType: encryptionType,
            encoding: encoding,
            firstImageIndex: firstImageIndex,
            fullTitle: fullTitle,
            author: author,
            coverOffset: coverOffset,
            thumbOffset: thumbOffset,
            kf8BoundaryRecord: kf8Boundary,
            huffRecordOffset: huffOffset,
            huffRecordCount: huffCount,
            extraDataFlags: extraDataFlags
        )
    }

    private static func stripTrailingData(_ recData: Data, flags: Int) -> Data {
        if flags == 0 || recData.isEmpty { return recData }
        let rec = [UInt8](recData)
        var end = rec.count
        var bit = 1
        while bit <= 15 && end > 0 {
            if (flags & (1 << bit)) != 0 {
                let trailSize = readBackwardVarInt(rec, endExclusive: end)
                if trailSize >= 1 && trailSize <= end {
                    end -= trailSize
                }
            }
            bit += 1
        }
        if (flags & 1) != 0 && end > 0 {
            let multibyteCount = Int(rec[end - 1] & 0x03) + 1
            if multibyteCount <= end {
                end -= multibyteCount
            }
        }
        return end == rec.count ? recData : recData.prefix(max(0, end))
    }

    private static func readBackwardVarInt(_ data: [UInt8], endExclusive: Int) -> Int {
        var value = 0
        var shift = 0
        var pos = endExclusive - 1
        let minPos = max(0, endExclusive - 4)
        while pos >= minPos {
            let b = Int(data[pos])
            value |= (b & 0x7F) << shift
            shift += 7
            if (b & 0x80) != 0 { break }
            pos -= 1
        }
        return value
    }

    // MARK: - PalmDOC LZ77 & HUFF/CDIC Decompression

    private static func decompressPalmDoc(_ data: Data) -> Data {
        let src = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(max(4096, src.count * 2))

        var i = 0
        let n = src.count
        while i < n {
            let c = Int(src[i])
            i += 1
            if c == 0x00 || (c >= 0x09 && c <= 0x7F) {
                out.append(UInt8(c))
            } else if c >= 0x01 && c <= 0x08 {
                let count = min(c, n - i)
                if count > 0 {
                    out.append(contentsOf: src[i..<(i + count)])
                    i += count
                }
            } else if c >= 0x80 && c <= 0xBF {
                if i >= n { break }
                let c2 = Int(src[i])
                i += 1
                let combined = (c << 8) | c2
                let dist = (combined >> 3) & 0x07FF
                let len = (combined & 0x07) + 3
                if dist >= 1 && dist <= out.count {
                    for _ in 0..<len {
                        let b = out[out.count - dist]
                        out.append(b)
                    }
                }
            } else {
                out.append(0x20)
                out.append(UInt8(c ^ 0x80))
            }
        }
        return Data(out)
    }

    private final class HuffCdicDecoder {
        let dict1: [UInt32]
        let minCode: [UInt64]
        let maxCode: [UInt64]
        let dictionary: [([UInt8], Bool)]

        init(dict1: [UInt32], minCode: [UInt64], maxCode: [UInt64], dictionary: [([UInt8], Bool)]) {
            self.dict1 = dict1
            self.minCode = minCode
            self.maxCode = maxCode
            self.dictionary = dictionary
        }

        func decompress(_ data: Data) -> Data {
            var out: [UInt8] = []
            out.reserveCapacity(data.count * 2)
            decodeSlice([UInt8](data), out: &out, depth: 0)
            return Data(out)
        }

        private func decodeSlice(_ data: [UInt8], out: inout [UInt8], depth: Int) {
            if depth > 32 || data.isEmpty { return }
            var bitsLeft = data.count * 8
            var pos = 0
            var x = readU64Padded(data, offset: 0)
            var n = 32

            while true {
                if n <= 0 {
                    pos += 4
                    x = readU64Padded(data, offset: pos)
                    n += 32
                }
                let code = (x >> UInt64(n)) & 0xFFFFFFFF
                let t1 = dict1[Int((code >> 24) & 0xFF)]
                var codeLen = Int(t1 & 0x1F)
                let isTerm = (t1 & 0x80) != 0
                var maxC = UInt64((t1 >> 8) & 0xFFFFFF)

                if !isTerm {
                    while codeLen < 32 && code < minCode[codeLen] {
                        codeLen += 1
                    }
                    if codeLen >= 33 || codeLen <= 0 { break }
                    maxC = maxCode[codeLen]
                }

                if codeLen <= 0 || codeLen > 32 { break }
                n -= codeLen
                bitsLeft -= codeLen
                if bitsLeft < 0 || maxC < code { break }

                let r = Int((maxC - code) >> UInt64(32 - codeLen))
                if r < 0 || r >= dictionary.count { break }
                let (slice, flag) = dictionary[r]
                if !flag {
                    decodeSlice(slice, out: &out, depth: depth + 1)
                } else {
                    out.append(contentsOf: slice)
                }
            }
        }

        private func readU64Padded(_ data: [UInt8], offset: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 {
                let idx = offset + k
                let b: UInt64 = (idx >= 0 && idx < data.count) ? UInt64(data[idx]) : 0
                v = (v << 8) | b
            }
            return v
        }
    }

    private static func buildHuffCdicDecoder(
        _ fh: FileHandle,
        pdb: PdbInfo,
        baseRecord: Int,
        header: MobiHeaderInfo
    ) -> HuffCdicDecoder? {
        let huffIdx = baseRecord + header.huffRecordOffset
        guard header.huffRecordCount >= 2,
              huffIdx >= 0 && huffIdx < pdb.recordOffsets.count else { return nil }
        let huff = [UInt8](readRecord(fh, pdb: pdb, index: huffIdx))
        guard huff.count >= 24,
              String(bytes: huff[0..<4], encoding: .ascii) == "HUFF" else { return nil }

        let off1 = Int(readU32(huff, 16))
        let off2 = Int(readU32(huff, 20))
        guard off1 >= 0, off2 >= 0,
              off1 + 256 * 4 <= huff.count,
              off2 + 64 * 4 <= huff.count else { return nil }

        let dict1 = (0..<256).map { i in readU32(huff, off1 + i * 4) }
        var minCode = [UInt64](repeating: 0, count: 33)
        var maxCode = [UInt64](repeating: 0, count: 33)
        for codelen in 1...32 {
            let idx = (codelen - 1) * 2
            let cMin = UInt64(readU32(huff, off2 + idx * 4))
            let cMax = UInt64(readU32(huff, off2 + (idx + 1) * 4))
            let shift = UInt64(32 - codelen)
            minCode[codelen] = (cMin << shift) & 0xFFFFFFFF
            maxCode[codelen] = (((cMax + 1) << shift) &- 1) & 0xFFFFFFFF
        }

        var dictionary: [([UInt8], Bool)] = []
        for k in 1..<header.huffRecordCount {
            let cdicIdx = huffIdx + k
            if cdicIdx < 0 || cdicIdx >= pdb.recordOffsets.count { break }
            let cdic = [UInt8](readRecord(fh, pdb: pdb, index: cdicIdx))
            if cdic.count < 16 || String(bytes: cdic[0..<4], encoding: .ascii) != "CDIC" { continue }
            let phrases = Int(readU32(cdic, 8))
            let bits = Int(readU32(cdic, 12))
            guard bits >= 0 && bits <= 24 else { continue }
            let count = min(1 << bits, max(0, phrases - dictionary.count))
            for i in 0..<count {
                let ptrPos = 16 + i * 2
                if ptrPos + 2 > cdic.count { break }
                let entryOff = 16 + readU16(cdic, ptrPos)
                if entryOff + 2 > cdic.count { break }
                let blen = readU16(cdic, entryOff)
                let sliceLen = blen & 0x7FFF
                let flag = (blen & 0x8000) != 0
                let start = entryOff + 2
                let end = min(start + sliceLen, cdic.count)
                dictionary.append((Array(cdic[start..<end]), flag))
            }
        }
        return HuffCdicDecoder(dict1: dict1, minCode: minCode, maxCode: maxCode, dictionary: dictionary)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func readU16(_ b: [UInt8], _ off: Int) -> Int {
        (Int(b[off]) << 8) | Int(b[off + 1])
    }

    private static func readU32(_ b: [UInt8], _ off: Int) -> UInt32 {
        (UInt32(b[off]) << 24) |
        (UInt32(b[off + 1]) << 16) |
        (UInt32(b[off + 2]) << 8) |
        UInt32(b[off + 3])
    }
}
