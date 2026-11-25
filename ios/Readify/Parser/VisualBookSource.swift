import Foundation
import ImageIO
import PDFKit
import UIKit
import Unrar
import ZIPFoundation

protocol VisualBookSource: AnyObject {
    var pageCount: Int { get }
    var defaultRtl: Bool { get }
    var isPdf: Bool { get }
    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage?
    func close()
}

enum VisualBookSourceFactory {
    static func open(book: BookItem, resolvedFileURL: URL) async -> VisualBookSource {
        await Task.detached(priority: .userInitiated) {
            switch book.format {
            case .PDF:
                return PdfVisualSource(fileURL: resolvedFileURL)
            case .EPUB:
                let info = BookParser.inspectEpubComic(fileURL: resolvedFileURL, fallbackTitle: book.title)
                return EpubComicSource(fileURL: resolvedFileURL, imagePaths: info.imagePaths, defaultRtl: info.isRtl)
            case .CBZ, .ZIP:
                return ZipComicSource(fileURL: resolvedFileURL)
            case .CBR:
                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let cacheDir = cachesDir.appendingPathComponent("cbr_cache/\(book.id)", isDirectory: true)
                if let rarSource = try? RarComicSource(fileURL: resolvedFileURL, cacheDir: cacheDir),
                   rarSource.pageCount > 0 {
                    return rarSource
                }
                return ZipComicSource(fileURL: resolvedFileURL)
            case .MOBI, .AZW3:
                let idx = MobiAzw3Parser.getImageIndex(fileURL: resolvedFileURL)
                return MobiComicSource(fileURL: resolvedFileURL, imageRecordIndices: idx.imageRecordIndices)
            case .TXT:
                return EmptyVisualSource()
            }
        }.value
    }

    static func extractZipComicCover(fileURL: URL) -> Data? {
        guard let archive = try? ZIPFoundation.Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else { return nil }
        let imageEntries = archive
            .filter { $0.type == .file && NaturalSort.isSupportedImageName($0.path) }
            .sorted { NaturalSort.lessThan($0.path, $1.path) }
        guard let first = imageEntries.first else { return nil }
        return BookParser.readEntryData(archive, entry: first)
    }

    static func extractRarComicCover(fileURL: URL) -> Data? {
        if let archive = try? Unrar.Archive(fileURL: fileURL),
           let entries = try? archive.entries() {
            let sorted = entries
                .filter { !$0.directory && NaturalSort.isSupportedImageName($0.fileName) }
                .sorted { NaturalSort.lessThan($0.fileName, $1.fileName) }
            if let first = sorted.first,
               let data = try? archive.extract(first),
               !data.isEmpty {
                return data
            }
        }
        return extractZipComicCover(fileURL: fileURL)
    }

    static func decodeDownsampledImage(data: Data, targetMaxDim: Int) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts as CFDictionary) else {
            return UIImage(data: data)
        }
        let maxPixel = max(600, targetMaxDim)
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            return UIImage(cgImage: cgImg)
        }
        return UIImage(data: data)
    }

    static func decodeDownsampledImage(fileURL: URL, targetMaxDim: Int) -> UIImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, srcOpts as CFDictionary) else {
            return UIImage(contentsOfFile: fileURL.path)
        }
        let maxPixel = max(600, targetMaxDim)
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            return UIImage(cgImage: cgImg)
        }
        return UIImage(contentsOfFile: fileURL.path)
    }
}

private final class EmptyVisualSource: VisualBookSource {
    let pageCount: Int = 0
    let defaultRtl: Bool = true
    let isPdf: Bool = false
    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage? { nil }
    func close() {}
}

private final class ZipComicSource: VisualBookSource {
    private let archive: ZIPFoundation.Archive?
    private let lock = NSLock()
    private let entries: [ZIPFoundation.Entry]

    let defaultRtl: Bool = true
    let isPdf: Bool = false
    var pageCount: Int { entries.count }

    init(fileURL: URL) {
        let arch = try? ZIPFoundation.Archive(url: fileURL, accessMode: .read, pathEncoding: nil)
        self.archive = arch
        if let arch {
            self.entries = arch
                .filter { $0.type == .file && NaturalSort.isSupportedImageName($0.path) }
                .sorted { NaturalSort.lessThan($0.path, $1.path) }
        } else {
            self.entries = []
        }
    }

    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage? {
        guard pageIndex >= 0 && pageIndex < entries.count, let archive else { return nil }
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let data = self.lock.withLock {
                BookParser.readEntryData(archive, entry: self.entries[pageIndex])
            }
            guard let data else { return nil }
            return VisualBookSourceFactory.decodeDownsampledImage(data: data, targetMaxDim: targetMaxDim)
        }.value
    }

    func close() {}
}

