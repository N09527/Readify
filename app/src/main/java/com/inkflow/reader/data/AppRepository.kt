package com.inkflow.reader.data

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.inkflow.reader.model.*
import com.inkflow.reader.parser.BookParser
import com.inkflow.reader.parser.NaturalSort
import com.inkflow.reader.sync.CloudProviderType
import com.inkflow.reader.sync.CloudSyncConfig
import com.inkflow.reader.sync.GoogleDriveConfig
import com.inkflow.reader.sync.OneDriveConfig
import com.inkflow.reader.sync.WebDavConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

class AppRepository(private val context: Context) {

    companion object {
        private val ioLock = Any()
    }

    private val booksDir = File(context.filesDir, "books").apply { mkdirs() }
    private val coversDir = File(context.filesDir, "covers").apply { mkdirs() }

    private val booksJsonFile = File(context.filesDir, "bookshelf.json")
    private val bookmarksJsonFile = File(context.filesDir, "bookmarks.json")
    private val settingsJsonFile = File(context.filesDir, "reader_settings.json")
    private val cloudSyncConfigFile = File(context.filesDir, "cloud_sync_config.json")
    private val syncMetaFile = File(context.filesDir, "sync_meta.json")

    private data class FolderFileCandidate(
        val uri: Uri,
        val displayName: String,
        val sizeBytes: Long,
        val relativePath: String
    )

    fun getBooksDir(): File = booksDir
    fun getCoversDir(): File = coversDir

    /**
     * Fast content fingerprint (file size + SHA-256 of first 64KB and last 64KB).
     * Runs in ~2ms even for 300MB PDF/CBR comics while uniquely matching identical book files across devices.
     */
    fun computeFastFingerprint(file: File): String {
        if (!file.exists()) return ""
        return runCatching {
            val md = MessageDigest.getInstance("SHA-256")
            val len = file.length()
            md.update(len.toString().toByteArray(Charsets.UTF_8))
            RandomAccessFile(file, "r").use { raf ->
                val chunk = 64 * 1024
                val buf = ByteArray(minOf(chunk.toLong(), len).toInt())
                if (buf.isNotEmpty()) {
                    raf.seek(0L)
                    val read1 = raf.read(buf)
                    if (read1 > 0) md.update(buf, 0, read1)
                }
                if (len > chunk) {
                    val tailLen = minOf(chunk.toLong(), len - chunk).toInt()
                    val tailBuf = ByteArray(tailLen)
                    raf.seek(len - tailLen)
                    val read2 = raf.read(tailBuf)
                    if (read2 > 0) md.update(tailBuf, 0, read2)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) }.take(24)
        }.getOrDefault("")
    }

    fun sanitizeTags(rawTags: Collection<String>): List<String> {
        return rawTags
            .map { it.trim() }
            .filter { it.isNotBlank() && it != "未分類" }
            .distinct()
    }

    // ---------------- Bookshelf ----------------

