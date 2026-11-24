package com.inkflow.reader.data

import android.content.Context
import android.graphics.Typeface
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import com.inkflow.reader.model.LocalFontItem
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.Charset

/**
 * Automatically discovers fonts from local device Fonts folders (without requiring manual import)
 * and parses each TTF/OTF/TTC file's internal OpenType `name` table to show the real font name
 * (preferring Traditional Chinese zh-TW > zh-HK > zh-CN > English) instead of the raw filename.
 */
object FontManager {

    private val FONT_EXTENSIONS = setOf("ttf", "otf", "ttc")

    fun hasAllFilesAccess(): Boolean {
        return Environment.isExternalStorageManager()
    }

    fun scanAvailableFonts(context: Context, customFolderUri: String?): List<LocalFontItem> {
        val results = LinkedHashMap<String, LocalFontItem>()

        // 1. Auto-scan public storage Fonts folders when All Files Access is granted
        if (hasAllFilesAccess()) {
            val extRoot = Environment.getExternalStorageDirectory()
            val candidateDirs = listOf(
                File(extRoot, "Fonts") to "本機 Fonts",
                File(extRoot, "fonts") to "本機 fonts",
                File(extRoot, "Download/Fonts") to "Download/Fonts",
                File(extRoot, "Documents/Fonts") to "Documents/Fonts"
            )
            for ((dir, label) in candidateDirs) {
                scanDirectoryRecursively(dir, label, results, maxDepth = 2)
            }
        }

        // 2. App-specific external Fonts folder (accessible even without All Files Access)
        context.getExternalFilesDir("Fonts")?.let { appExtFonts ->
            appExtFonts.mkdirs()
            scanDirectoryRecursively(appExtFonts, "App Fonts", results, maxDepth = 2)
        }

        // 3. Previously imported internal fonts
        val internalFonts = File(context.filesDir, "fonts")
        if (internalFonts.exists()) {
            scanDirectoryRecursively(internalFonts, "已匯入", results, maxDepth = 1)
        }

        // 4. Optional user-picked SAF folder (works without All Files Access)
        if (!customFolderUri.isNullOrBlank()) {
            scanSafTree(context, Uri.parse(customFolderUri), results)
        }

        return results.values.sortedWith(
            compareBy<LocalFontItem> { it.displayName.lowercase() }
                .thenBy { it.pathOrUri }
        )
    }

