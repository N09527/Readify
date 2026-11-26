package com.inkflow.reader.sync

import com.inkflow.reader.data.AppRepository
import com.inkflow.reader.model.*
import com.inkflow.reader.parser.BookParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class CloudSyncManager(private val repository: AppRepository) {

    companion object {
        private const val STATE_FILE = "sync_state.json"
        private const val BOOKS_SUBFOLDER = "books"
        private val syncMutex = Mutex()
    }

    fun createClient(
        config: CloudSyncConfig,
        onConfigUpdated: (CloudSyncConfig) -> Unit
    ): CloudStorageClient {
        return when (config.activeProvider) {
            CloudProviderType.WEBDAV -> WebDavClient(config.webDav)
            CloudProviderType.GOOGLE_DRIVE -> GoogleDriveClient(config.googleDrive) { updatedGDrive ->
                val newCfg = repository.loadCloudSyncConfig().copy(googleDrive = updatedGDrive)
                repository.saveCloudSyncConfig(newCfg)
                onConfigUpdated(newCfg)
            }
            CloudProviderType.ONEDRIVE -> OneDriveClient(config.oneDrive) { updatedOneDrive ->
                val newCfg = repository.loadCloudSyncConfig().copy(oneDrive = updatedOneDrive)
                repository.saveCloudSyncConfig(newCfg)
                onConfigUpdated(newCfg)
            }
        }
    }

    suspend fun testConnection(
        config: CloudSyncConfig,
        onConfigUpdated: (CloudSyncConfig) -> Unit
    ): Result<String> {
        val client = createClient(config, onConfigUpdated)
        return client.testConnection()
    }

    suspend fun listCloudFiles(
        config: CloudSyncConfig,
        onConfigUpdated: (CloudSyncConfig) -> Unit
    ): Result<List<RemoteFileEntry>> = withContext(Dispatchers.IO) {
        runCatching {
            val client = createClient(config, onConfigUpdated)
            client.ensureRootFolder().getOrThrow()
            val rootEntries = client.listFiles("").getOrThrow()
            val bookEntries = client.listFiles(BOOKS_SUBFOLDER).getOrDefault(emptyList())
                .map { it.copy(name = "$BOOKS_SUBFOLDER/${it.name}") }
            (rootEntries.filterNot { it.isDirectory && it.name.equals(BOOKS_SUBFOLDER, ignoreCase = true) } + bookEntries)
                .sortedBy { it.name.lowercase() }
        }
    }

    /**
     * Performs full two-way sync across WebDAV / Google Drive / Microsoft OneDrive:
     *  1. Ensures remote root & books directories exist.
     *  2. Downloads remote sync_state.json (if present).
     *  3. Matches local & remote books by id, fast contentHash, or (sourceFileName + size).
     *  4. Merges reading progress (latest lastReadTime wins) & multi-tags.
     *  5. If effectiveSyncBookFiles is enabled, uploads missing local books & downloads missing remote books.
     *  6. Merges bookmarks (union minus merged deletedBookmarkIds tombstones).
     *  7. Optionally merges ReaderSettings (latest settingsUpdatedAtMs wins, preserving local font paths).
     *  8. Saves merged state locally and uploads updated sync_state.json to cloud.
     */
    suspend fun syncNow(
        config: CloudSyncConfig,
        syncBookFilesOverride: Boolean? = null,
        onConfigUpdated: (CloudSyncConfig) -> Unit,
        onProgress: suspend (String) -> Unit
    ): Result<SyncReport> = withContext(Dispatchers.IO) {
        syncMutex.withLock {
            runCatching {
                val effectiveSyncBookFiles = syncBookFilesOverride ?: config.syncBookFiles
                val client = createClient(config, onConfigUpdated)
                val errors = mutableListOf<String>()
                var uploadedBooks = 0
                var downloadedBooks = 0

                onProgress("正在連線 ${config.activeProvider.label} 並檢查同步目錄…")
                client.ensureRootFolder().getOrThrow()

                // Ensure all local books have a contentHash computed before matching
                onProgress("正在掃描本機書架與計算書籍指紋…")
                val localBooks = repository.loadBooks().map { book ->
                    val f = File(book.localPath)
                    if (book.contentHash.isBlank() && f.exists()) {
                        book.copy(
                            contentHash = repository.computeFastFingerprint(f),
                            fileSizeBytes = if (book.fileSizeBytes > 0L) book.fileSizeBytes else f.length()
                        )
                    } else book
                }.toMutableList()

                val localBookmarks = repository.loadAllBookmarksPublic()
                val localDeletedBookmarks = repository.loadDeletedBookmarkIds()
                val localSettings = repository.loadSettings()
                val localSettingsUpdatedAt = repository.loadSettingsUpdatedAtMs()

                onProgress("正在下載雲端同步紀錄 ($STATE_FILE)…")
                val remoteStateBytes = client.downloadBytes(STATE_FILE).getOrThrow()
                val remoteJson = remoteStateBytes?.let { bytes ->
                    runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull()
                }

                val remoteBooks = parseRemoteBooks(remoteJson)
                val remoteBookmarks = parseRemoteBookmarks(remoteJson)
                val remoteDeletedBookmarks = parseRemoteStringSet(remoteJson, "deletedBookmarkIds")
                val remoteSettingsUpdatedAt = remoteJson?.optLong("settingsUpdatedAtMs", 0L) ?: 0L
                val remoteSettingsObj = remoteJson?.optJSONObject("settings")

                // Query existing files in remote books/ folder to avoid redundant uploads
                val existingRemoteBookFiles: Set<String> = if (effectiveSyncBookFiles) {
                    onProgress("正在比對雲端書檔清單…")
                    client.listFiles(BOOKS_SUBFOLDER).getOrDefault(emptyList())
                        .filterNot { it.isDirectory }
                        .map { it.name }
                        .toSet()
                } else emptySet()

                // Map old local book ID -> canonical synced book ID (for remapping bookmarks if two devices imported same file separately)
                val bookIdRemap = mutableMapOf<String, String>()
                val mergedBooks = mutableListOf<BookItem>()
                val matchedRemoteIds = mutableSetOf<String>()

                // Step A: Reconcile all local books against remote records
                for (local in localBooks) {
                    val remoteMatch = findMatchingRemoteBook(local, remoteBooks, matchedRemoteIds)
                    if (remoteMatch != null) {
                        matchedRemoteIds.add(remoteMatch.id)
                        val canonicalId = remoteMatch.id
                        if (local.id != canonicalId) {
                            bookIdRemap[local.id] = canonicalId
                        }
                        val merged = if (remoteMatch.lastReadTime > local.lastReadTime) {
                            local.copy(
                                id = canonicalId,
                                tags = if (remoteMatch.tags.isNotEmpty()) remoteMatch.tags else local.tags,
                                lastChapterIndex = remoteMatch.lastChapterIndex,
                                lastCharOffset = remoteMatch.lastCharOffset,
                                lastPageIndex = remoteMatch.lastPageIndex,
                                lastReadTime = remoteMatch.lastReadTime,
                                contentType = remoteMatch.contentType,
                                readingProgress = remoteMatch.readingProgress,
                                isRead = remoteMatch.isRead,
                                hasStartedReading = remoteMatch.hasStartedReading
                            )
                        } else {
                            local.copy(id = canonicalId)
                        }
                        mergedBooks.add(merged)

                        if (effectiveSyncBookFiles) {
                            val remoteFileName = buildRemoteBookFileName(merged)
                            if (remoteFileName !in existingRemoteBookFiles) {
                                val localFile = File(merged.localPath)
                                if (localFile.exists()) {
                                    onProgress("正在上傳書檔：${merged.title}…")
                                    client.uploadFile("$BOOKS_SUBFOLDER/$remoteFileName", localFile)
                                        .onSuccess { uploadedBooks++ }
                                        .onFailure { errors.add("上傳「${merged.title}」失敗：${it.message}") }
                                }
                            }
                        }
                    } else {
                        // Local-only book -> keep locally & upload to cloud if enabled
                        mergedBooks.add(local)
                        if (effectiveSyncBookFiles) {
                            val remoteFileName = buildRemoteBookFileName(local)
                            if (remoteFileName !in existingRemoteBookFiles) {
                                val localFile = File(local.localPath)
                                if (localFile.exists()) {
                                    onProgress("正在上傳書檔：${local.title}…")
                                    client.uploadFile("$BOOKS_SUBFOLDER/$remoteFileName", localFile)
                                        .onSuccess { uploadedBooks++ }
                                        .onFailure { errors.add("上傳「${local.title}」失敗：${it.message}") }
                                }
                            }
                        }
                    }
                }

                // Step B: Download remote-only books (if effectiveSyncBookFiles is enabled)
                val unmatchedRemoteBooks = remoteBooks.filter { it.id !in matchedRemoteIds }
                val preservedRemoteOnlyRecords = mutableListOf<RemoteBookRecord>()

                for (remote in unmatchedRemoteBooks) {
                    if (effectiveSyncBookFiles) {
                    val remoteFileName = remote.remoteFileName.ifBlank {
                        "${remote.id}.${remote.ext.ifBlank { remote.format.name.lowercase() }}"
                    }
                    val destFile = File(repository.getBooksDir(), "${remote.id}.${remote.ext.ifBlank { remote.format.name.lowercase() }}")
                    onProgress("正在從雲端下載：${remote.title}…")
                    val dlRes = client.downloadFile("$BOOKS_SUBFOLDER/$remoteFileName", destFile)
                    val downloaded = dlRes.getOrDefault(false)
                    if (dlRes.isFailure) {
                        errors.add("下載「${remote.title}」失敗：${dlRes.exceptionOrNull()?.message}")
                        preservedRemoteOnlyRecords.add(remote)
                    } else if (downloaded && destFile.exists() && destFile.length() > 0L) {
                        val parsed = runCatching {
                            BookParser.parseMetadataAndCover(destFile, remote.format, remote.title)
                        }.getOrNull()

                        var coverPath: String? = null
                        val coverBytes = parsed?.coverBytes
                        if (coverBytes != null && coverBytes.isNotEmpty()) {
                            val coverFile = File(repository.getCoversDir(), "${remote.id}.img")
                            coverFile.writeBytes(coverBytes)
                            coverPath = coverFile.absolutePath
                        }

                        val newLocal = BookItem(
                            id = remote.id,
                            title = remote.title.ifBlank { parsed?.title ?: remote.sourceFileName },
                            author = remote.author.ifBlank { parsed?.author ?: "未知作者" },
                            format = remote.format,
                            contentType = remote.contentType,
                            localPath = destFile.absolutePath,
                            coverPath = coverPath,
                            tags = remote.tags,
                            lastChapterIndex = remote.lastChapterIndex,
                            lastCharOffset = remote.lastCharOffset,
                            lastPageIndex = remote.lastPageIndex,
                            lastReadTime = remote.lastReadTime,
                            addedTime = remote.addedTime,
                            sourceFileName = remote.sourceFileName,
                            fileSizeBytes = destFile.length(),
                            contentHash = remote.contentHash.ifBlank { repository.computeFastFingerprint(destFile) },
                            readingProgress = remote.readingProgress,
                            isRead = remote.isRead,
                            hasStartedReading = remote.hasStartedReading
                        )
                        mergedBooks.add(newLocal)
                        downloadedBooks++
                    } else {
                        // Book file wasn't on cloud (e.g. other device disabled syncBookFiles) -> keep its metadata in remote state
                        preservedRemoteOnlyRecords.add(remote)
                    }
                } else {
                    preservedRemoteOnlyRecords.add(remote)
                }
            }

            // Step C: Merge Bookmarks (union minus deleted tombstones)
            onProgress("正在合併書籤資料…")
            val mergedDeletedBookmarks = localDeletedBookmarks + remoteDeletedBookmarks
            val bookmarkMap = LinkedHashMap<String, BookmarkItem>()
            for (bm in remoteBookmarks) {
                if (bm.id !in mergedDeletedBookmarks) {
                    bookmarkMap[bm.id] = bm
                }
            }
            for (bm in localBookmarks) {
                if (bm.id !in mergedDeletedBookmarks) {
                    val mappedBookId = bookIdRemap[bm.bookId] ?: bm.bookId
                    bookmarkMap[bm.id] = bm.copy(bookId = mappedBookId)
                }
            }
            val mergedBookmarks = bookmarkMap.values.sortedByDescending { it.createdAt }

            // Step D: Optionally merge ReaderSettings (preserving local device-specific font paths!)
            var effectiveSettings = localSettings
            var effectiveSettingsUpdatedAt = localSettingsUpdatedAt
            var settingsSynced = false
            if (config.syncReaderSettings && remoteSettingsObj != null && remoteSettingsUpdatedAt > localSettingsUpdatedAt) {
                effectiveSettings = repository.applySyncedSettingsJson(localSettings, remoteSettingsObj)
                effectiveSettingsUpdatedAt = remoteSettingsUpdatedAt
                repository.saveSettingsWithTimestamp(effectiveSettings, effectiveSettingsUpdatedAt)
                settingsSynced = true
            }

            // Step E: Persist merged state locally
            repository.saveBooks(mergedBooks)
            repository.saveAllBookmarksPublic(mergedBookmarks)
            repository.saveDeletedBookmarkIds(mergedDeletedBookmarks)

            // Step F: Upload merged sync_state.json to cloud
            onProgress("正在上傳合併後的雲端同步紀錄…")
            val allRemoteRecords = mergedBooks.map { toRemoteBookRecord(it) } + preservedRemoteOnlyRecords
            val statePayload = buildSyncStateJson(
                books = allRemoteRecords,
                bookmarks = mergedBookmarks,
                deletedBookmarkIds = mergedDeletedBookmarks,
                settings = if (config.syncReaderSettings) effectiveSettings else null,
                settingsUpdatedAtMs = effectiveSettingsUpdatedAt
            )
            client.uploadBytes(
                remotePath = STATE_FILE,
                data = statePayload.toString(2).toByteArray(Charsets.UTF_8),
                contentType = "application/json; charset=utf-8"
            ).getOrThrow()

            val report = SyncReport(
                provider = config.activeProvider,
                uploadedBooks = uploadedBooks,
                downloadedBooks = downloadedBooks,
                mergedBooksCount = mergedBooks.size,
                mergedBookmarksCount = mergedBookmarks.size,
                settingsSynced = settingsSynced || config.syncReaderSettings,
                errors = errors
            )

            val refreshedCfg = repository.loadCloudSyncConfig().copy(
                lastSyncTimeMs = System.currentTimeMillis(),
                lastSyncSummary = report.toDisplaySummary()
            )
            repository.saveCloudSyncConfig(refreshedCfg)
            onConfigUpdated(refreshedCfg)

            report
            }
        }
    }

    // ---------------- Internal Serialization & Matching ----------------

    private data class RemoteBookRecord(
        val id: String,
        val title: String,
        val author: String,
        val format: BookFormat,
        val contentType: BookContentType,
        val ext: String,
        val remoteFileName: String,
        val tags: List<String>,
        val lastChapterIndex: Int,
        val lastCharOffset: Int,
        val lastPageIndex: Int,
        val lastReadTime: Long,
        val addedTime: Long,
        val sourceFileName: String,
        val fileSizeBytes: Long,
        val contentHash: String,
        val readingProgress: Float,
        val isRead: Boolean,
        val hasStartedReading: Boolean
    )

    private fun buildRemoteBookFileName(book: BookItem): String {
        val ext = File(book.localPath).extension.lowercase().ifBlank { book.format.name.lowercase() }
        return "${book.id}.$ext"
    }

    private fun toRemoteBookRecord(book: BookItem): RemoteBookRecord {
        val ext = File(book.localPath).extension.lowercase().ifBlank { book.format.name.lowercase() }
        return RemoteBookRecord(
            id = book.id,
            title = book.title,
            author = book.author,
            format = book.format,
            contentType = book.contentType,
            ext = ext,
            remoteFileName = "${book.id}.$ext",
            tags = repository.sanitizeTags(book.tags),
            lastChapterIndex = book.lastChapterIndex,
            lastCharOffset = book.lastCharOffset,
            lastPageIndex = book.lastPageIndex,
            lastReadTime = book.lastReadTime,
            addedTime = book.addedTime,
            sourceFileName = book.sourceFileName,
            fileSizeBytes = book.fileSizeBytes,
            contentHash = book.contentHash,
            readingProgress = book.readingProgress,
            isRead = book.isRead,
            hasStartedReading = book.hasStartedReading
        )
    }

    private fun findMatchingRemoteBook(
        local: BookItem,
        remoteBooks: List<RemoteBookRecord>,
        alreadyMatchedIds: Set<String>
    ): RemoteBookRecord? {
        val candidates = remoteBooks.filter { it.id !in alreadyMatchedIds }
        // 1. Exact book ID match
        candidates.find { it.id == local.id }?.let { return it }
        // 2. Fast content hash match (same book imported separately on 2 devices)
        if (local.contentHash.isNotBlank()) {
            candidates.find { it.contentHash.isNotBlank() && it.contentHash == local.contentHash }?.let { return it }
        }
        // 3. Fallback: same source filename & file size
        if (local.sourceFileName.isNotBlank() && local.fileSizeBytes > 0L) {
            candidates.find {
                it.sourceFileName.equals(local.sourceFileName, ignoreCase = true) && it.fileSizeBytes == local.fileSizeBytes
            }?.let { return it }
        }
        return null
    }

    private fun parseRemoteBooks(root: JSONObject?): List<RemoteBookRecord> {
        val arr = root?.optJSONArray("books") ?: return emptyList()
        val list = mutableListOf<RemoteBookRecord>()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val fmt = runCatching { BookFormat.valueOf(obj.optString("format", "TXT")) }.getOrDefault(BookFormat.TXT)
            val ct = runCatching { BookContentType.valueOf(obj.optString("contentType", "TEXT")) }.getOrDefault(BookContentType.TEXT)
            val id = obj.optString("id").trim()
            if (id.isBlank()) continue
            list.add(
                RemoteBookRecord(
                    id = id,
                    title = obj.optString("title", "未命名"),
                    author = obj.optString("author", "未知作者"),
                    format = fmt,
                    contentType = ct,
                    ext = obj.optString("ext", fmt.name.lowercase()),
                    remoteFileName = obj.optString("remoteFileName", "$id.${fmt.name.lowercase()}"),
                    tags = run {
                        val tArr = obj.optJSONArray("tags")
                        if (tArr != null) {
                            repository.sanitizeTags((0 until tArr.length()).map { idx -> tArr.optString(idx) })
                        } else {
                            val legacy = obj.optString("groupName", "").trim()
                            if (legacy.isNotBlank() && legacy != "未分類") listOf(legacy) else emptyList()
                        }
                    },
                    lastChapterIndex = obj.optInt("lastChapterIndex", 0),
                    lastCharOffset = obj.optInt("lastCharOffset", 0),
                    lastPageIndex = obj.optInt("lastPageIndex", 0),
                    lastReadTime = obj.optLong("lastReadTime", 0L),
                    addedTime = obj.optLong("addedTime", System.currentTimeMillis()),
                    sourceFileName = obj.optString("sourceFileName", ""),
                    fileSizeBytes = obj.optLong("fileSizeBytes", 0L),
                    contentHash = obj.optString("contentHash", ""),
                    readingProgress = obj.optDouble("readingProgress", 0.0).toFloat().coerceIn(0f, 1f),
                    isRead = obj.optBoolean("isRead", false),
                    hasStartedReading = obj.optBoolean("hasStartedReading", false)
                )
            )
        }
        return list
    }

    private fun parseRemoteBookmarks(root: JSONObject?): List<BookmarkItem> {
        val arr = root?.optJSONArray("bookmarks") ?: return emptyList()
        val list = mutableListOf<BookmarkItem>()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val id = obj.optString("id").trim()
            val bookId = obj.optString("bookId").trim()
            if (id.isBlank() || bookId.isBlank()) continue
            list.add(
                BookmarkItem(
                    id = id,
                    bookId = bookId,
                    chapterIndex = obj.optInt("chapterIndex", 0),
                    chapterTitle = obj.optString("chapterTitle", ""),
                    charOffset = obj.optInt("charOffset", 0),
                    preview = obj.optString("preview", ""),
                    createdAt = obj.optLong("createdAt", System.currentTimeMillis())
                )
            )
        }
        return list
    }

    private fun parseRemoteStringSet(root: JSONObject?, key: String): Set<String> {
        val arr = root?.optJSONArray(key) ?: return emptySet()
        val set = mutableSetOf<String>()
        for (i in 0 until arr.length()) {
            val v = arr.optString(i).trim()
            if (v.isNotBlank()) set.add(v)
        }
        return set
    }

    private fun buildSyncStateJson(
        books: List<RemoteBookRecord>,
        bookmarks: List<BookmarkItem>,
        deletedBookmarkIds: Set<String>,
        settings: ReaderSettings?,
        settingsUpdatedAtMs: Long
    ): JSONObject {
        val booksArr = JSONArray()
        books.forEach { b ->
            booksArr.put(JSONObject().apply {
                put("id", b.id)
                put("title", b.title)
                put("author", b.author)
                put("format", b.format.name)
                put("contentType", b.contentType.name)
                put("ext", b.ext)
                put("remoteFileName", b.remoteFileName)
                put("tags", JSONArray().apply { repository.sanitizeTags(b.tags).forEach { put(it) } })
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

        val bmArr = JSONArray()
        bookmarks.forEach { bm ->
            bmArr.put(JSONObject().apply {
                put("id", bm.id)
                put("bookId", bm.bookId)
                put("chapterIndex", bm.chapterIndex)
                put("chapterTitle", bm.chapterTitle)
                put("charOffset", bm.charOffset)
                put("preview", bm.preview)
                put("createdAt", bm.createdAt)
            })
        }

        val delArr = JSONArray()
        deletedBookmarkIds.forEach { delArr.put(it) }

        return JSONObject().apply {
            put("schemaVersion", 1)
            put("updatedAtMs", System.currentTimeMillis())
            put("books", booksArr)
            put("bookmarks", bmArr)
            put("deletedBookmarkIds", delArr)
            put("settingsUpdatedAtMs", settingsUpdatedAtMs)
            if (settings != null) {
                put("settings", repository.serializePortableSettings(settings))
            }
        }
    }
}
