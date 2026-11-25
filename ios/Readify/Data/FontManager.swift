import CoreFoundation
import CoreText
import Foundation
import UIKit

enum FontManager {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    private static let lock = NSLock()
    private static var registeredFontPostScriptNames: [String: String] = [:]

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var publicFontsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Fonts", isDirectory: true)
        ensureFontsDirectoryInitialized(dir)
        return dir
    }

    private static func ensureFontsDirectoryInitialized(_ dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let readmeURL = dir.appendingPathComponent("字體放入此資料夾即可自動讀取.txt")
        if !fm.fileExists(atPath: readmeURL.path) {
            let guide = """
            將 .ttf / .otf / .ttc 字體檔案放入此「Fonts」資料夾（可透過 iOS/iPadOS「檔案」App → 我的 iPhone/iPad → Readify → Fonts，或透過 Mac Finder 檔案共享放入），
            Readify 閱讀器即會自動掃描並顯示字體的真實繁體中文名稱。
            """
            try? guide.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    static func resolveFontFileURL(_ pathOrRelative: String?) -> URL? {
        guard let raw = pathOrRelative, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let fm = FileManager.default
        if raw.hasPrefix("/") {
            if fm.fileExists(atPath: raw) {
                return URL(fileURLWithPath: raw)
            }
            // Recover across iOS container UUID changes if stored path was inside Documents/
            if let range = raw.range(of: "/Documents/") {
                let rel = String(raw[range.upperBound...])
                let candidate = documentsDirectory.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        } else {
            let candidate = documentsDirectory.appendingPathComponent(raw)
            return fm.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    static func makePortablePath(_ fileURL: URL) -> String {
        let docPath = documentsDirectory.standardizedFileURL.path
        let targetPath = fileURL.standardizedFileURL.path
        if targetPath.hasPrefix(docPath + "/") {
            return String(targetPath.dropFirst(docPath.count + 1))
        }
        return targetPath
    }

    static func importFontFiles(_ urls: [URL]) -> Int {
        let destDir = publicFontsDirectory
        let fm = FileManager.default
        var imported = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            guard fontExtensions.contains(ext) else { continue }
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            if (try? fm.copyItem(at: url, to: dest)) != nil {
                imported += 1
            }
        }
        return imported
    }

    static func scanAvailableFonts(customFolderBookmark: String?) -> [LocalFontItem] {
        var results: [String: LocalFontItem] = [:]

        // 1. Scan Documents/Fonts (visible in iOS Files app)
        scanDirectoryRecursively(
            dir: publicFontsDirectory,
            sourceLabel: "Readify/Fonts",
            out: &results,
            maxDepth: 2
        )

        // 2. Also scan Documents root in case user dropped fonts directly in Readify folder
        scanDirectoryRecursively(
            dir: documentsDirectory,
            sourceLabel: "Readify",
            out: &results,
            maxDepth: 0
        )

        // 3. Optional user-picked external folder via security-scoped bookmark
        if let bookmarkB64 = customFolderBookmark,
           let bookmarkData = Data(base64Encoded: bookmarkB64) {
            var isStale = false
            if let folderURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let scoped = folderURL.startAccessingSecurityScopedResource()
                defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

                // Copy discovered external fonts into Documents/Fonts cache or scan directly if readable
                scanExternalBookmarkFolder(folderURL: folderURL, out: &results)
            }
        }

        return results.values.sorted {
            let cmp = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.pathOrUri < $1.pathOrUri
        }
    }

    private static func scanExternalBookmarkFolder(
        folderURL: URL,
        out: inout [String: LocalFontItem]
    ) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let importedCacheDir = publicFontsDirectory.appendingPathComponent("Imported", isDirectory: true)
        try? fm.createDirectory(at: importedCacheDir, withIntermediateDirectories: true)

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard fontExtensions.contains(ext) else { continue }
            let cachedURL = importedCacheDir.appendingPathComponent(fileURL.lastPathComponent)
            if !fm.fileExists(atPath: cachedURL.path) {
                try? fm.copyItem(at: fileURL, to: cachedURL)
            }
            let target = fm.fileExists(atPath: cachedURL.path) ? cachedURL : fileURL
            let portable = makePortablePath(target)
            let dedupKey = portable.lowercased()
            if out[dedupKey] != nil { continue }
            let displayName = parseFontDisplayName(fileURL: target)
                ?? target.deletingPathExtension().lastPathComponent
            out[dedupKey] = LocalFontItem(
                displayName: displayName,
                pathOrUri: portable,
                sourceLabel: "自訂資料夾"
            )
        }
    }

    private static func scanDirectoryRecursively(
        dir: URL,
        sourceLabel: String,
        out: inout [String: LocalFontItem],
        maxDepth: Int
    ) {
        guard maxDepth >= 0 else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                let name = child.lastPathComponent
                if name != "Books" && name != "Covers" && name != "Inbox" {
                    scanDirectoryRecursively(dir: child, sourceLabel: sourceLabel, out: &out, maxDepth: maxDepth - 1)
                }
            } else if values?.isRegularFile == true {
                let ext = child.pathExtension.lowercased()
                let size = values?.fileSize ?? 0
                guard fontExtensions.contains(ext), size > 1024 else { continue }
                let portable = makePortablePath(child)
                let dedupKey = portable.lowercased()
                if out[dedupKey] != nil { continue }
                let fontName = parseFontDisplayName(fileURL: child)
                    ?? child.deletingPathExtension().lastPathComponent
                out[dedupKey] = LocalFontItem(
                    displayName: fontName,
                    pathOrUri: portable,
                    sourceLabel: sourceLabel
                )
            }
        }
    }

    static func resolveReaderFont(
        size: CGFloat,
        bold: Bool,
        customFontPath: String?
    ) -> (font: UIFont, needsSyntheticBold: Bool) {
        if let url = resolveFontFileURL(customFontPath),
           let psName = registerAndGetPostScriptName(for: url),
           let baseCustom = UIFont(name: psName, size: size) {
            if bold {
                if let boldDesc = baseCustom.fontDescriptor.withSymbolicTraits(.traitBold),
                   boldDesc.postscriptName != baseCustom.fontDescriptor.postscriptName {
                    return (UIFont(descriptor: boldDesc, size: size), false)
                }
                return (baseCustom, true)
            }
            return (baseCustom, false)
        }

        // Default serif CJK font (Songti / Hiragino Mincho / System Serif fallback)
        let serifCandidates = bold
            ? ["STSongti-TC-Bold", "HiraMinProN-W6", "Songti TC"]
            : ["STSongti-TC-Regular", "HiraMinProN-W3", "Songti TC"]
        for name in serifCandidates {
            if let f = UIFont(name: name, size: size) {
                if bold && !name.contains("Bold") && !name.contains("W6") {
                    return (f, true)
                }
                return (f, false)
            }
        }

        let baseSys = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if let serifDesc = baseSys.fontDescriptor.withDesign(.serif) {
            return (UIFont(descriptor: serifDesc, size: size), false)
        }
        return (baseSys, false)
    }

    private static func registerAndGetPostScriptName(for url: URL) -> String? {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = registeredFontPostScriptNames[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let psName = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else {
            return nil
        }

        lock.lock()
        registeredFontPostScriptNames[key] = psName
        lock.unlock()
        return psName
    }

    // MARK: - OpenType / TrueType / TTC `name` Table Parser

    static func parseFontDisplayName(fileURL: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }

        let fileLen = (try? fh.seekToEnd()) ?? 0
        guard fileLen >= 12 else { return nil }

        try? fh.seek(toOffset: 0)
        guard let header = try? fh.read(upToCount: Int(min(16, fileLen))), header.count >= 12 else {
            return nil
        }

        let tag = String(bytes: header.prefix(4), encoding: .ascii) ?? ""
        let sfntOffset: UInt64
        if tag == "ttcf" {
            guard header.count >= 16 else { return nil }
            let numFonts = readUInt32(header, 8)
            guard numFonts >= 1 else { return nil }
            sfntOffset = UInt64(readUInt32(header, 12))
        } else {
            sfntOffset = 0
        }

        guard sfntOffset + 12 <= fileLen else { return nil }
        try? fh.seek(toOffset: sfntOffset)
        guard let sfntHeader = try? fh.read(upToCount: 12), sfntHeader.count == 12 else { return nil }
        let numTables = Int(readUInt16(sfntHeader, 4))
        guard numTables > 0 && numTables <= 512 else { return nil }

        let dirLen = numTables * 16
        guard sfntOffset + 12 + UInt64(dirLen) <= fileLen else { return nil }
        guard let dirBytes = try? fh.read(upToCount: dirLen), dirBytes.count == dirLen else { return nil }

        var nameTableOffset: UInt64?
        var nameTableLength: Int = 0
        for i in 0..<numTables {
            let base = i * 16
            if dirBytes[base] == 0x6E && dirBytes[base + 1] == 0x61 &&
               dirBytes[base + 2] == 0x6D && dirBytes[base + 3] == 0x65 {
                nameTableOffset = UInt64(readUInt32(dirBytes, base + 8))
                nameTableLength = Int(readUInt32(dirBytes, base + 12))
                break
            }
        }

        guard let offset = nameTableOffset,
              nameTableLength > 6,
              nameTableLength <= 2 * 1024 * 1024,
              offset + UInt64(nameTableLength) <= fileLen else {
            return nil
        }

        try? fh.seek(toOffset: offset)
        guard let nameTable = try? fh.read(upToCount: nameTableLength), nameTable.count == nameTableLength else {
            return nil
        }
        return extractBestNameFromTable(nameTable)
    }

    private static func extractBestNameFromTable(_ table: Data) -> String? {
        guard table.count >= 6 else { return nil }
        let count = Int(readUInt16(table, 2))
        let stringOffset = Int(readUInt16(table, 4))

        var bestScore = -1
        var bestName: String?

        for i in 0..<count {
            let rec = 6 + i * 12
            if rec + 12 > table.count { break }

            let platformId = Int(readUInt16(table, rec))
            let encodingId = Int(readUInt16(table, rec + 2))
            let languageId = Int(readUInt16(table, rec + 4))
            let nameId = Int(readUInt16(table, rec + 6))
            let length = Int(readUInt16(table, rec + 8))
            let offset = Int(readUInt16(table, rec + 10))

            if nameId != 4 && nameId != 16 && nameId != 1 { continue }
            let strStart = stringOffset + offset
            let strEnd = strStart + length
            if length <= 0 || strStart < 0 || strEnd > table.count { continue }

            let slice = table.subdata(in: strStart..<strEnd)
            guard let rawDecoded = decodeNameRecord(slice, platformId: platformId, encodingId: encodingId) else {
                continue
            }
            let decoded = rawDecoded
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if decoded.isEmpty { continue }

            let langScore: Int
            switch platformId {
            case 3:
                switch languageId {
                case 0x0404: langScore = 100
                case 0x0C04, 0x1404: langScore = 92
                case 0x0804, 0x1004: langScore = 80
                case 0x0409: langScore = 50
                default: langScore = 30
                }
            case 1:
                switch languageId {
                case 19: langScore = 95
                case 33: langScore = 75
                case 0: langScore = 40
                default: langScore = 20
                }
            case 0:
                langScore = 45
            default:
                langScore = 10
            }

            let idScore: Int
            switch nameId {
            case 4: idScore = 3
            case 16: idScore = 2
            default: idScore = 1
            }

            let totalScore = langScore * 10 + idScore
            if totalScore > bestScore {
                bestScore = totalScore
                bestName = decoded
            }
        }
        return bestName
    }

    private static func decodeNameRecord(_ data: Data, platformId: Int, encodingId: Int) -> String? {
        switch platformId {
        case 0, 3:
            return String(data: data, encoding: .utf16BigEndian)
        case 1:
            let cfEnc: CFStringEncoding? = {
                switch encodingId {
                case 2: return CFStringEncoding(CFStringEncodings.big5.rawValue)
                case 25: return CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                default: return nil
                }
            }()
            if let cfEnc {
                let nsEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
                if let str = String(data: data, encoding: nsEnc) {
                    return str
                }
            }
            return String(data: data, encoding: .isoLatin1)
        default:
            return nil
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return (b0 << 8) | b1
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
