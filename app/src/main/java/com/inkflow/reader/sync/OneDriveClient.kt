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

class OneDriveClient(
    initialConfig: OneDriveConfig,
    private val onTokensUpdated: (OneDriveConfig) -> Unit
) : CloudStorageClient {

    override val providerType: CloudProviderType = CloudProviderType.ONEDRIVE

    private var config: OneDriveConfig = initialConfig
    private val rootFolderName: String = config.remoteFolder.trim().trim('/').ifBlank { "Readify" }

    // 4 MB threshold for simple PUT vs Microsoft Graph Upload Session; chunk size MUST be a multiple of 320 KiB
    private val simpleUploadLimit = 4 * 1024 * 1024L
    private val uploadChunkSize = 10 * 320 * 1024 // 3,276,800 bytes

    private suspend fun getValidAccessToken(): String {
        val now = System.currentTimeMillis()
        if (config.accessToken.isNotBlank() && (config.tokenExpiresAtMs == 0L || now < config.tokenExpiresAtMs - 60_000L)) {
            return config.accessToken
        }
        val refreshed = OAuthPkceHelper.refreshOneDriveToken(config).getOrThrow()
        config = config.copy(
            accessToken = refreshed.accessToken,
            refreshToken = refreshed.refreshToken,
            tokenExpiresAtMs = refreshed.expiresAtMs
        )
        onTokensUpdated(config)
        return config.accessToken
    }

    private fun buildItemPathUrl(remotePath: String, suffix: String = ""): String {
        val clean = remotePath.trim().trim('/')
        val fullPath = if (clean.isEmpty()) rootFolderName else "$rootFolderName/$clean"
        val encoded = SyncHttpUtils.urlEncodePath(fullPath)
        return "https://graph.microsoft.com/v1.0/me/drive/root:/$encoded$suffix"
    }

    override suspend fun testConnection(): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            if (!config.isAuthorized) throw IllegalStateException("尚未授權 OneDrive，請先點擊登入")
            ensureRootFolder().getOrThrow()
            val files = listFiles("").getOrThrow()
            "OneDrive 連線成功！資料夾「$rootFolderName」目前有 ${files.size} 個項目。"
        }
    }

    override suspend fun ensureRootFolder(): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            var parentPath = ""
            for (seg in rootFolderName.split("/").filter { it.isNotEmpty() }) {
                ensureSingleFolder(token, parentPath, seg)
                parentPath = if (parentPath.isEmpty()) seg else "$parentPath/$seg"
            }
            ensureSingleFolder(token, parentPath, "books")
        }
    }

    private fun ensureSingleFolder(token: String, parentPath: String, folderName: String) {
        val checkPath = if (parentPath.isEmpty()) folderName else "$parentPath/$folderName"
        val checkUrl = "https://graph.microsoft.com/v1.0/me/drive/root:/${SyncHttpUtils.urlEncodePath(checkPath)}"
        val checkConn = openGraphConn(checkUrl, "GET", token)
        val exists = try {
            val code = checkConn.responseCode
            if (code in 200..299) true
            else if (code == 404) false
            else throw IllegalStateException("檢查 OneDrive 資料夾失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(checkConn).take(200)}")
        } finally {
            checkConn.disconnect()
        }
        if (exists) return

        val createUrl = if (parentPath.isEmpty()) {
            "https://graph.microsoft.com/v1.0/me/drive/root/children"
        } else {
            "https://graph.microsoft.com/v1.0/me/drive/root:/${SyncHttpUtils.urlEncodePath(parentPath)}:/children"
        }
        val payload = JSONObject().apply {
            put("name", folderName)
            put("folder", JSONObject())
            put("@microsoft.graph.conflictBehavior", "fail")
        }
        val conn = openGraphConn(createUrl, "POST", token).apply {
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=UTF-8")
        }
        try {
            conn.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            if (code !in 200..299 && code != 409) {
                throw IllegalStateException("建立 OneDrive 資料夾失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
            }
        } finally {
            conn.disconnect()
        }
    }

    override suspend fun listFiles(subFolder: String): Result<List<RemoteFileEntry>> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val entries = mutableListOf<RemoteFileEntry>()
            var nextUrl: String? = buildItemPathUrl(subFolder, ":/children?\$top=1000")

            while (!nextUrl.isNullOrBlank()) {
                val conn = openGraphConn(nextUrl, "GET", token)
                val body = try {
                    val code = conn.responseCode
                    if (code == 404) return@runCatching emptyList()
                    val text = SyncHttpUtils.readResponseText(conn)
                    if (code !in 200..299) {
                        throw IllegalStateException("列出 OneDrive 檔案失敗 (HTTP $code)：${text.take(200)}")
                    }
                    text
                } finally {
                    conn.disconnect()
                }

                val json = JSONObject(body)
                val arr = json.optJSONArray("value") ?: JSONArray()
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    entries.add(
                        RemoteFileEntry(
                            name = obj.optString("name"),
                            sizeBytes = obj.optLong("size", 0L),
                            isDirectory = obj.has("folder"),
                            remoteId = obj.optString("id")
                        )
                    )
                }
                nextUrl = json.optString("@odata.nextLink").takeIf { it.isNotBlank() }
            }
            entries
        }
    }

    override suspend fun downloadBytes(remotePath: String): Result<ByteArray?> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val conn = openDownloadConn(buildItemPathUrl(remotePath, ":/content"), token) ?: return@runCatching null
            try {
                conn.inputStream.use { it.readBytes() }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun downloadFile(remotePath: String, destFile: File): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val conn = openDownloadConn(buildItemPathUrl(remotePath, ":/content"), token) ?: return@runCatching false
            try {
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

    /**
     * Microsoft Graph `/content` returns 302 redirecting to a pre-authenticated Azure Blob Storage URL.
     * We MUST manually follow the redirect WITHOUT sending the Bearer token to Azure Blob.
     */
    private fun openDownloadConn(initialUrl: String, token: String): HttpURLConnection? {
        val first = openGraphConn(initialUrl, "GET", token).apply {
            instanceFollowRedirects = false
        }
        val code = first.responseCode
        if (code == 404) {
            first.disconnect()
            return null
        }
        if (code in setOf(301, 302, 303, 307, 308)) {
            val loc = first.getHeaderField("Location")
            first.disconnect()
            if (loc.isNullOrBlank()) throw IllegalStateException("OneDrive 下載重導向缺少 Location")
            val second = (URL(loc).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 20_000
                readTimeout = 90_000
                instanceFollowRedirects = true
            }
            val c2 = second.responseCode
            if (c2 !in 200..299) {
                val err = SyncHttpUtils.readResponseText(second)
                second.disconnect()
                throw IllegalStateException("OneDrive 下載內容失敗 (HTTP $c2)：${err.take(200)}")
            }
            return second
        }
        if (code !in 200..299) {
            val err = SyncHttpUtils.readResponseText(first)
            first.disconnect()
            throw IllegalStateException("OneDrive 下載失敗 (HTTP $code)：${err.take(200)}")
        }
        return first
    }

    override suspend fun uploadBytes(remotePath: String, data: ByteArray, contentType: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val conn = openGraphConn(buildItemPathUrl(remotePath, ":/content"), "PUT", token).apply {
                doOutput = true
                setFixedLengthStreamingMode(data.size)
                setRequestProperty("Content-Type", contentType)
            }
            try {
                conn.outputStream.use { it.write(data) }
                val code = conn.responseCode
                if (code !in 200..299) {
                    throw IllegalStateException("OneDrive 上傳失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun uploadFile(remotePath: String, sourceFile: File, contentType: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val totalSize = sourceFile.length()
            if (totalSize <= simpleUploadLimit) {
                val conn = openGraphConn(buildItemPathUrl(remotePath, ":/content"), "PUT", token).apply {
                    doOutput = true
                    setFixedLengthStreamingMode(totalSize)
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
                        throw IllegalStateException("OneDrive 上傳書檔失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(200)}")
                    }
                } finally {
                    conn.disconnect()
                }
            } else {
                uploadLargeFileChunked(token, remotePath, sourceFile, totalSize)
            }
        }
    }

    private fun uploadLargeFileChunked(token: String, remotePath: String, sourceFile: File, totalSize: Long) {
        val sessionUrl = buildItemPathUrl(remotePath, ":/createUploadSession")
        val reqBody = JSONObject().apply {
            put("item", JSONObject().apply {
                put("@microsoft.graph.conflictBehavior", "replace")
            })
        }
        val sessionConn = openGraphConn(sessionUrl, "POST", token).apply {
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=UTF-8")
        }
        val uploadUrl = try {
            sessionConn.outputStream.use { it.write(reqBody.toString().toByteArray(Charsets.UTF_8)) }
            val code = sessionConn.responseCode
            val resp = SyncHttpUtils.readResponseText(sessionConn)
            if (code !in 200..299) {
                throw IllegalStateException("建立 OneDrive 大檔上傳工作階段失敗 (HTTP $code)：${resp.take(200)}")
            }
            JSONObject(resp).getString("uploadUrl")
        } finally {
            sessionConn.disconnect()
        }

        val buffer = ByteArray(uploadChunkSize)
        var offset = 0L
        FileInputStream(sourceFile).use { fis ->
            while (offset < totalSize) {
                val toRead = minOf(uploadChunkSize.toLong(), totalSize - offset).toInt()
                var bytesRead = 0
                while (bytesRead < toRead) {
                    val r = fis.read(buffer, bytesRead, toRead - bytesRead)
                    if (r < 0) break
                    bytesRead += r
                }
                if (bytesRead <= 0) break

                val rangeEnd = offset + bytesRead - 1L
                // Pre-authenticated uploadUrl MUST NOT carry Graph Authorization header
                val chunkConn = (URL(uploadUrl).openConnection() as HttpURLConnection).apply {
                    requestMethod = "PUT"
                    connectTimeout = 20_000
                    readTimeout = 90_000
                    doOutput = true
                    setFixedLengthStreamingMode(bytesRead)
                    setRequestProperty("Content-Range", "bytes $offset-$rangeEnd/$totalSize")
                }
                try {
                    chunkConn.outputStream.use { it.write(buffer, 0, bytesRead) }
                    val code = chunkConn.responseCode
                    if (code !in 200..299) {
                        throw IllegalStateException("OneDrive 分塊上傳失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(chunkConn).take(200)}")
                    }
                } finally {
                    chunkConn.disconnect()
                }
                offset += bytesRead
            }
        }
    }

    override suspend fun deleteFile(remotePath: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val token = getValidAccessToken()
            val conn = openGraphConn(buildItemPathUrl(remotePath), "DELETE", token)
            try {
                val code = conn.responseCode
                if (code !in 200..299 && code != 404) {
                    throw IllegalStateException("OneDrive 刪除失敗 (HTTP $code)")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun openGraphConn(urlStr: String, method: String, token: String): HttpURLConnection {
        return (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 20_000
            readTimeout = 60_000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/json")
        }
    }
}
