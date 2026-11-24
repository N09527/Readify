package com.inkflow.reader.parser

import android.graphics.BitmapFactory
import com.inkflow.reader.model.BookContentType
import com.inkflow.reader.model.Chapter
import com.inkflow.reader.model.ParsedBook
import org.jsoup.Jsoup
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.Charset

data class MobiImageIndex(
    val imageRecordIndices: List<Int>,
    val coverRecordIndex: Int?
)

/**
 * Pure-Kotlin parser for DRM-free Kindle MOBI and AZW3 (KF8) files.
 * Fixes & capabilities:
 *  - PalmDB container parsing & combo MOBI+KF8 BOUNDARY handling (EXTH 121)
 *  - EXTH 201 (CoverOffset) + EXTH 202 (ThumbOffset) + full-PDB decodable image fallback
 *  - Supports JPEG, PNG, GIF, WebP, BMP, and Kindle HD CRES image containers
 *  - Uncompressed (1), PalmDOC LZ77 (2), and HUFF/CDIC (17480) decompression
 */
object MobiAzw3Parser {

    private data class PdbInfo(
        val pdbTitle: String,
        val recordOffsets: LongArray,
        val fileLength: Long
    )

    private data class MobiHeaderInfo(
        val compression: Int,
        val textRecordCount: Int,
        val encryptionType: Int,
        val encoding: Int,
        val firstImageIndex: Int,
        val fullTitle: String,
        val author: String,
        val coverOffset: Int?,
        val thumbOffset: Int?,
        val kf8BoundaryRecord: Int?,
        val huffRecordOffset: Int,
        val huffRecordCount: Int,
        val extraDataFlags: Int
    )

    private data class Kf8Resolved(
        val baseRecord: Int,
        val header: MobiHeaderInfo
    )