    fun loadTypeface(context: Context, pathOrUri: String?): Typeface? {
        if (pathOrUri.isNullOrBlank()) return null
        return runCatching {
            if (pathOrUri.startsWith("content://")) {
                val uri = Uri.parse(pathOrUri)
                context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    Typeface.Builder(pfd.fileDescriptor).build()
                }
            } else {
                val file = File(pathOrUri)
                if (file.exists() && file.canRead()) {
                    Typeface.createFromFile(file)
                } else null
            }
        }.getOrNull()
    }

    private fun scanDirectoryRecursively(
        dir: File,
        sourceLabel: String,
        out: MutableMap<String, LocalFontItem>,
        maxDepth: Int
    ) {
        if (maxDepth < 0 || !dir.exists() || !dir.isDirectory) return
        val children = dir.listFiles() ?: return
        for (child in children) {
            if (child.isDirectory) {
                if (!child.name.startsWith(".")) {
                    scanDirectoryRecursively(child, sourceLabel, out, maxDepth - 1)
                }
            } else if (child.isFile && child.extension.lowercase() in FONT_EXTENSIONS && child.length() > 1024L) {
                val canonical = runCatching { child.canonicalPath }.getOrDefault(child.absolutePath)
                val dedupKey = canonical.lowercase()
                if (out.containsKey(dedupKey)) continue
                val fontName = parseFontDisplayName(child) ?: child.nameWithoutExtension
                out[dedupKey] = LocalFontItem(
                    displayName = fontName,
                    pathOrUri = canonical,
                    sourceLabel = sourceLabel
                )
            }
        }
    }

    private fun scanSafTree(
        context: Context,
        treeUri: Uri,
        out: MutableMap<String, LocalFontItem>
    ) {
        runCatching {
            val docId = DocumentsContract.getTreeDocumentId(treeUri)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            )
            context.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)

                while (cursor.moveToNext()) {
                    val childId = if (idIdx >= 0) cursor.getString(idIdx) else continue
                    val displayName = if (nameIdx >= 0) cursor.getString(nameIdx) else continue
                    val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx) else ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue

                    val ext = displayName.substringAfterLast('.', "").lowercase()
                    if (ext !in FONT_EXTENSIONS) continue

                    val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                    val key = fileUri.toString()
                    if (out.containsKey(key)) continue

                    val parsedName = parseFontDisplayNameFromUri(context, fileUri)
                        ?: displayName.substringBeforeLast('.')
                    out[key] = LocalFontItem(
                        displayName = parsedName,
                        pathOrUri = key,
                        sourceLabel = "自訂資料夾"
                    )
                }
            }
        }
    }

    // ---------------- OpenType / TrueType / TTC `name` Table Parser ----------------

    fun parseFontDisplayName(file: File): String? {
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                val fileLen = raf.length()
                if (fileLen < 12L) return@use null

                val header = ByteArray(16)
                raf.readFully(header, 0, minOf(16L, fileLen).toInt())
                val tag = String(header, 0, 4, Charsets.US_ASCII)

                val sfntOffset: Long = if (tag == "ttcf") {
                    if (fileLen < 16L) return@use null
                    val bb = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN)
                    val numFonts = bb.getInt(8)
                    if (numFonts < 1) return@use null
                    bb.getInt(12).toLong() and 0xFFFFFFFFL
                } else {
                    0L
                }

                if (sfntOffset + 12L > fileLen) return@use null
                raf.seek(sfntOffset)
                val sfntHeader = ByteArray(12)
                raf.readFully(sfntHeader)
                val numTables = readUInt16(sfntHeader, 4)
                if (numTables <= 0 || numTables > 512) return@use null

                val dirBytes = ByteArray(numTables * 16)
                if (sfntOffset + 12L + dirBytes.size > fileLen) return@use null
                raf.readFully(dirBytes)

                var nameTableOffset = -1L
                var nameTableLength = 0
                for (i in 0 until numTables) {
                    val base = i * 16
                    if (dirBytes[base] == 'n'.code.toByte() &&
                        dirBytes[base + 1] == 'a'.code.toByte() &&
                        dirBytes[base + 2] == 'm'.code.toByte() &&
                        dirBytes[base + 3] == 'e'.code.toByte()
                    ) {
                        nameTableOffset = readUInt32(dirBytes, base + 8)
                        nameTableLength = readUInt32(dirBytes, base + 12).toInt()
                        break
                    }
                }

                if (nameTableOffset < 0L || nameTableLength <= 6 || nameTableOffset + nameTableLength > fileLen) {
                    return@use null
                }
                if (nameTableLength > 2 * 1024 * 1024) return@use null

                raf.seek(nameTableOffset)
                val nameTable = ByteArray(nameTableLength)
                raf.readFully(nameTable)
                extractBestNameFromTable(nameTable)
            }
        }.getOrNull()
    }

    private fun parseFontDisplayNameFromUri(context: Context, uri: Uri): String? {
        return runCatching {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                java.io.FileInputStream(pfd.fileDescriptor).channel.use { ch ->
                    val size = ch.size()
                    if (size < 12L) return@use null

                    val hdrBuf = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
                    ch.read(hdrBuf, 0L)
                    val hdr = hdrBuf.array()
                    val tag = String(hdr, 0, 4, Charsets.US_ASCII)
                    val sfntOffset: Long = if (tag == "ttcf") {
                        val numFonts = ByteBuffer.wrap(hdr).order(ByteOrder.BIG_ENDIAN).getInt(8)
                        if (numFonts < 1) return@use null
                        ByteBuffer.wrap(hdr).order(ByteOrder.BIG_ENDIAN).getInt(12).toLong() and 0xFFFFFFFFL
                    } else 0L

                    if (sfntOffset + 12L > size) return@use null
                    val sfntBuf = ByteBuffer.allocate(12)
                    ch.read(sfntBuf, sfntOffset)
                    val numTables = readUInt16(sfntBuf.array(), 4)
                    if (numTables <= 0 || numTables > 512) return@use null

                    val dirBuf = ByteBuffer.allocate(numTables * 16)
                    ch.read(dirBuf, sfntOffset + 12L)
                    val dirBytes = dirBuf.array()

                    var nameOffset = -1L
                    var nameLen = 0
                    for (i in 0 until numTables) {
                        val b = i * 16
                        if (dirBytes[b] == 'n'.code.toByte() &&
                            dirBytes[b + 1] == 'a'.code.toByte() &&
                            dirBytes[b + 2] == 'm'.code.toByte() &&
                            dirBytes[b + 3] == 'e'.code.toByte()
                        ) {
                            nameOffset = readUInt32(dirBytes, b + 8)
                            nameLen = readUInt32(dirBytes, b + 12).toInt()
                            break
                        }
                    }
                    if (nameOffset < 0L || nameLen <= 6 || nameOffset + nameLen > size || nameLen > 2 * 1024 * 1024) {
                        return@use null
                    }
                    val tableBuf = ByteBuffer.allocate(nameLen)
                    ch.read(tableBuf, nameOffset)
                    extractBestNameFromTable(tableBuf.array())
                }
            }
        }.getOrNull()
    }

    private fun extractBestNameFromTable(table: ByteArray): String? {
        if (table.size < 6) return null
        val count = readUInt16(table, 2)
        val stringOffset = readUInt16(table, 4)

        var bestScore = -1
        var bestName: String? = null

        for (i in 0 until count) {
            val rec = 6 + i * 12
            if (rec + 12 > table.size) break

            val platformId = readUInt16(table, rec)
            val encodingId = readUInt16(table, rec + 2)
            val languageId = readUInt16(table, rec + 4)
            val nameId = readUInt16(table, rec + 6)
            val length = readUInt16(table, rec + 8)
            val offset = readUInt16(table, rec + 10)

            // nameID 4 = Full Font Name, 16 = Typographic Family, 1 = Font Family
            if (nameId != 4 && nameId != 16 && nameId != 1) continue
            val strStart = stringOffset + offset
            val strEnd = strStart + length
            if (length <= 0 || strStart < 0 || strEnd > table.size) continue

            val decoded = decodeNameRecord(table, strStart, length, platformId, encodingId)
                ?.replace("\u0000", "")
                ?.trim()
                .orEmpty()
            if (decoded.isBlank()) continue

            val langScore = when (platformId) {
                3 -> when (languageId) {
                    0x0404 -> 100 // zh-TW (Traditional Chinese - Taiwan)
                    0x0C04, 0x1404 -> 92 // zh-HK / zh-MO
                    0x0804, 0x1004 -> 80 // zh-CN / zh-SG
                    0x0409 -> 50 // en-US
                    else -> 30
                }
                1 -> when (languageId) {
                    19 -> 95 // Mac Traditional Chinese
                    33 -> 75 // Mac Simplified Chinese
                    0 -> 40  // Mac English
                    else -> 20
                }
                0 -> 45 // Unicode platform
                else -> 10
            }

            val idScore = when (nameId) {
                4 -> 3
                16 -> 2
                else -> 1
            }

            val totalScore = langScore * 10 + idScore
            if (totalScore > bestScore) {
                bestScore = totalScore
                bestName = decoded
            }
        }
        return bestName
    }

    private fun decodeNameRecord(
        table: ByteArray,
        start: Int,
        length: Int,
        platformId: Int,
        encodingId: Int
    ): String? {
        return runCatching {
            when (platformId) {
                0, 3 -> String(table, start, length, Charsets.UTF_16BE)
                1 -> {
                    val csName = when (encodingId) {
                        2 -> "Big5"
                        25 -> "GB18030"
                        else -> "ISO-8859-1"
                    }
                    val cs = if (Charset.isSupported(csName)) Charset.forName(csName) else Charsets.ISO_8859_1
                    String(table, start, length, cs)
                }
                else -> null
            }
        }.getOrNull()
    }

    private fun readUInt16(bytes: ByteArray, offset: Int): Int {
        return ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)
    }

    private fun readUInt32(bytes: ByteArray, offset: Int): Long {
        return ((bytes[offset].toLong() and 0xFF) shl 24) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
            (bytes[offset + 3].toLong() and 0xFF)
    }
}