private final class EpubComicSource: VisualBookSource {
    private let archive: ZIPFoundation.Archive?
    private let lock = NSLock()
    private let orderedEntries: [ZIPFoundation.Entry]

    let defaultRtl: Bool
    let isPdf: Bool = false
    var pageCount: Int { orderedEntries.count }

    init(fileURL: URL, imagePaths: [String], defaultRtl: Bool) {
        self.defaultRtl = defaultRtl
        let arch = try? ZIPFoundation.Archive(url: fileURL, accessMode: .read, pathEncoding: nil)
        self.archive = arch
        if let arch {
            var map: [String: ZIPFoundation.Entry] = [:]
            for e in arch where e.type == .file {
                map[e.path] = e
                map[e.path.lowercased()] = e
            }
            self.orderedEntries = imagePaths.compactMap { p in
                map[p] ?? map[p.lowercased()]
            }
        } else {
            self.orderedEntries = []
        }
    }

    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage? {
        guard pageIndex >= 0 && pageIndex < orderedEntries.count, let archive else { return nil }
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let data = self.lock.withLock {
                BookParser.readEntryData(archive, entry: self.orderedEntries[pageIndex])
            }
            guard let data else { return nil }
            return VisualBookSourceFactory.decodeDownsampledImage(data: data, targetMaxDim: targetMaxDim)
        }.value
    }

    func close() {}
}

private final class RarComicSource: VisualBookSource {
    private let extractedFiles: [URL]
    let defaultRtl: Bool = true
    let isPdf: Bool = false
    var pageCount: Int { extractedFiles.count }

    init(fileURL: URL, cacheDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let marker = cacheDir.appendingPathComponent(".extracted_ok")

        if !fm.fileExists(atPath: marker.path) {
            if let oldFiles = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
                for f in oldFiles { try? fm.removeItem(at: f) }
            }

            let archive = try Unrar.Archive(fileURL: fileURL)
            let entries = try archive.entries()
                .filter { !$0.directory && NaturalSort.isSupportedImageName($0.fileName) }
                .sorted { NaturalSort.lessThan($0.fileName, $1.fileName) }

            for (idx, entry) in entries.enumerated() {
                let ext = URL(fileURLWithPath: entry.fileName).pathExtension.lowercased()
                let safeExt = ext.isEmpty ? "jpg" : ext
                let outURL = cacheDir.appendingPathComponent(String(format: "page_%05d.%@", idx, safeExt))
                if let data = try? archive.extract(entry), !data.isEmpty {
                    try data.write(to: outURL, options: .atomic)
                }
            }
            try "ok".write(to: marker, atomically: true, encoding: .utf8)
        }

        let contents = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        self.extractedFiles = contents
            .filter { !$0.lastPathComponent.hasPrefix(".") && NaturalSort.isSupportedImageName($0.lastPathComponent) }
            .sorted { NaturalSort.lessThan($0.lastPathComponent, $1.lastPathComponent) }
    }

    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage? {
        guard pageIndex >= 0 && pageIndex < extractedFiles.count else { return nil }
        let url = extractedFiles[pageIndex]
        return await Task.detached(priority: .userInitiated) {
            VisualBookSourceFactory.decodeDownsampledImage(fileURL: url, targetMaxDim: targetMaxDim)
        }.value
    }

    func close() {}
}

private final class MobiComicSource: VisualBookSource {
    private let fileURL: URL
    private let imageRecordIndices: [Int]

    let defaultRtl: Bool = true
    let isPdf: Bool = false
    var pageCount: Int { imageRecordIndices.count }

    init(fileURL: URL, imageRecordIndices: [Int]) {
        self.fileURL = fileURL
        self.imageRecordIndices = imageRecordIndices
    }

    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage? {
        guard pageIndex >= 0 && pageIndex < imageRecordIndices.count else { return nil }
        let url = fileURL
        let recIdx = imageRecordIndices[pageIndex]
        return await Task.detached(priority: .userInitiated) {
            guard let data = MobiAzw3Parser.readImageRecordBytes(fileURL: url, recordIndex: recIdx) else {
                return nil
            }
            return VisualBookSourceFactory.decodeDownsampledImage(data: data, targetMaxDim: targetMaxDim)
        }.value
    }

    func close() {}
}

private final class PdfVisualSource: VisualBookSource {
    private let document: PDFDocument?
    private let lock = NSLock()

    let defaultRtl: Bool = false
    let isPdf: Bool = true
    var pageCount: Int { document?.pageCount ?? 0 }