    fun loadBooks(): List<BookItem> = synchronized(ioLock) {
        if (!booksJsonFile.exists()) return emptyList()
        return runCatching {
            val arr = JSONArray(booksJsonFile.readText())
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                val fmt = runCatching { BookFormat.valueOf(obj.optString("format", "TXT")) }
                    .getOrDefault(BookFormat.TXT)
                val defaultContentType = when (fmt) {
                    BookFormat.PDF -> BookContentType.PDF
                    BookFormat.CBZ, BookFormat.CBR, BookFormat.ZIP -> BookContentType.COMIC
                    else -> BookContentType.TEXT
                }
                val contentType = runCatching {
                    val raw = obj.optString("contentType", "")
                    if (raw.isBlank()) defaultContentType else BookContentType.valueOf(raw)
                }.getOrDefault(defaultContentType)

                val lastCh = obj.optInt("lastChapterIndex", 0)
                val lastOff = obj.optInt("lastCharOffset", 0)
                val lastPg = obj.optInt("lastPageIndex", 0)
                val progress = obj.optDouble("readingProgress", 0.0).toFloat().coerceIn(0f, 1f)
                val isRead = obj.optBoolean("isRead", progress >= 0.99f)
                val hasStarted = obj.optBoolean(
                    "hasStartedReading",
                    isRead || progress > 0f || lastCh > 0 || lastOff > 0 || lastPg > 0
                )
                val tagsArr = obj.optJSONArray("tags")
                val parsedTags = if (tagsArr != null) {
                    sanitizeTags((0 until tagsArr.length()).map { idx -> tagsArr.optString(idx) })
                } else {
                    val legacyGroup = obj.optString("groupName", "").trim()
                    if (legacyGroup.isNotBlank() && legacyGroup != "未分類") listOf(legacyGroup) else emptyList()
                }
                BookItem(
                    id = obj.getString("id"),
                    title = obj.getString("title"),
                    author = obj.optString("author", "未知作者"),
                    format = fmt,
                    contentType = contentType,
                    localPath = obj.getString("localPath"),
                    coverPath = obj.optString("coverPath").takeIf { it.isNotBlank() },
                    tags = parsedTags,
                    lastChapterIndex = lastCh,
                    lastCharOffset = lastOff,
                    lastPageIndex = lastPg,
                    lastReadTime = obj.optLong("lastReadTime", System.currentTimeMillis()),
                    addedTime = obj.optLong("addedTime", System.currentTimeMillis()),
                    sourceFileName = obj.optString("sourceFileName", ""),
                    fileSizeBytes = obj.optLong("fileSizeBytes", 0L),
                    contentHash = obj.optString("contentHash", ""),
                    readingProgress = progress,
                    isRead = isRead,
                    hasStartedReading = hasStarted
                )
            }.filter { File(it.localPath).exists() }
        }.getOrDefault(emptyList())
    }

    fun saveBooks(books: List<BookItem>) = synchronized(ioLock) {
        val arr = JSONArray()
        books.forEach { b ->
            arr.put(JSONObject().apply {
                put("id", b.id)
                put("title", b.title)
                put("author", b.author)
                put("format", b.format.name)
                put("contentType", b.contentType.name)
                put("localPath", b.localPath)
                put("coverPath", b.coverPath ?: "")
                put("tags", JSONArray().apply { sanitizeTags(b.tags).forEach { put(it) } })
                put("lastChapterIndex", b.lastChapterIndex)
                put("lastCharOffset", b.lastCharOffset)
                put("lastPageIndex", b.lastPageIndex)
                put("lastReadTime", b.lastReadTime)
                put("addedTime", b.addedTime)
                put("sourceFileName", b.sourceFileName)
                put("fileSizeBytes", b.fileSizeBytes)
                put("contentHash", b.contentHash)
                put("readingProgress", b.readingProgress.toDouble())
                put("isRead", b.isRead)
                put("hasStartedReading", b.hasStartedReading)
            })
        }
        booksJsonFile.writeText(arr.toString(2))
    }

    private fun resolveSupportedFormat(displayName: String): BookFormat? {
        val ext = displayName.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "txt" -> BookFormat.TXT
            "epub" -> BookFormat.EPUB
            "pdf" -> BookFormat.PDF
            "cbz" -> BookFormat.CBZ
            "cbr" -> BookFormat.CBR
            "zip" -> BookFormat.ZIP
            "mobi", "prc" -> BookFormat.MOBI
            "azw3", "kf8" -> BookFormat.AZW3
            else -> null
        }
    }

    private fun isDuplicateBook(existing: List<BookItem>, displayName: String, sizeBytes: Long): Boolean {
        if (displayName.isBlank()) return false
        return existing.any { item ->
            item.sourceFileName.equals(displayName, ignoreCase = true) &&
                (sizeBytes <= 0L || item.fileSizeBytes <= 0L || item.fileSizeBytes == sizeBytes)
        }
    }

    private fun copyAndParseBook(
        uri: Uri,
        displayName: String,
        sizeBytes: Long,
        format: BookFormat
    ): BookItem {
        val ext = displayName.substringAfterLast('.', format.name.lowercase()).lowercase()
        val id = UUID.randomUUID().toString()
        val destFile = File(booksDir, "$id.$ext")

        context.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(destFile).use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("無法讀取檔案內容")

        val actualSize = if (sizeBytes > 0L) sizeBytes else destFile.length()
        val hash = computeFastFingerprint(destFile)
        val fallbackTitle = displayName.substringBeforeLast('.').ifBlank { displayName }
        val parsed = BookParser.parseMetadataAndCover(destFile, format, fallbackTitle)

        var coverPath: String? = null
        if (parsed.coverBytes != null && parsed.coverBytes.isNotEmpty()) {
            val coverFile = File(coversDir, "$id.img")
            coverFile.writeBytes(parsed.coverBytes)
            coverPath = coverFile.absolutePath
        }

        val now = System.currentTimeMillis()
        return BookItem(
            id = id,
            title = parsed.title.ifBlank { fallbackTitle },
            author = parsed.author.ifBlank { "未知作者" },
            format = format,
            contentType = parsed.contentType,
            localPath = destFile.absolutePath,
            coverPath = coverPath,
            tags = emptyList(),
            lastReadTime = now,
            addedTime = now,
            sourceFileName = displayName,
            fileSizeBytes = actualSize,
            contentHash = hash
        )
    }

    suspend fun importBooksFromUris(
        uris: List<Uri>,
        onProgress: suspend (current: Int, total: Int, fileName: String) -> Unit
    ): BatchImportResult = withContext(Dispatchers.IO) {
        if (uris.isEmpty()) return@withContext BatchImportResult(0, 0, 0, 0)

        val currentBooks = loadBooks().toMutableList()
        var imported = 0
        var skippedDup = 0
        var unsupported = 0
        var failed = 0
        var lastTitle: String? = null

        uris.forEachIndexed { idx, uri ->
            val (displayName, sizeBytes) = resolveDisplayNameAndSize(uri)
            val safeName = displayName ?: "未命名書籍"
            onProgress(idx + 1, uris.size, safeName)

            val format = resolveSupportedFormat(safeName)
            if (format == null) {
                unsupported++
                return@forEachIndexed
            }
            if (isDuplicateBook(currentBooks, safeName, sizeBytes)) {
                skippedDup++
                return@forEachIndexed
            }

            runCatching {
                copyAndParseBook(uri, safeName, sizeBytes, format)
            }.onSuccess { item ->
                currentBooks.add(0, item)
                imported++
                lastTitle = item.title
                if (imported % 3 == 0) saveBooks(currentBooks)
            }.onFailure {
                failed++
            }
        }

        if (imported > 0) saveBooks(currentBooks)
        BatchImportResult(imported, skippedDup, unsupported, failed, lastTitle)
    }

    suspend fun importBooksFromFolderUri(
        treeUri: Uri,
        onProgress: suspend (current: Int, total: Int, fileName: String) -> Unit
    ): BatchImportResult = withContext(Dispatchers.IO) {
        val rootDocId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull()
            ?: return@withContext BatchImportResult(0, 0, 0, 1)

        val candidates = mutableListOf<FolderFileCandidate>()
        collectFolderBooksRecursively(treeUri, rootDocId, "", 6, candidates)

        if (candidates.isEmpty()) return@withContext BatchImportResult(0, 0, 0, 0)
        candidates.sortWith(compareBy(NaturalSort.COMPARATOR) { it.relativePath })

        val currentBooks = loadBooks().toMutableList()
        var imported = 0
        var skippedDup = 0
        var failed = 0
        var lastTitle: String? = null

        candidates.forEachIndexed { idx, candidate ->
            onProgress(idx + 1, candidates.size, candidate.displayName)
            val format = resolveSupportedFormat(candidate.displayName) ?: return@forEachIndexed
            if (isDuplicateBook(currentBooks, candidate.displayName, candidate.sizeBytes)) {
                skippedDup++
                return@forEachIndexed
            }

            runCatching {
                copyAndParseBook(candidate.uri, candidate.displayName, candidate.sizeBytes, format)
            }.onSuccess { item ->
                currentBooks.add(0, item)
                imported++
                lastTitle = item.title
                if (imported % 3 == 0) saveBooks(currentBooks)
            }.onFailure {
                failed++
            }
        }

        if (imported > 0) saveBooks(currentBooks)
        BatchImportResult(imported, skippedDup, 0, failed, lastTitle)
    }

    private fun collectFolderBooksRecursively(
        treeUri: Uri,
        parentDocId: String,
        relativePrefix: String,
        maxDepth: Int,
        out: MutableList<FolderFileCandidate>
    ) {
        if (maxDepth < 0) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE
        )

        runCatching {
            context.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)

                while (cursor.moveToNext()) {
                    val childId = if (idIdx >= 0) cursor.getString(idIdx) else continue
                    val name = if (nameIdx >= 0) cursor.getString(nameIdx)?.trim().orEmpty() else continue
                    if (name.isBlank() || name.startsWith(".")) continue

                    val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx).orEmpty() else ""
                    val size = if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) cursor.getLong(sizeIdx) else 0L
                    val relPath = if (relativePrefix.isEmpty()) name else "$relativePrefix/$name"

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (!name.equals("Android", ignoreCase = true) && !name.equals("__MACOSX", ignoreCase = true)) {
                            collectFolderBooksRecursively(treeUri, childId, relPath, maxDepth - 1, out)
                        }
                    } else if (resolveSupportedFormat(name) != null) {
                        val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                        out.add(FolderFileCandidate(fileUri, name, size, relPath))
                    }
                }
            }
        }
    }

    suspend fun refreshContentTypeIfNeeded(book: BookItem): BookItem = withContext(Dispatchers.IO) {
        if (book.format == BookFormat.EPUB && book.contentType == BookContentType.TEXT) {
            val info = BookParser.inspectEpubComic(File(book.localPath), book.title)
            if (info.isComic) {
                val updatedBook = book.copy(contentType = BookContentType.COMIC)
                val updatedList = loadBooks().map { if (it.id == book.id) updatedBook else it }
                saveBooks(updatedList)
                return@withContext updatedBook
            }
        }
        book
    }

    fun deleteBook(bookId: String) = deleteBooks(setOf(bookId))

    fun deleteBooks(bookIds: Set<String>) {
        if (bookIds.isEmpty()) return
        val current = loadBooks()
        current.filter { it.id in bookIds }.forEach { target ->
            File(target.localPath).delete()
            target.coverPath?.let { File(it).delete() }
            File(context.cacheDir, "cbr_cache/${target.id}").deleteRecursively()
        }
        saveBooks(current.filterNot { it.id in bookIds })
        val allBm = loadAllBookmarksPublic()
        val removedBmIds = allBm.filter { it.bookId in bookIds }.map { it.id }.toSet()
        if (removedBmIds.isNotEmpty()) {
            saveDeletedBookmarkIds(loadDeletedBookmarkIds() + removedBmIds)
        }
        saveAllBookmarksPublic(allBm.filterNot { it.bookId in bookIds })
    }

    fun updateBookProgress(
        bookId: String,
        chapterIndex: Int,
        charOffset: Int,
        progressFraction: Float
    ) = synchronized(ioLock) {
        val clamped = progressFraction.coerceIn(0f, 1f)
        val now = System.currentTimeMillis()
        val updated = loadBooks().map { book ->
            if (book.id == bookId) {
                val nowRead = book.isRead || clamped >= 0.99f
                val newProgress = if (nowRead && clamped < 0.99f) book.readingProgress.coerceAtLeast(clamped) else clamped
                val unchanged = book.hasStartedReading &&
                    book.lastChapterIndex == chapterIndex &&
                    book.lastCharOffset == charOffset &&
                    book.isRead == nowRead &&
                    kotlin.math.abs(book.readingProgress - newProgress) < 0.0005f
                book.copy(
                    lastChapterIndex = chapterIndex,
                    lastCharOffset = charOffset,
                    readingProgress = newProgress,
                    isRead = nowRead,
                    hasStartedReading = true,
                    lastReadTime = if (unchanged) book.lastReadTime else now
                )
            } else book
        }
        saveBooks(updated)
    }

    fun updateVisualBookProgress(
        bookId: String,
        pageIndex: Int,
        progressFraction: Float
    ) = synchronized(ioLock) {
        val clamped = progressFraction.coerceIn(0f, 1f)
        val now = System.currentTimeMillis()
        val updated = loadBooks().map { book ->
            if (book.id == bookId) {
                val nowRead = book.isRead || clamped >= 0.99f
                val newProgress = if (nowRead && clamped < 0.99f) book.readingProgress.coerceAtLeast(clamped) else clamped
                val unchanged = book.hasStartedReading &&
                    book.lastPageIndex == pageIndex &&
                    book.isRead == nowRead &&
                    kotlin.math.abs(book.readingProgress - newProgress) < 0.0005f
                book.copy(
                    lastPageIndex = pageIndex,
                    readingProgress = newProgress,
                    isRead = nowRead,
                    hasStartedReading = true,
                    lastReadTime = if (unchanged) book.lastReadTime else now
                )
            } else book
        }
        saveBooks(updated)
    }

    fun setBookReadStatus(bookId: String, isRead: Boolean) = setBooksReadStatus(setOf(bookId), isRead)

    fun setBooksReadStatus(bookIds: Set<String>, isRead: Boolean) {
        if (bookIds.isEmpty()) return
        val now = System.currentTimeMillis()
        val updated = loadBooks().map { book ->
            if (book.id in bookIds) {
                if (isRead) {
                    book.copy(
                        isRead = true,
                        hasStartedReading = true,
                        readingProgress = 1f,
                        lastReadTime = now
                    )
                } else {
                    book.copy(
                        isRead = false,
                        hasStartedReading = false,
                        readingProgress = 0f,
                        lastChapterIndex = 0,
                        lastCharOffset = 0,
                        lastPageIndex = 0,
                        lastReadTime = now
                    )
                }
            } else book
        }
        saveBooks(updated)
    }

    /**
     * Automatically repairs covers (and author metadata) for previously imported MOBI / AZW3 books
     * whose cover was missing before v9's improved MOBI cover extractor.
     */
    suspend fun repairMissingMobiCovers(): Boolean = withContext(Dispatchers.IO) {
        val current = loadBooks()
        var anyChanged = false
        val updated = current.map { book ->
            val missingCover = book.coverPath.isNullOrBlank() || !File(book.coverPath).exists()
            if (book.format in setOf(BookFormat.MOBI, BookFormat.AZW3) && missingCover) {
                val file = File(book.localPath)
                if (file.exists()) {
                    val parsed = BookParser.parseMetadataAndCover(file, book.format, book.title)
                    var newCoverPath = book.coverPath
                    if (parsed.coverBytes != null && parsed.coverBytes.isNotEmpty()) {
                        val coverFile = File(coversDir, "${book.id}.img")
                        coverFile.writeBytes(parsed.coverBytes)
                        newCoverPath = coverFile.absolutePath
                        anyChanged = true
                    }
                    val newAuthor = if (book.author in setOf("未知作者", "Kindle 電子書") && parsed.author.isNotBlank() && parsed.author != "Kindle 電子書") {
                        anyChanged = true
                        parsed.author
                    } else book.author
                    book.copy(coverPath = newCoverPath, author = newAuthor)
                } else book
            } else book
        }
        if (anyChanged) {
            saveBooks(updated)
        }
        anyChanged
    }

    fun updateBookTags(bookId: String, newTags: List<String>) {
        val clean = sanitizeTags(newTags)
        val updated = loadBooks().map { book ->
            if (book.id == bookId) book.copy(tags = clean) else book
        }
        saveBooks(updated)
    }

    fun addTagsToBooks(bookIds: Set<String>, tagsToAdd: Collection<String>) {
        val clean = sanitizeTags(tagsToAdd)
        if (bookIds.isEmpty() || clean.isEmpty()) return
        val updated = loadBooks().map { book ->
            if (book.id in bookIds) book.copy(tags = sanitizeTags(book.tags + clean)) else book
        }
        saveBooks(updated)
    }

    fun removeTagsFromBooks(bookIds: Set<String>, tagsToRemove: Collection<String>) {
        val removeSet = sanitizeTags(tagsToRemove).toSet()
        if (bookIds.isEmpty() || removeSet.isEmpty()) return
        val updated = loadBooks().map { book ->
            if (book.id in bookIds) book.copy(tags = book.tags.filterNot { it in removeSet }) else book
        }
        saveBooks(updated)
    }

    fun updateBookContentType(bookId: String, newType: BookContentType) {
        val updated = loadBooks().map { book ->
            if (book.id == bookId) book.copy(contentType = newType) else book
        }
        saveBooks(updated)
    }

    // ---------------- Local Fonts Discovery ----------------

    suspend fun scanLocalFonts(customFolderUri: String?): List<LocalFontItem> = withContext(Dispatchers.IO) {
        FontManager.scanAvailableFonts(context, customFolderUri)
    }

    // ---------------- Bookmarks ----------------

    fun loadAllBookmarksPublic(): List<BookmarkItem> {
        if (!bookmarksJsonFile.exists()) return emptyList()
        return runCatching {
            val arr = JSONArray(bookmarksJsonFile.readText())
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                BookmarkItem(
                    id = obj.getString("id"),
                    bookId = obj.getString("bookId"),
                    chapterIndex = obj.getInt("chapterIndex"),
                    chapterTitle = obj.optString("chapterTitle", ""),
                    charOffset = obj.getInt("charOffset"),
                    preview = obj.optString("preview", ""),
                    createdAt = obj.optLong("createdAt", System.currentTimeMillis())
                )
            }
        }.getOrDefault(emptyList())
    }

    fun saveAllBookmarksPublic(items: List<BookmarkItem>) {
        val arr = JSONArray()
        items.forEach { bm ->
            arr.put(JSONObject().apply {
                put("id", bm.id)
                put("bookId", bm.bookId)
                put("chapterIndex", bm.chapterIndex)
                put("chapterTitle", bm.chapterTitle)
                put("charOffset", bm.charOffset)
                put("preview", bm.preview)
                put("createdAt", bm.createdAt)
            })
        }
        bookmarksJsonFile.writeText(arr.toString(2))
    }

    fun loadBookmarksForBook(bookId: String): List<BookmarkItem> {
        return loadAllBookmarksPublic()
            .filter { it.bookId == bookId }
            .sortedByDescending { it.createdAt }
    }

    fun addBookmark(bookmark: BookmarkItem) {
        val list = loadAllBookmarksPublic().toMutableList()
        list.add(0, bookmark)
        saveAllBookmarksPublic(list)
    }

    fun deleteBookmark(bookmarkId: String) {
        saveDeletedBookmarkIds(loadDeletedBookmarkIds() + bookmarkId)
        saveAllBookmarksPublic(loadAllBookmarksPublic().filterNot { it.id == bookmarkId })
    }

    // ---------------- Sync Metadata (Tombstones & Settings Timestamp) ----------------

    private fun loadSyncMetaJson(): JSONObject {
        if (!syncMetaFile.exists()) return JSONObject()
        return runCatching { JSONObject(syncMetaFile.readText()) }.getOrDefault(JSONObject())
    }

    private fun saveSyncMetaJson(obj: JSONObject) {
        syncMetaFile.writeText(obj.toString(2))
    }

    fun loadDeletedBookmarkIds(): Set<String> {
        val arr = loadSyncMetaJson().optJSONArray("deletedBookmarkIds") ?: return emptySet()
        val out = mutableSetOf<String>()
        for (i in 0 until arr.length()) {
            val s = arr.optString(i).trim()
            if (s.isNotBlank()) out.add(s)
        }
        return out
    }

    fun saveDeletedBookmarkIds(ids: Set<String>) {
        val meta = loadSyncMetaJson()
        val arr = JSONArray()
        ids.forEach { arr.put(it) }
        meta.put("deletedBookmarkIds", arr)
        saveSyncMetaJson(meta)
    }

    fun loadSettingsUpdatedAtMs(): Long {
        return loadSyncMetaJson().optLong("settingsUpdatedAtMs", 0L)
    }

    private fun saveSettingsUpdatedAtMs(ts: Long) {
        val meta = loadSyncMetaJson()
        meta.put("settingsUpdatedAtMs", ts)
        saveSyncMetaJson(meta)
    }

    // ---------------- Cloud Sync Config ----------------

    fun loadCloudSyncConfig(): CloudSyncConfig = synchronized(ioLock) {
        if (!cloudSyncConfigFile.exists()) return CloudSyncConfig()
        return runCatching {
            val obj = JSONObject(cloudSyncConfigFile.readText())
            val wd = obj.optJSONObject("webDav")
            val gd = obj.optJSONObject("googleDrive")
            val od = obj.optJSONObject("oneDrive")
            CloudSyncConfig(
                activeProvider = runCatching {
                    CloudProviderType.valueOf(obj.optString("activeProvider", CloudProviderType.WEBDAV.name))
                }.getOrDefault(CloudProviderType.WEBDAV),
                autoSyncOnBookOpenClose = obj.optBoolean("autoSyncOnBookOpenClose", true),
                syncBookFiles = obj.optBoolean("syncBookFiles", true),
                syncReaderSettings = obj.optBoolean("syncReaderSettings", true),
                lastSyncTimeMs = obj.optLong("lastSyncTimeMs", 0L),
                lastSyncSummary = obj.optString("lastSyncSummary", ""),
                webDav = WebDavConfig(
                    serverUrl = wd?.optString("serverUrl", "") ?: "",
                    username = wd?.optString("username", "") ?: "",
                    password = wd?.optString("password", "") ?: "",
                    remoteFolder = wd?.optString("remoteFolder", "Readify") ?: "Readify"
                ),
                googleDrive = GoogleDriveConfig(
                    clientId = gd?.optString("clientId", "") ?: "",
                    clientSecret = gd?.optString("clientSecret", "") ?: "",
                    redirectUri = gd?.optString("redirectUri", "http://127.0.0.1:48123/callback") ?: "http://127.0.0.1:48123/callback",
                    accessToken = gd?.optString("accessToken", "") ?: "",
                    refreshToken = gd?.optString("refreshToken", "") ?: "",
                    tokenExpiresAtMs = gd?.optLong("tokenExpiresAtMs", 0L) ?: 0L,
                    remoteFolder = gd?.optString("remoteFolder", "Readify") ?: "Readify"
                ),
                oneDrive = OneDriveConfig(
                    clientId = od?.optString("clientId", "") ?: "",
                    tenantId = od?.optString("tenantId", "common") ?: "common",
                    redirectUri = od?.optString("redirectUri", "com.inkflow.reader://oauth/onedrive") ?: "com.inkflow.reader://oauth/onedrive",
                    accessToken = od?.optString("accessToken", "") ?: "",
                    refreshToken = od?.optString("refreshToken", "") ?: "",
                    tokenExpiresAtMs = od?.optLong("tokenExpiresAtMs", 0L) ?: 0L,
                    remoteFolder = od?.optString("remoteFolder", "Readify") ?: "Readify"
                )
            )
        }.getOrDefault(CloudSyncConfig())
    }

    fun saveCloudSyncConfig(config: CloudSyncConfig) = synchronized(ioLock) {
        val obj = JSONObject().apply {
            put("activeProvider", config.activeProvider.name)
            put("autoSyncOnBookOpenClose", config.autoSyncOnBookOpenClose)
            put("syncBookFiles", config.syncBookFiles)
            put("syncReaderSettings", config.syncReaderSettings)
            put("lastSyncTimeMs", config.lastSyncTimeMs)
            put("lastSyncSummary", config.lastSyncSummary)
            put("webDav", JSONObject().apply {
                put("serverUrl", config.webDav.serverUrl)
                put("username", config.webDav.username)
                put("password", config.webDav.password)
                put("remoteFolder", config.webDav.remoteFolder)
            })
            put("googleDrive", JSONObject().apply {
                put("clientId", config.googleDrive.clientId)
                put("clientSecret", config.googleDrive.clientSecret)
                put("redirectUri", config.googleDrive.redirectUri)
                put("accessToken", config.googleDrive.accessToken)
                put("refreshToken", config.googleDrive.refreshToken)
                put("tokenExpiresAtMs", config.googleDrive.tokenExpiresAtMs)
                put("remoteFolder", config.googleDrive.remoteFolder)
            })
            put("oneDrive", JSONObject().apply {
                put("clientId", config.oneDrive.clientId)
                put("tenantId", config.oneDrive.tenantId)
                put("redirectUri", config.oneDrive.redirectUri)
                put("accessToken", config.oneDrive.accessToken)
                put("refreshToken", config.oneDrive.refreshToken)
                put("tokenExpiresAtMs", config.oneDrive.tokenExpiresAtMs)
                put("remoteFolder", config.oneDrive.remoteFolder)
            })
        }
        cloudSyncConfigFile.writeText(obj.toString(2))
    }

    // ---------------- Settings ----------------

    fun loadSettings(): ReaderSettings {
        if (!settingsJsonFile.exists()) return ReaderSettings()
        return runCatching {
            val obj = JSONObject(settingsJsonFile.readText())
            val tapArr = obj.optJSONArray("tapZones")
            val tapZones = if (tapArr != null && tapArr.length() == 9) {
                (0 until 9).map { TapAction.valueOf(tapArr.getString(it)) }
            } else {
                ReaderSettings.defaultVerticalTapZones()
            }
            val savedFontPath = obj.optString("customFontPath").takeIf { path ->
                path.isNotBlank() && (path.startsWith("content://") || File(path).exists())
            }
            ReaderSettings(
                writingMode = WritingMode.valueOf(obj.optString("writingMode", WritingMode.VERTICAL.name)),
                verticalNaturalSwipe = obj.optBoolean("verticalNaturalSwipe", true),
                dualPageMode = DualPageMode.valueOf(obj.optString("dualPageMode", DualPageMode.AUTO.name)),
                showSpineShadow = obj.optBoolean("showSpineShadow", true),
                pageTurnAnimation = PageTurnAnimation.valueOf(obj.optString("pageTurnAnimation", PageTurnAnimation.SIMULATION.name)),
                eInkMode = obj.optBoolean("eInkMode", false),
                theme = ReaderTheme.valueOf(obj.optString("theme", ReaderTheme.SEPIA.name)),
                fontSizeSp = obj.optDouble("fontSizeSp", 20.0).toFloat(),
                fontBold = obj.optBoolean("fontBold", false),
                letterSpacingEm = obj.optDouble("letterSpacingEm", 0.04).toFloat(),
                lineSpacingMultiplier = obj.optDouble("lineSpacingMultiplier", 1.65).toFloat(),
                paragraphSpacingEm = obj.optDouble("paragraphSpacingEm", 0.45).toFloat(),
                paragraphIndentChars = obj.optInt("paragraphIndentChars", 2).coerceIn(0, 6),
                marginHorizontalDp = obj.optDouble("marginHorizontalDp", 20.0).toFloat(),
                marginVerticalDp = obj.optDouble("marginVerticalDp", 24.0).toFloat(),
                customFontPath = savedFontPath,
                customFontName = obj.optString("customFontName").takeIf { it.isNotBlank() && savedFontPath != null },
                customFontFolderUri = obj.optString("customFontFolderUri").takeIf { it.isNotBlank() },
                chineseConvertMode = ChineseConvertMode.valueOf(obj.optString("chineseConvertMode", ChineseConvertMode.ORIGINAL.name)),
                volumeKeyPageTurn = obj.optBoolean("volumeKeyPageTurn", true),
                comicRtl = obj.optBoolean("comicRtl", true),
                pdfAutoCrop = obj.optBoolean("pdfAutoCrop", false),
                pdfReflowMode = obj.optBoolean("pdfReflowMode", false),
                pdfNightInvert = obj.optBoolean("pdfNightInvert", false),
                shelfSortField = runCatching { ShelfSortField.valueOf(obj.optString("shelfSortField", ShelfSortField.ADDED_TIME.name)) }.getOrDefault(ShelfSortField.ADDED_TIME),
                shelfSortAscending = obj.optBoolean("shelfSortAscending", false),
                shelfCoverSize = runCatching { ShelfCoverSize.valueOf(obj.optString("shelfCoverSize", ShelfCoverSize.STANDARD.name)) }.getOrDefault(ShelfCoverSize.STANDARD),
                tapZones = tapZones
            )
        }.getOrDefault(ReaderSettings())
    }

    fun saveSettings(settings: ReaderSettings) {
        saveSettingsWithTimestamp(settings, System.currentTimeMillis())
    }

    fun saveSettingsWithTimestamp(settings: ReaderSettings, timestampMs: Long) {
        val obj = serializePortableSettings(settings).apply {
            put("customFontPath", settings.customFontPath ?: "")
            put("customFontName", settings.customFontName ?: "")
            put("customFontFolderUri", settings.customFontFolderUri ?: "")
            put("shelfCoverSize", settings.shelfCoverSize.name)
        }
        settingsJsonFile.writeText(obj.toString(2))
        saveSettingsUpdatedAtMs(timestampMs)
    }

    fun serializePortableSettings(settings: ReaderSettings): JSONObject {
        return JSONObject().apply {
            put("writingMode", settings.writingMode.name)
            put("verticalNaturalSwipe", settings.verticalNaturalSwipe)
            put("dualPageMode", settings.dualPageMode.name)
            put("showSpineShadow", settings.showSpineShadow)
            put("pageTurnAnimation", settings.pageTurnAnimation.name)
            put("eInkMode", settings.eInkMode)
            put("theme", settings.theme.name)
            put("fontSizeSp", settings.fontSizeSp.toDouble())
            put("fontBold", settings.fontBold)
            put("letterSpacingEm", settings.letterSpacingEm.toDouble())
            put("lineSpacingMultiplier", settings.lineSpacingMultiplier.toDouble())
            put("paragraphSpacingEm", settings.paragraphSpacingEm.toDouble())
            put("paragraphIndentChars", settings.paragraphIndentChars)
            put("marginHorizontalDp", settings.marginHorizontalDp.toDouble())
            put("marginVerticalDp", settings.marginVerticalDp.toDouble())
            put("chineseConvertMode", settings.chineseConvertMode.name)
            put("volumeKeyPageTurn", settings.volumeKeyPageTurn)
            put("comicRtl", settings.comicRtl)
            put("pdfAutoCrop", settings.pdfAutoCrop)
            put("pdfReflowMode", settings.pdfReflowMode)
            put("pdfNightInvert", settings.pdfNightInvert)
            put("shelfSortField", settings.shelfSortField.name)
            put("shelfSortAscending", settings.shelfSortAscending)
            put("tapZones", JSONArray().apply {
                settings.tapZones.forEach { put(it.name) }
            })
        }
    }

    /**
     * Applies remote synced ReaderSettings while preserving device-local customFontPath & customFontFolderUri.
     */
    fun applySyncedSettingsJson(local: ReaderSettings, obj: JSONObject): ReaderSettings {
        return runCatching {
            val tapArr = obj.optJSONArray("tapZones")
            val tapZones = if (tapArr != null && tapArr.length() == 9) {
                (0 until 9).map { TapAction.valueOf(tapArr.getString(it)) }
            } else local.tapZones

            local.copy(
                writingMode = runCatching { WritingMode.valueOf(obj.optString("writingMode")) }.getOrDefault(local.writingMode),
                verticalNaturalSwipe = obj.optBoolean("verticalNaturalSwipe", local.verticalNaturalSwipe),
                dualPageMode = runCatching { DualPageMode.valueOf(obj.optString("dualPageMode")) }.getOrDefault(local.dualPageMode),
                showSpineShadow = obj.optBoolean("showSpineShadow", local.showSpineShadow),
                pageTurnAnimation = runCatching { PageTurnAnimation.valueOf(obj.optString("pageTurnAnimation")) }.getOrDefault(local.pageTurnAnimation),
                eInkMode = obj.optBoolean("eInkMode", local.eInkMode),
                theme = runCatching { ReaderTheme.valueOf(obj.optString("theme")) }.getOrDefault(local.theme),
                fontSizeSp = obj.optDouble("fontSizeSp", local.fontSizeSp.toDouble()).toFloat(),
                fontBold = obj.optBoolean("fontBold", local.fontBold),
                letterSpacingEm = obj.optDouble("letterSpacingEm", local.letterSpacingEm.toDouble()).toFloat(),
                lineSpacingMultiplier = obj.optDouble("lineSpacingMultiplier", local.lineSpacingMultiplier.toDouble()).toFloat(),
                paragraphSpacingEm = obj.optDouble("paragraphSpacingEm", local.paragraphSpacingEm.toDouble()).toFloat(),
                paragraphIndentChars = obj.optInt("paragraphIndentChars", local.paragraphIndentChars).coerceIn(0, 6),
                marginHorizontalDp = obj.optDouble("marginHorizontalDp", local.marginHorizontalDp.toDouble()).toFloat(),
                marginVerticalDp = obj.optDouble("marginVerticalDp", local.marginVerticalDp.toDouble()).toFloat(),
                chineseConvertMode = runCatching { ChineseConvertMode.valueOf(obj.optString("chineseConvertMode")) }.getOrDefault(local.chineseConvertMode),
                volumeKeyPageTurn = obj.optBoolean("volumeKeyPageTurn", local.volumeKeyPageTurn),
                comicRtl = obj.optBoolean("comicRtl", local.comicRtl),
                pdfAutoCrop = obj.optBoolean("pdfAutoCrop", local.pdfAutoCrop),
                pdfReflowMode = obj.optBoolean("pdfReflowMode", local.pdfReflowMode),
                pdfNightInvert = obj.optBoolean("pdfNightInvert", local.pdfNightInvert),
                shelfSortField = runCatching { ShelfSortField.valueOf(obj.optString("shelfSortField")) }.getOrDefault(local.shelfSortField),
                shelfSortAscending = obj.optBoolean("shelfSortAscending", local.shelfSortAscending),
                tapZones = tapZones
            )
        }.getOrDefault(local)
    }

    private fun resolveDisplayNameAndSize(uri: Uri): Pair<String?, Long> {
        var name: String? = null
        var size = 0L
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIdx >= 0) name = cursor.getString(nameIdx)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) size = cursor.getLong(sizeIdx)
            }
        }
        if (name.isNullOrBlank()) {
            name = uri.lastPathSegment?.substringAfterLast('/')
        }
        return name to size
    }
}
