package com.inkflow.reader.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class GoogleDriveClient(
    initialConfig: GoogleDriveConfig,
    private val onTokensUpdated: (GoogleDriveConfig) -> Unit
) : CloudStorageClient {

    override val providerType: CloudProviderType = CloudProviderType.GOOGLE_DRIVE

    private var config: GoogleDriveConfig = initialConfig
    private val rootFolderName: String = config.remoteFolder.trim().trim('/').ifBlank { "Readify" }

    private var cachedRootFolderId: String? = null
    private var cachedBooksFolderId: String? = null

    private suspend fun getValidAccessToken(): String {
        val now = System.currentTimeMillis()
        if (config.accessToken.isNotBlank() && (config.tokenExpiresAtMs == 0L || now < config.tokenExpiresAtMs - 60_000L)) {
            return config.accessToken
        }
        val refreshed = OAuthPkceHelper.refreshGoogleToken(config).getOrThrow()
        config = config.copy(
            accessToken = refreshed.accessToken,
            refreshToken = refreshed.refreshToken,
            tokenExpiresAtMs = refreshed.expiresAtMs
        )
        onTokensUpdated(config)
        return config.accessToken
    }

    override suspend fun testConnection(): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            if (!config.isAuthorized) throw IllegalStateException("尚未授權 Google Drive，請先點擊登入")
            ensureRootFolder().getOrThrow()
            val files = listFiles("").getOrThrow()
            "Google Drive 連線成功！資料夾「$rootFolderName」目前有 ${files.size} 個項目。"
        }
    }

    override suspend fun ensureRootFolder(): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val rootId = cachedRootFolderId ?: findOrCreateFolder(token, rootFolderName, parentId = null)
            cachedRootFolderId = rootId
            val booksId = cachedBooksFolderId ?: findOrCreateFolder(token, "books", parentId = rootId)
            cachedBooksFolderId = booksId
        }
    }

    override suspend fun listFiles(subFolder: String): Result<List<RemoteFileEntry>> = withContext(Dispatchers.IO) {
        runCatching {
            ensureRootFolder().getOrThrow()
            val token = getValidAccessToken()
            val folderId = resolveParentFolderId(token, subFolder.trim().trim('/'))
            val q = "'$folderId' in parents and trashed = false"
            val url = "https://www.googleapis.com/drive/v3/files" +
                "?q=${URLEncoder.encode(q, "UTF-8")}" +
                "&fields=${URLEncoder.encode("files(id,name,size,mimeType)", "UTF-8")}" +
                "&pageSize=1000"
            val body = executeJsonGet(token, url)
            val filesArr = JSONObject(body).optJSONArray("files") ?: JSONArray()
            val result = mutableListOf<RemoteFileEntry>()
            for (i in 0 until filesArr.length()) {
                val obj = filesArr.getJSONObject(i)
                result.add(
                    RemoteFileEntry(
                        name = obj.optString("name"),
                        sizeBytes = obj.optString("size", "0").toLongOrNull() ?: 0L,
                        isDirectory = obj.optString("mimeType") == "application/vnd.google-apps.folder",
                        remoteId = obj.optString("id")
                    )
                )
            }
            result
        }
    }

    override suspend fun downloadBytes(remotePath: String): Result<ByteArray?> = withContext(Dispatchers.IO) {
        runCatching {
            ensureRootFolder().getOrThrow()
            val token = getValidAccessToken()
            val (folderId, fileName) = resolveParentAndFileName(token, remotePath)
            val fileId = findFileIdInFolder(token, folderId, fileName) ?: return@runCatching null

            val conn = openAuthedConn("https://www.googleapis.com/drive/v3/files/$fileId?alt=media", "GET", token)
            try {
                val code = conn.responseCode
                if (code == 404) return@runCatching null
                if (code !in 200..299) {
                    throw IllegalStateException("Google Drive 下載失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
                }
                conn.inputStream.use { it.readBytes() }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun downloadFile(remotePath: String, destFile: File): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            ensureRootFolder().getOrThrow()
            val token = getValidAccessToken()
            val (folderId, fileName) = resolveParentAndFileName(token, remotePath)
            val fileId = findFileIdInFolder(token, folderId, fileName) ?: return@runCatching false

            val conn = openAuthedConn("https://www.googleapis.com/drive/v3/files/$fileId?alt=media", "GET", token)
            try {
                val code = conn.responseCode
                if (code == 404) return@runCatching false
                if (code !in 200..299) {
                    throw IllegalStateException("Google Drive 下載書檔失敗 (HTTP $code)")
                }
                destFile.parentFile?.mkdirs()
                conn.inputStream.use { input ->
                    FileOutputStream(destFile).use { output ->
                        input.copyTo(output, bufferSize = 32 * 1024)
                    }
                }
                true
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun uploadBytes(remotePath: String, data: ByteArray, contentType: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            ensureRootFolder().getOrThrow()
            val token = getValidAccessToken()
            val (folderId, fileName) = resolveParentAndFileName(token, remotePath)
            val existingId = findFileIdInFolder(token, folderId, fileName)
            val uploadUrl = initiateResumableSession(token, folderId, fileName, existingId, contentType, data.size.toLong())

            val conn = (URL(uploadUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "PUT"
                connectTimeout = 20_000
                readTimeout = 60_000
                doOutput = true
                setFixedLengthStreamingMode(data.size)
                setRequestProperty("Content-Type", contentType)
            }
            try {
                conn.outputStream.use { it.write(data) }
                val code = conn.responseCode
                if (code !in 200..299) {
                    throw IllegalStateException("Google Drive 上傳資料失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun uploadFile(remotePath: String, sourceFile: File, contentType: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            ensureRootFolder().getOrThrow()
            val token = getValidAccessToken()
            val (folderId, fileName) = resolveParentAndFileName(token, remotePath)
            val existingId = findFileIdInFolder(token, folderId, fileName)
            val fileLen = sourceFile.length()
            val uploadUrl = initiateResumableSession(token, folderId, fileName, existingId, contentType, fileLen)

            val conn = (URL(uploadUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "PUT"
                connectTimeout = 20_000
                readTimeout = 120_000
                doOutput = true
                setFixedLengthStreamingMode(fileLen)
                setRequestProperty("Content-Type", contentType)
            }
            try {
                conn.outputStream.use { output ->
                    FileInputStream(sourceFile).use { input ->
                        input.copyTo(output, bufferSize = 32 * 1024)
                    }
                }
                val code = conn.responseCode
                if (code !in 200..299) {
                    throw IllegalStateException("Google Drive 上傳書檔失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun deleteFile(remotePath: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            ensureRootFolder().getOrThrow()
            val token = getValidAccessToken()
            val (folderId, fileName) = resolveParentAndFileName(token, remotePath)
            val fileId = findFileIdInFolder(token, folderId, fileName) ?: return@runCatching
            val conn = openAuthedConn("https://www.googleapis.com/drive/v3/files/$fileId", "DELETE", token)
            try {
                val code = conn.responseCode
                if (code !in 200..299 && code != 404) {
                    throw IllegalStateException("Google Drive 刪除失敗 (HTTP $code)")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun resolveParentAndFileName(token: String, remotePath: String): Pair<String, String> {
        val clean = remotePath.trim().trim('/')
        val slash = clean.lastIndexOf('/')
        return if (slash < 0) {
            resolveParentFolderId(token, "") to clean
        } else {
            val sub = clean.substring(0, slash)
            val name = clean.substring(slash + 1)
            resolveParentFolderId(token, sub) to name
        }
    }

    private fun resolveParentFolderId(token: String, subFolder: String): String {
        val rootId = cachedRootFolderId ?: throw IllegalStateException("尚未初始化 Google Drive 根目錄")
        if (subFolder.isBlank()) return rootId
        if (subFolder == "books" && cachedBooksFolderId != null) return cachedBooksFolderId!!
        var cur = rootId
        for (seg in subFolder.split("/").filter { it.isNotEmpty() }) {
            cur = findOrCreateFolder(token, seg, cur)
        }
        return cur
    }

    private fun findOrCreateFolder(token: String, name: String, parentId: String?): String {
        val escaped = name.replace("'", "\\'")
        val parentClause = if (parentId != null) " and '$parentId' in parents" else " and 'root' in parents"
        val q = "name = '$escaped' and mimeType = 'application/vnd.google-apps.folder' and trashed = false$parentClause"
        val url = "https://www.googleapis.com/drive/v3/files?q=${URLEncoder.encode(q, "UTF-8")}&fields=files(id,name)&pageSize=5"
        val body = executeJsonGet(token, url)
        val arr = JSONObject(body).optJSONArray("files")
        if (arr != null && arr.length() > 0) {
            return arr.getJSONObject(0).getString("id")
        }

        val meta = JSONObject().apply {
            put("name", name)
            put("mimeType", "application/vnd.google-apps.folder")
            if (parentId != null) put("parents", JSONArray().put(parentId))
        }
        val conn = openAuthedConn("https://www.googleapis.com/drive/v3/files?fields=id", "POST", token).apply {
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=UTF-8")
        }
        try {
            conn.outputStream.use { it.write(meta.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val resp = SyncHttpUtils.readResponseText(conn)
            if (code !in 200..299) {
                throw IllegalStateException("建立 Google Drive 資料夾失敗 (HTTP $code)：${resp.take(200)}")
            }
            return JSONObject(resp).getString("id")
        } finally {
            conn.disconnect()
        }
    }

    private fun findFileIdInFolder(token: String, folderId: String, fileName: String): String? {
        val escaped = fileName.replace("'", "\\'")
        val q = "name = '$escaped' and '$folderId' in parents and trashed = false"
        val url = "https://www.googleapis.com/drive/v3/files?q=${URLEncoder.encode(q, "UTF-8")}&fields=files(id)&pageSize=5"
        val body = executeJsonGet(token, url)
        val arr = JSONObject(body).optJSONArray("files")
        return if (arr != null && arr.length() > 0) arr.getJSONObject(0).getString("id") else null
    }

    private fun initiateResumableSession(
        token: String,
        folderId: String,
        fileName: String,
        existingFileId: String?,
        contentType: String,
        contentLength: Long
    ): String {
        val url = if (existingFileId != null) {
            "https://www.googleapis.com/upload/drive/v3/files/$existingFileId?uploadType=resumable"
        } else {
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable"
        }
        val meta = JSONObject().apply {
            put("name", fileName)
            if (existingFileId == null) {
                put("parents", JSONArray().put(folderId))
            }
        }
        val conn = openAuthedConn(url, "POST", token).apply {
            doOutput = true
            if (existingFileId != null) {
                // Officially supported by Google APIs; avoids HttpURLConnection PATCH limitations
                setRequestProperty("X-HTTP-Method-Override", "PATCH")
            }
            setRequestProperty("Content-Type", "application/json; charset=UTF-8")
            setRequestProperty("X-Upload-Content-Type", contentType)
            setRequestProperty("X-Upload-Content-Length", contentLength.toString())
        }
        try {
            conn.outputStream.use { it.write(meta.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("初始化 Google Drive 上傳失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
            }
            return conn.getHeaderField("Location")
                ?: throw IllegalStateException("Google Drive 未回傳上傳網址 (Location)")
        } finally {
            conn.disconnect()
        }
    }

    private fun executeJsonGet(token: String, urlStr: String): String {
        val conn = openAuthedConn(urlStr, "GET", token)
        try {
            val code = conn.responseCode
            val body = SyncHttpUtils.readResponseText(conn)
            if (code !in 200..299) {
                throw IllegalStateException("Google Drive API 錯誤 (HTTP $code)：${body.take(220)}")
            }
            return body
        } finally {
            conn.disconnect()
        }
    }

    private fun openAuthedConn(urlStr: String, method: String, token: String): HttpURLConnection {
        return (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 20_000
            readTimeout = 60_000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/json")
        }
    }
}