    init(fileURL: URL) {
        self.document = PDFDocument(url: fileURL)
    }

    func renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) async -> UIImage? {
        guard let doc = document, pageIndex >= 0 && pageIndex < doc.pageCount else { return nil }
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            return self.renderPageSync(doc: doc, pageIndex: pageIndex, targetMaxDim: targetMaxDim, autoCrop: autoCrop)
        }.value
    }

    private func renderPageSync(doc: PDFDocument, pageIndex: Int, targetMaxDim: Int, autoCrop: Bool) -> UIImage? {
        lock.withLock {
            guard let page = doc.page(at: pageIndex) else { return nil }
            let rawBounds = page.bounds(for: .mediaBox)
            let rot = ((page.rotation % 360) + 360) % 360
            let isRotated90 = (rot == 90 || rot == 270)
            let pw = max(1, isRotated90 ? rawBounds.height : rawBounds.width)
            let ph = max(1, isRotated90 ? rawBounds.width : rawBounds.height)

            let clampedTarget = CGFloat(min(2400, max(600, targetMaxDim)))
            if !autoCrop {
                let scale = clampedTarget / max(pw, ph)
                let size = CGSize(
                    width: min(2400, max(200, pw * scale)),
                    height: min(2400, max(200, ph * scale))
                )
                return Self.renderFullOpaquePdfPage(page: page, targetSize: size)
            }

            let probeScale = 360.0 / max(pw, ph)
            let probeSize = CGSize(
                width: min(400, max(80, pw * probeScale)),
                height: min(400, max(80, ph * probeScale))
            )
            let probeImg = Self.renderFullOpaquePdfPage(page: page, targetSize: probeSize)
            let cropRatios = probeImg.flatMap { Self.detectContentBounds($0) } ?? (0, 0, 1, 1)

            let (leftR, topR, rightR, bottomR) = cropRatios
            let cropRatioW = max(0.15, rightR - leftR)
            let cropRatioH = max(0.15, bottomR - topR)

            let fullRenderScale = clampedTarget / max(pw * cropRatioW, ph * cropRatioH)
            let fullSize = CGSize(
                width: min(2800, max(240, pw * fullRenderScale)),
                height: min(2800, max(240, ph * fullRenderScale))
            )
            guard let fullImg = Self.renderFullOpaquePdfPage(page: page, targetSize: fullSize),
                  let cgImg = fullImg.cgImage else {
                return probeImg
            }

            let imgW = CGFloat(cgImg.width)
            let imgH = CGFloat(cgImg.height)
            let cropRect = CGRect(
                x: floor(imgW * leftR),
                y: floor(imgH * topR),
                width: ceil(imgW * cropRatioW),
                height: ceil(imgH * cropRatioH)
            ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard cropRect.width >= 32, cropRect.height >= 32,
                  let croppedCG = cgImg.cropping(to: cropRect) else {
                return fullImg
            }
            return UIImage(cgImage: croppedCG)
        }
    }

    private static func renderFullOpaquePdfPage(page: PDFPage, targetSize: CGSize) -> UIImage? {
        let thumb = page.thumbnail(of: targetSize, for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: thumb.size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: thumb.size))
            thumb.draw(in: CGRect(origin: .zero, size: thumb.size))
        }
    }

    private static func detectContentBounds(_ image: UIImage) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 16 && h >= 16 else { return nil }

        let bytesPerRow = w * 4
        var rawPixels = [UInt8](repeating: 255, count: h * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rawPixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1

        let borderX = max(1, Int(Double(w) * 0.01))
        let borderY = max(1, Int(Double(h) * 0.01))

        for y in borderY..<(h - borderY) {
            let rowOff = y * bytesPerRow
            for x in borderX..<(w - borderX) {
                let pxOff = rowOff + x * 4
                let r = rawPixels[pxOff]
                let g = rawPixels[pxOff + 1]
                let b = rawPixels[pxOff + 2]
                if r < 242 || g < 242 || b < 242 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        if maxX <= minX || maxY <= minY { return (0, 0, 1, 1) }

        let padX = Int(Double(w) * 0.025)
        let padY = Int(Double(h) * 0.025)
        let left = CGFloat(max(0, minX - padX)) / CGFloat(w)
        let top = CGFloat(max(0, minY - padY)) / CGFloat(h)
        let right = CGFloat(min(w, maxX + padX)) / CGFloat(w)
        let bottom = CGFloat(min(h, maxY + padY)) / CGFloat(h)

        if (right - left) < 0.15 || (bottom - top) < 0.15 {
            return (0, 0, 1, 1)
        }
        return (left, top, right, bottom)
    }

    func close() {}
}