    fun parseMetadataAndCover(file: File, fallbackTitle: String): ParsedBook {
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                val pdb = readPdbInfo(raf)
                if (pdb.recordOffsets.isEmpty()) {
                    return ParsedBook(fallbackTitle, "Kindle 電子書", emptyList())
                }
                val rec0 = readRecord(raf, pdb, 0)
                val header0 = parseMobiHeader(rec0, pdb.pdbTitle.ifBlank { fallbackTitle })
                val kf8 = resolveKf8Header(raf, pdb, header0)

                val imgIndex = scanAllImageRecords(raf, pdb, header0, kf8)
                val coverBytes = resolveBestCoverBytes(raf, pdb, header0, kf8, imgIndex)

                val bestTitle = kf8?.header?.fullTitle?.takeIf { it.isNotBlank() }
                    ?: header0.fullTitle.ifBlank { fallbackTitle }
                val bestAuthor = kf8?.header?.author?.takeIf { it.isNotBlank() }
                    ?: header0.author.ifBlank { "Kindle 電子書" }

                val contentType = detectContentTypeQuick(raf, pdb, header0, imgIndex)

                ParsedBook(
                    title = bestTitle,
                    author = bestAuthor,
                    chapters = emptyList(),
                    coverBytes = coverBytes,
                    contentType = contentType
                )
            }
        }.getOrElse {
            ParsedBook(fallbackTitle, "Kindle 電子書", emptyList())
        }
    }

    fun parseFullBook(file: File, fallbackTitle: String): ParsedBook {
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                val pdb = readPdbInfo(raf)
                if (pdb.recordOffsets.isEmpty()) {
                    return ParsedBook(fallbackTitle, "Kindle 電子書", listOf(Chapter(0, fallbackTitle, "無法解析此 Kindle 檔案：PDB 結構無效。")))
                }

                val rec0 = readRecord(raf, pdb, 0)
                val header0 = parseMobiHeader(rec0, pdb.pdbTitle.ifBlank { fallbackTitle })

                if (header0.encryptionType != 0) {
                    return ParsedBook(
                        title = header0.fullTitle.ifBlank { fallbackTitle },
                        author = header0.author.ifBlank { "Kindle 電子書" },
                        chapters = listOf(
                            Chapter(
                                0,
                                "DRM 加密檔案",
                                "此 Kindle 檔案（MOBI/AZW3）受到 DRM 加密保護（encryptionType=${header0.encryptionType}），無法直接讀取內文。請匯入無 DRM 加密的檔案。"
                            )
                        )
                    )
                }

                val kf8 = resolveKf8Header(raf, pdb, header0)
                val baseRecord = kf8?.baseRecord ?: 0
                val activeHeader = kf8?.header?.copy(
                    fullTitle = kf8.header.fullTitle.ifBlank { header0.fullTitle },
                    author = kf8.header.author.ifBlank { header0.author }
                ) ?: header0

                if (activeHeader.encryptionType != 0) {
                    return ParsedBook(
                        title = activeHeader.fullTitle.ifBlank { fallbackTitle },
                        author = activeHeader.author.ifBlank { "Kindle 電子書" },
                        chapters = listOf(Chapter(0, "DRM 加密檔案", "此 AZW3 (KF8) 檔案受到 DRM 加密保護，無法直接讀取內文。"))
                    )
                }

                val huffDecoder = if (activeHeader.compression == 17480) {
                    buildHuffCdicDecoder(raf, pdb, baseRecord, activeHeader)
                } else null

                val htmlBytes = ByteArrayOutputStream()
                val textCount = activeHeader.textRecordCount.coerceAtMost(pdb.recordOffsets.size - baseRecord - 1)
                for (i in 1..textCount) {
                    val recIdx = baseRecord + i
                    if (recIdx >= pdb.recordOffsets.size) break
                    var rawRec = readRecord(raf, pdb, recIdx)
                    rawRec = stripTrailingData(rawRec, activeHeader.extraDataFlags)
                    val decompressed = when (activeHeader.compression) {
                        1 -> rawRec
                        2 -> decompressPalmDoc(rawRec)
                        17480 -> huffDecoder?.decompress(rawRec) ?: ByteArray(0)
                        else -> rawRec
                    }
                    htmlBytes.write(decompressed)
                }

                val charset = when (activeHeader.encoding) {
                    1252 -> Charset.forName("windows-1252")
                    else -> Charsets.UTF_8
                }
                val rawHtml = String(htmlBytes.toByteArray(), charset)
                val chapters = splitHtmlIntoChapters(rawHtml, activeHeader.fullTitle.ifBlank { fallbackTitle })

                val imgIndex = scanAllImageRecords(raf, pdb, header0, kf8)
                val coverBytes = resolveBestCoverBytes(raf, pdb, header0, kf8, imgIndex)

                val totalChars = chapters.sumOf { it.content.length }
                val isComic = imgIndex.imageRecordIndices.size >= 4 && totalChars < 350

                ParsedBook(
                    title = activeHeader.fullTitle.ifBlank { fallbackTitle },
                    author = activeHeader.author.ifBlank { "Kindle 電子書" },
                    chapters = if (chapters.isNotEmpty()) chapters else listOf(
                        Chapter(0, activeHeader.fullTitle.ifBlank { fallbackTitle }, "（未能從此 Kindle 檔案中擷取到文字內容）")
                    ),
                    coverBytes = coverBytes,
                    contentType = if (isComic) BookContentType.COMIC else BookContentType.TEXT
                )
            }
        }.getOrElse { err ->
            ParsedBook(
                title = fallbackTitle,
                author = "Kindle 電子書",
                chapters = listOf(Chapter(0, fallbackTitle, "解析 Kindle 檔案時發生錯誤：${err.message}"))
            )
        }
    }

    fun getImageIndex(file: File): MobiImageIndex {
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                val pdb = readPdbInfo(raf)
                val rec0 = readRecord(raf, pdb, 0)
                val header0 = parseMobiHeader(rec0, pdb.pdbTitle)
                val kf8 = resolveKf8Header(raf, pdb, header0)
                scanAllImageRecords(raf, pdb, header0, kf8)
            }
        }.getOrDefault(MobiImageIndex(emptyList(), null))
    }

    fun readImageRecordBytes(file: File, recordIndex: Int): ByteArray? {
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                val pdb = readPdbInfo(raf)
                if (recordIndex !in pdb.recordOffsets.indices) return@use null
                val raw = readRecord(raf, pdb, recordIndex)
                extractImagePayload(raw) ?: raw
            }
        }.getOrNull()
    }

    /**
     * Resolves KF8 Record 0 in combo MOBI+KF8 files.
     * EXTH 121 may point to the "BOUNDARY" marker record itself (meaning KF8 header is at +1)
     * OR directly to the KF8 header record.
     */
    private fun resolveKf8Header(raf: RandomAccessFile, pdb: PdbInfo, header0: MobiHeaderInfo): Kf8Resolved? {
        val boundary = header0.kf8BoundaryRecord ?: return null
        if (boundary !in 1 until pdb.recordOffsets.size) return null

        val recAtBoundary = readRecord(raf, pdb, boundary)
        val isBoundaryMarker = recAtBoundary.size >= 8 &&
            String(recAtBoundary, 0, 8, Charsets.US_ASCII) == "BOUNDARY"

        val actualKf8RecIdx = if (isBoundaryMarker) boundary + 1 else boundary
        if (actualKf8RecIdx !in 1 until pdb.recordOffsets.size) return null

        val kf8Rec = if (isBoundaryMarker) readRecord(raf, pdb, actualKf8RecIdx) else recAtBoundary
        if (kf8Rec.size < 24 || String(kf8Rec, 16, 4, Charsets.US_ASCII) != "MOBI") return null

        val parsed = parseMobiHeader(kf8Rec, header0.fullTitle)
        return Kf8Resolved(actualKf8RecIdx, parsed)
    }

    /**
     * Resolves the highest-priority decodable cover image from EXTH 201 (CoverOffset),
     * EXTH 202 (ThumbOffset), or full PDB image scan fallback.
     */
    private fun resolveBestCoverBytes(
        raf: RandomAccessFile,
        pdb: PdbInfo,
        header0: MobiHeaderInfo,
        kf8: Kf8Resolved?,
        imgIndex: MobiImageIndex
    ): ByteArray? {
        val candidates = LinkedHashSet<Int>()

        fun addCandidate(baseIdx: Int, offset: Int?) {
            if (baseIdx > 0 && offset != null && offset >= 0) {
                val idx = baseIdx + offset
                if (idx in 1 until pdb.recordOffsets.size) {
                    candidates.add(idx)
                }
            }
        }

        // Priority 1: EXTH 201 (Full CoverOffset) from MOBI6 header0 & KF8 header
        addCandidate(header0.firstImageIndex, header0.coverOffset)
        if (kf8 != null) {
            addCandidate(kf8.header.firstImageIndex, kf8.header.coverOffset)
            addCandidate(header0.firstImageIndex, kf8.header.coverOffset)
            if (kf8.header.firstImageIndex > 0) {
                addCandidate(kf8.baseRecord + kf8.header.firstImageIndex, kf8.header.coverOffset)
            }
        }

        // Priority 2: EXTH 202 (ThumbOffset) fallback
        addCandidate(header0.firstImageIndex, header0.thumbOffset)
        if (kf8 != null) {
            addCandidate(kf8.header.firstImageIndex, kf8.header.thumbOffset)
            addCandidate(header0.firstImageIndex, kf8.header.thumbOffset)
        }

        // Test explicit cover candidates first and ensure Android BitmapFactory can decode them
        for (idx in candidates) {
            val raw = readRecord(raf, pdb, idx)
            val payload = extractImagePayload(raw) ?: continue
            val dims = probeImageDimensions(payload)
            if (dims != null && dims.first >= 24 && dims.second >= 24) {
                return payload
            }
        }

        // Priority 3: Fallback across all detected image records in the PDB (prefer >= 100x100 cover-sized image)
        var bestFallback: ByteArray? = null
        var bestArea = 0L
        val maxToProbe = imgIndex.imageRecordIndices.take(40)
        for (idx in maxToProbe) {
            val raw = readRecord(raf, pdb, idx)
            val payload = extractImagePayload(raw) ?: continue
            val dims = probeImageDimensions(payload) ?: continue
            val w = dims.first
            val h = dims.second
            if (w >= 120 && h >= 120) {
                return payload
            }
            val area = w.toLong() * h.toLong()
            if (area > bestArea) {
                bestArea = area
                bestFallback = payload
            }
        }
        return bestFallback
    }

    private fun probeImageDimensions(bytes: ByteArray): Pair<Int, Int>? {
        return runCatching {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            if (opts.outWidth > 0 && opts.outHeight > 0) opts.outWidth to opts.outHeight else null
        }.getOrNull()
    }

    private fun scanAllImageRecords(
        raf: RandomAccessFile,
        pdb: PdbInfo,
        header0: MobiHeaderInfo,
        kf8: Kf8Resolved?
    ): MobiImageIndex {
        // Determine safe earliest index to scan; start from 1 if firstImageIndex is unreliable
        val candidateStarts = listOfNotNull(
            header0.firstImageIndex.takeIf { it in 1 until pdb.recordOffsets.size },
            kf8?.header?.firstImageIndex?.takeIf { it in 1 until pdb.recordOffsets.size },
            (header0.textRecordCount + 1).takeIf { it in 1 until pdb.recordOffsets.size }
        )
        val primaryStart = candidateStarts.minOrNull() ?: 1

        val images = mutableListOf<Int>()
        val probeBuf = ByteArray(48)

        fun scanRange(from: Int, toExclusive: Int) {
            for (i in from until toExclusive) {
                val recLen = recordLength(pdb, i)
                if (recLen < 24) continue
                val toRead = minOf(probeBuf.size, recLen)
                raf.seek(pdb.recordOffsets[i])
                raf.readFully(probeBuf, 0, toRead)
                if (findImageStartOffset(probeBuf, toRead) >= 0) {
                    images.add(i)
                }
            }
        }

        scanRange(primaryStart, pdb.recordOffsets.size)
        // If nothing found after primaryStart, scan earlier records (1 until primaryStart) as well
        if (images.isEmpty() && primaryStart > 1) {
            scanRange(1, primaryStart)
        }

        val explicitCover = header0.coverOffset?.let { off ->
            val idx = header0.firstImageIndex + off
            if (idx in images) idx else null
        } ?: kf8?.header?.coverOffset?.let { off ->
            val idx = kf8.header.firstImageIndex + off
            if (idx in images) idx else null
        }

        return MobiImageIndex(images, explicitCover)
    }

    /**
     * Extracts clean image bytes from a raw PDB record.
     * Handles standard JPEG/PNG/GIF/WebP/BMP as well as Kindle HD "CRES" containers
     * and small leading padding before the magic signature.
     */
    private fun extractImagePayload(raw: ByteArray): ByteArray? {
        if (raw.size < 24) return null
        val startOffset = findImageStartOffset(raw, minOf(raw.size, 64))
        if (startOffset < 0) return null
        return if (startOffset == 0) raw else raw.copyOfRange(startOffset, raw.size)
    }

    private fun findImageStartOffset(buf: ByteArray, limit: Int): Int {
        if (limit < 4) return -1
        // Direct check at offset 0 first (fast path)
        if (matchesImageMagicAt(buf, 0, limit)) return 0

        // Kindle HD image wrapper starts with "CRES" followed by 8-24 byte header then JPEG/PNG/WebP
        val isCres = buf[0] == 'C'.code.toByte() && buf[1] == 'R'.code.toByte() &&
            buf[2] == 'E'.code.toByte() && buf[3] == 'S'.code.toByte()
        val maxScan = if (isCres) minOf(limit - 4, 48) else minOf(limit - 4, 16)
        for (off in 1..maxScan) {
            if (matchesImageMagicAt(buf, off, limit)) {
                return off
            }
        }
        return -1
    }

    private fun matchesImageMagicAt(b: ByteArray, off: Int, limit: Int): Boolean {
        if (off + 4 > limit) return false
        // JPEG: FF D8 FF
        if (b[off] == 0xFF.toByte() && b[off + 1] == 0xD8.toByte() && b[off + 2] == 0xFF.toByte()) return true
        // PNG: 89 50 4E 47
        if (b[off] == 0x89.toByte() && b[off + 1] == 0x50.toByte() && b[off + 2] == 0x4E.toByte() && b[off + 3] == 0x47.toByte()) return true
        // GIF: GIF87a / GIF89a
        if (off + 6 <= limit &&
            b[off] == 'G'.code.toByte() && b[off + 1] == 'I'.code.toByte() && b[off + 2] == 'F'.code.toByte() &&
            b[off + 3] == '8'.code.toByte() && (b[off + 4] == '7'.code.toByte() || b[off + 4] == '9'.code.toByte()) &&
            b[off + 5] == 'a'.code.toByte()
        ) return true
        // WebP: RIFF....WEBP
        if (off + 12 <= limit &&
            b[off] == 'R'.code.toByte() && b[off + 1] == 'I'.code.toByte() && b[off + 2] == 'F'.code.toByte() && b[off + 3] == 'F'.code.toByte() &&
            b[off + 8] == 'W'.code.toByte() && b[off + 9] == 'E'.code.toByte() && b[off + 10] == 'B'.code.toByte() && b[off + 11] == 'P'.code.toByte()
        ) return true
        // BMP: BM + valid DIB header size (12/40/52/56/108/124) at off+14
        if (off + 18 <= limit && b[off] == 'B'.code.toByte() && b[off + 1] == 'M'.code.toByte()) {
            val dibSize = (b[off + 14].toInt() and 0xFF) or
                ((b[off + 15].toInt() and 0xFF) shl 8) or
                ((b[off + 16].toInt() and 0xFF) shl 16) or
                ((b[off + 17].toInt() and 0xFF) shl 24)
            if (dibSize in setOf(12, 40, 52, 56, 108, 124)) return true
        }
        return false
    }

    private fun detectContentTypeQuick(
        raf: RandomAccessFile,
        pdb: PdbInfo,
        header: MobiHeaderInfo,
        imgIndex: MobiImageIndex
    ): BookContentType {
        if (header.encryptionType != 0) return BookContentType.TEXT
        if (imgIndex.imageRecordIndices.size < 6) return BookContentType.TEXT
        val sampleCount = header.textRecordCount.coerceAtMost(3)
        var textChars = 0
        for (i in 1..sampleCount) {
            if (i >= pdb.recordOffsets.size) break
            val rec = stripTrailingData(readRecord(raf, pdb, i), header.extraDataFlags)
            val data = when (header.compression) {
                1 -> rec
                2 -> decompressPalmDoc(rec)
                else -> ByteArray(0)
            }
            if (data.isNotEmpty()) {
                val txt = Jsoup.parse(String(data, Charsets.UTF_8)).text().trim()
                textChars += txt.length
            }
        }
        return if (header.compression != 17480 && textChars < 80 && imgIndex.imageRecordIndices.size >= 8) {
            BookContentType.COMIC
        } else {
            BookContentType.TEXT
        }
    }

    private fun splitHtmlIntoChapters(rawHtml: String, fallbackTitle: String): List<Chapter> {
        val chapters = mutableListOf<Chapter>()
        val pageBreakRegex = Regex("<mbp:pagebreak\\s*/?>", RegexOption.IGNORE_CASE)
        val rawSegments = pageBreakRegex.split(rawHtml)

        val cleanedSegments = mutableListOf<Pair<String, String>>()
        for (seg in rawSegments) {
            if (seg.isBlank()) continue
            val doc = Jsoup.parse(seg)
            val bodyText = BookParser.extractReadableText(doc)
            if (bodyText.isBlank()) continue
            val heading = doc.selectFirst("h1, h2, h3")?.text()?.trim().orEmpty()
                .takeIf { it.isNotBlank() && it.length <= 60 }
                ?: bodyText.lineSequence().firstOrNull()?.take(36).orEmpty()
            cleanedSegments.add(heading to bodyText)
        }

        if (cleanedSegments.size in 2..800) {
            for ((idx, pair) in cleanedSegments.withIndex()) {
                chapters.add(
                    Chapter(
                        index = idx,
                        title = pair.first.ifBlank { "第 ${idx + 1} 章" },
                        content = pair.second
                    )
                )
            }
            return chapters
        }

        val fullDoc = Jsoup.parse(rawHtml)
        val fullText = BookParser.extractReadableText(fullDoc)
        if (fullText.isBlank()) return emptyList()
        return BookParser.splitPlainTextIntoChapters(fullText, fallbackTitle)
    }

    private fun readPdbInfo(raf: RandomAccessFile): PdbInfo {
        val fileLen = raf.length()
        if (fileLen < 78L) return PdbInfo("", LongArray(0), fileLen)
        raf.seek(0L)
        val header = ByteArray(78)
        raf.readFully(header)

        val titleBytes = header.copyOfRange(0, 32)
        val nullIdx = titleBytes.indexOf(0.toByte()).takeIf { it >= 0 } ?: 32
        val pdbTitle = String(titleBytes, 0, nullIdx, Charsets.UTF_8).replace('_', ' ').trim()

        val numRecords = readU16(header, 76)
        val offsets = LongArray(numRecords)
        val entryBuf = ByteArray(8)
        for (i in 0 until numRecords) {
            if (raf.filePointer + 8 > fileLen) break
            raf.readFully(entryBuf)
            offsets[i] = readU32(entryBuf, 0)
        }
        return PdbInfo(pdbTitle, offsets, fileLen)
    }

    private fun recordLength(pdb: PdbInfo, index: Int): Int {
        val start = pdb.recordOffsets[index]
        val end = if (index + 1 < pdb.recordOffsets.size) pdb.recordOffsets[index + 1] else pdb.fileLength
        return (end - start).coerceAtLeast(0L).toInt()
    }

    private fun readRecord(raf: RandomAccessFile, pdb: PdbInfo, index: Int): ByteArray {
        val len = recordLength(pdb, index)
        if (len <= 0) return ByteArray(0)
        val buf = ByteArray(len)
        raf.seek(pdb.recordOffsets[index])
        raf.readFully(buf)
        return buf
    }

    private fun parseMobiHeader(rec: ByteArray, fallbackTitle: String): MobiHeaderInfo {
        if (rec.size < 16) {
            return MobiHeaderInfo(1, 0, 0, 65001, -1, fallbackTitle, "", null, null, null, 0, 0, 0)
        }
        val compression = readU16(rec, 0)
        val textRecordCount = readU16(rec, 8)
        val encryptionType = readU16(rec, 12)

        var encoding = 65001
        var firstImageIndex = -1
        var fullTitle = fallbackTitle
        var author = ""
        var coverOffset: Int? = null
        var thumbOffset: Int? = null
        var kf8Boundary: Int? = null
        var huffOffset = 0
        var huffCount = 0
        var extraDataFlags = 0

        if (rec.size >= 36 && String(rec, 16, 4, Charsets.US_ASCII) == "MOBI") {
            val mobiHeaderLen = readU32(rec, 20).toInt()
            encoding = readU32(rec, 28).toInt()
            if (rec.size >= 92) {
                val fnOffset = readU32(rec, 84).toInt()
                val fnLen = readU32(rec, 88).toInt()
                if (fnOffset > 0 && fnLen > 0 && fnOffset + fnLen <= rec.size) {
                    val cs = if (encoding == 1252) Charset.forName("windows-1252") else Charsets.UTF_8
                    val t = String(rec, fnOffset, fnLen, cs).trim()
                    if (t.isNotBlank()) fullTitle = t
                }
            }
            if (rec.size >= 112) {
                val fii = readU32(rec, 108)
                if (fii in 1L..1000000L) firstImageIndex = fii.toInt()
            }
            if (rec.size >= 120) {
                huffOffset = readU32(rec, 112).toInt()
                huffCount = readU32(rec, 116).toInt()
            }
            if (mobiHeaderLen >= 228 && rec.size >= 244) {
                extraDataFlags = readU32(rec, 240).toInt()
            }

            // Check EXTH directly at 16 + mobiHeaderLen even if exthFlags bit 0x40 was omitted by converter
            val exthStart = 16 + mobiHeaderLen
            if (exthStart >= 16 && exthStart + 12 <= rec.size &&
                String(rec, exthStart, 4, Charsets.US_ASCII) == "EXTH"
            ) {
                val exthCount = readU32(rec, exthStart + 8).toInt()
                var pos = exthStart + 12
                val cs = if (encoding == 1252) Charset.forName("windows-1252") else Charsets.UTF_8
                for (i in 0 until exthCount) {
                    if (pos + 8 > rec.size) break
                    val recType = readU32(rec, pos).toInt()
                    val recLen = readU32(rec, pos + 4).toInt()
                    if (recLen < 8 || pos + recLen > rec.size) break
                    val dataStart = pos + 8
                    val dataLen = recLen - 8
                    when (recType) {
                        100 -> if (author.isBlank() && dataLen > 0) {
                            author = String(rec, dataStart, dataLen, cs).trim()
                        }
                        121 -> if (dataLen == 4) {
                            val boundary = readU32(rec, dataStart)
                            if (boundary in 1L..1000000L) kf8Boundary = boundary.toInt()
                        }
                        201 -> if (dataLen == 4) {
                            val off = readU32(rec, dataStart)
                            if (off in 0L..1000000L) coverOffset = off.toInt()
                        }
                        202 -> if (dataLen == 4) {
                            val off = readU32(rec, dataStart)
                            if (off in 0L..1000000L) thumbOffset = off.toInt()
                        }
                        503 -> if (dataLen > 0) {
                            val updatedTitle = String(rec, dataStart, dataLen, cs).trim()
                            if (updatedTitle.isNotBlank()) fullTitle = updatedTitle
                        }
                    }
                    pos += recLen
                }
            }
        }

        return MobiHeaderInfo(
            compression = compression,
            textRecordCount = textRecordCount,
            encryptionType = encryptionType,
            encoding = encoding,
            firstImageIndex = firstImageIndex,
            fullTitle = fullTitle,
            author = author,
            coverOffset = coverOffset,
            thumbOffset = thumbOffset,
            kf8BoundaryRecord = kf8Boundary,
            huffRecordOffset = huffOffset,
            huffRecordCount = huffCount,
            extraDataFlags = extraDataFlags
        )
    }

    private fun stripTrailingData(rec: ByteArray, flags: Int): ByteArray {
        if (flags == 0 || rec.isEmpty()) return rec
        var end = rec.size
        var bit = 1
        while (bit <= 15 && end > 0) {
            if ((flags and (1 shl bit)) != 0) {
                val trailSize = readBackwardVarInt(rec, end)
                if (trailSize in 1..end) {
                    end -= trailSize
                }
            }
            bit++
        }
        if ((flags and 1) != 0 && end > 0) {
            val multibyteCount = (rec[end - 1].toInt() and 0x03) + 1
            if (multibyteCount <= end) {
                end -= multibyteCount
            }
        }
        return if (end == rec.size) rec else rec.copyOfRange(0, end.coerceAtLeast(0))
    }

    private fun readBackwardVarInt(data: ByteArray, endExclusive: Int): Int {
        var value = 0
        var shift = 0
        var pos = endExclusive - 1
        val minPos = (endExclusive - 4).coerceAtLeast(0)
        while (pos >= minPos) {
            val b = data[pos].toInt() and 0xFF
            value = value or ((b and 0x7F) shl shift)
            shift += 7
            if ((b and 0x80) != 0) break
            pos--
        }
        return value
    }

    private fun decompressPalmDoc(data: ByteArray): ByteArray {
        var buf = ByteArray((data.size * 2).coerceAtLeast(4096))
        var outSize = 0

        fun ensureCapacity(extra: Int) {
            val needed = outSize + extra
            if (needed > buf.size) {
                buf = buf.copyOf(maxOf(buf.size * 2, needed + 1024))
            }
        }

        var i = 0
        val n = data.size
        while (i < n) {
            val c = data[i++].toInt() and 0xFF
            when {
                c == 0x00 || c in 0x09..0x7F -> {
                    ensureCapacity(1)
                    buf[outSize++] = c.toByte()
                }
                c in 0x01..0x08 -> {
                    val count = minOf(c, n - i)
                    ensureCapacity(count)
                    System.arraycopy(data, i, buf, outSize, count)
                    i += count
                    outSize += count
                }
                c in 0x80..0xBF -> {
                    if (i >= n) break
                    val c2 = data[i++].toInt() and 0xFF
                    val combined = (c shl 8) or c2
                    val dist = (combined shr 3) and 0x07FF
                    val len = (combined and 0x07) + 3
                    if (dist in 1..outSize) {
                        ensureCapacity(len)
                        for (k in 0 until len) {
                            buf[outSize] = buf[outSize - dist]
                            outSize++
                        }
                    }
                }
                else -> {
                    ensureCapacity(2)
                    buf[outSize++] = 0x20.toByte()
                    buf[outSize++] = (c xor 0x80).toByte()
                }
            }
        }
        return buf.copyOf(outSize)
    }

    private class HuffCdicDecoder(
        private val dict1: IntArray,
        private val minCode: LongArray,
        private val maxCode: LongArray,
        private val dictionary: ArrayList<Pair<ByteArray, Boolean>>
    ) {
        fun decompress(data: ByteArray): ByteArray {
            val out = ByteArrayOutputStream(data.size * 2)
            decodeSlice(data, out, depth = 0)
            return out.toByteArray()
        }

        private fun decodeSlice(data: ByteArray, out: ByteArrayOutputStream, depth: Int) {
            if (depth > 32 || data.isEmpty()) return
            var bitsLeft = data.size * 8
            var pos = 0
            var x = readU64Padded(data, 0)
            var n = 32

            while (true) {
                if (n <= 0) {
                    pos += 4
                    x = readU64Padded(data, pos)
                    n += 32
                }
                val code = ((x ushr n) and 0xFFFFFFFFL)
                val t1 = dict1[(code ushr 24).toInt() and 0xFF]
                var codeLen = t1 and 0x1F
                val isTerm = (t1 and 0x80) != 0
                var maxC = ((t1 ushr 8) and 0xFFFFFF).toLong()

                if (!isTerm) {
                    while (codeLen < 32 && code < minCode[codeLen]) {
                        codeLen++
                    }
                    if (codeLen >= 33) break
                    maxC = maxCode[codeLen]
                }

                n -= codeLen
                bitsLeft -= codeLen
                if (bitsLeft < 0) break

                val r = ((maxC - code) ushr (32 - codeLen)).toInt()
                if (r !in dictionary.indices) break
                val (slice, flag) = dictionary[r]
                if (!flag) {
                    decodeSlice(slice, out, depth + 1)
                } else {
                    out.write(slice)
                }
            }
        }

        private fun readU64Padded(data: ByteArray, offset: Int): Long {
            var v = 0L
            for (k in 0 until 8) {
                val b = if (offset + k < data.size) (data[offset + k].toLong() and 0xFFL) else 0L
                v = (v shl 8) or b
            }
            return v
        }
    }

    private fun buildHuffCdicDecoder(
        raf: RandomAccessFile,
        pdb: PdbInfo,
        baseRecord: Int,
        header: MobiHeaderInfo
    ): HuffCdicDecoder? {
        return runCatching {
            val huffIdx = baseRecord + header.huffRecordOffset
            if (header.huffRecordCount < 2 || huffIdx !in pdb.recordOffsets.indices) return@runCatching null
            val huff = readRecord(raf, pdb, huffIdx)
            if (huff.size < 24 || String(huff, 0, 4, Charsets.US_ASCII) != "HUFF") return@runCatching null

            val off1 = readU32(huff, 16).toInt()
            val off2 = readU32(huff, 20).toInt()
            if (off1 + 256 * 4 > huff.size || off2 + 64 * 4 > huff.size) return@runCatching null

            val dict1 = IntArray(256) { i -> readU32(huff, off1 + i * 4).toInt() }
            val minCode = LongArray(33)
            val maxCode = LongArray(33)
            for (codelen in 1..32) {
                val idx = (codelen - 1) * 2
                val cMin = readU32(huff, off2 + idx * 4)
                val cMax = readU32(huff, off2 + (idx + 1) * 4)
                minCode[codelen] = (cMin shl (32 - codelen)) and 0xFFFFFFFFL
                maxCode[codelen] = (((cMax + 1L) shl (32 - codelen)) - 1L) and 0xFFFFFFFFL
            }

            val dictionary = ArrayList<Pair<ByteArray, Boolean>>()
            for (k in 1 until header.huffRecordCount) {
                val cdicIdx = huffIdx + k
                if (cdicIdx !in pdb.recordOffsets.indices) break
                val cdic = readRecord(raf, pdb, cdicIdx)
                if (cdic.size < 16 || String(cdic, 0, 4, Charsets.US_ASCII) != "CDIC") continue
                val phrases = readU32(cdic, 8).toInt()
                val bits = readU32(cdic, 12).toInt()
                val count = minOf(1 shl bits, phrases - dictionary.size)
                for (i in 0 until count) {
                    val ptrPos = 16 + i * 2
                    if (ptrPos + 2 > cdic.size) break
                    val entryOff = 16 + readU16(cdic, ptrPos)
                    if (entryOff + 2 > cdic.size) break
                    val blen = readU16(cdic, entryOff)
                    val sliceLen = blen and 0x7FFF
                    val flag = (blen and 0x8000) != 0
                    val start = entryOff + 2
                    val end = (start + sliceLen).coerceAtMost(cdic.size)
                    dictionary.add(cdic.copyOfRange(start, end) to flag)
                }
            }
            HuffCdicDecoder(dict1, minCode, maxCode, dictionary)
        }.getOrNull()
    }

    private fun readU16(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 8) or (b[off + 1].toInt() and 0xFF)

    private fun readU32(b: ByteArray, off: Int): Long =
        ((b[off].toLong() and 0xFF) shl 24) or
            ((b[off + 1].toLong() and 0xFF) shl 16) or
            ((b[off + 2].toLong() and 0xFF) shl 8) or
            (b[off + 3].toLong() and 0xFF)
}
