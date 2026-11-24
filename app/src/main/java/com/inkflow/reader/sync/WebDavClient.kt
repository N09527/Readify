package com.inkflow.reader.sync

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.Socket
import java.net.URL
import java.net.URLDecoder
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

class WebDavClient(private val config: WebDavConfig) : CloudStorageClient {

    override val providerType: CloudProviderType = CloudProviderType.WEBDAV

    private val baseUrl: String = config.serverUrl.trim().trimEnd('/')
    private val rootFolder: String = config.remoteFolder.trim().trim('/').ifBlank { "Readify" }

    private fun authHeader(): String? {
        if (config.username.isBlank() && config.password.isBlank()) return null
        val raw = "${config.username}:${config.password}".toByteArray(Charsets.UTF_8)
        return "Basic " + Base64.encodeToString(raw, Base64.NO_WRAP)
    }

    private fun buildUrl(remotePath: String, trailingSlash: Boolean = false): String {
        val clean = remotePath.trim().trim('/')
        val folderEnc = SyncHttpUtils.urlEncodePath(rootFolder)
        val pathEnc = if (clean.isEmpty()) "" else "/" + SyncHttpUtils.urlEncodePath(clean)
        val suffix = if (trailingSlash) "/" else ""
        return "$baseUrl/$folderEnc$pathEnc$suffix"
    }

    override suspend fun testConnection(): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            if (baseUrl.isBlank()) throw IllegalArgumentException("請先填寫 WebDAV 伺服器網址")
            ensureRootFolder().getOrThrow()
            val files = listFiles("").getOrThrow()
            "WebDAV 連線成功！資料夾「$rootFolder」目前有 ${files.size} 個項目。"
        }
    }

    override suspend fun ensureRootFolder(): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            if (baseUrl.isBlank()) throw IllegalArgumentException("WebDAV 伺服器網址為空")
            val segments = rootFolder.split("/").filter { it.isNotEmpty() }
            val accum = StringBuilder()
            for (seg in segments) {
                accum.append("/").append(SyncHttpUtils.urlEncodeSegment(seg))
                mkcol("$baseUrl$accum/")
            }
            mkcol(buildUrl("books", trailingSlash = true))
        }
    }

    override suspend fun listFiles(subFolder: String): Result<List<RemoteFileEntry>> = withContext(Dispatchers.IO) {
        runCatching {
            val targetUrl = buildUrl(subFolder, trailingSlash = true)
            val propfindXml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
                "<d:propfind xmlns:d=\"DAV:\"><d:prop>" +
                "<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>" +
                "</d:prop></d:propfind>"
            val resp = sendRawWebDavRequest(
                method = "PROPFIND",
                urlStr = targetUrl,
                extraHeaders = mapOf(
                    "Depth" to "1",
                    "Content-Type" to "application/xml; charset=utf-8"
                ),
                bodyBytes = propfindXml.toByteArray(Charsets.UTF_8)
            )
            if (resp.statusCode == 404) return@runCatching emptyList()
            if (resp.statusCode !in 200..299) {
                throw IllegalStateException("PROPFIND 失敗 (HTTP ${resp.statusCode})：${resp.bodyText.take(200)}")
            }

            val reqPath = URL(targetUrl).path.trimEnd('/').lowercase()
            val doc = Jsoup.parse(resp.bodyText, "", Parser.xmlParser())
            val entries = mutableListOf<RemoteFileEntry>()

            for (node in doc.select("response, *|response")) {
                val rawHref = node.selectFirst("href, *|href")?.text()?.trim().orEmpty()
                if (rawHref.isBlank()) continue
                val hrefPath = runCatching {
                    if (rawHref.startsWith("http://") || rawHref.startsWith("https://")) URL(rawHref).path else rawHref
                }.getOrDefault(rawHref)

                val decodedPath = runCatching { URLDecoder.decode(hrefPath, "UTF-8") }.getOrDefault(hrefPath)
                val normalizedHref = decodedPath.trimEnd('/')
                val normalizedReq = runCatching { URLDecoder.decode(reqPath, "UTF-8") }.getOrDefault(reqPath)

                if (normalizedHref.equals(normalizedReq, ignoreCase = true)) continue

                val isDir = node.select("resourcetype collection, *|resourcetype *|collection").isNotEmpty() ||
                    decodedPath.endsWith("/")
                val name = normalizedHref.substringAfterLast('/').ifBlank {
                    node.selectFirst("displayname, *|displayname")?.text()?.trim().orEmpty()
                }
                if (name.isBlank()) continue

                val size = node.selectFirst("getcontentlength, *|getcontentlength")
                    ?.text()?.trim()?.toLongOrNull() ?: 0L

                entries.add(
                    RemoteFileEntry(
                        name = name,
                        sizeBytes = size,
                        modifiedMs = 0L,
                        isDirectory = isDir,
                        remoteId = normalizedHref
                    )
                )
            }
            entries
        }
    }

    override suspend fun downloadBytes(remotePath: String): Result<ByteArray?> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = openHttpConn(buildUrl(remotePath), "GET")
            try {
                val code = conn.responseCode
                if (code == 404) return@runCatching null
                if (code !in 200..299) {
                    throw IllegalStateException("WebDAV 下載失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(180)}")
                }
                conn.inputStream.use { it.readBytes() }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun uploadBytes(remotePath: String, data: ByteArray, contentType: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = openHttpConn(buildUrl(remotePath), "PUT").apply {
                doOutput = true
                setFixedLengthStreamingMode(data.size)
                setRequestProperty("Content-Type", contentType)
            }
            try {
                conn.outputStream.use { it.write(data) }
                val code = conn.responseCode
                if (code !in 200..299) {
                    throw IllegalStateException("WebDAV 上傳失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(180)}")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun downloadFile(remotePath: String, destFile: File): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = openHttpConn(buildUrl(remotePath), "GET")
            try {
                val code = conn.responseCode
                if (code == 404) return@runCatching false
                if (code !in 200..299) {
                    throw IllegalStateException("WebDAV 下載檔案失敗 (HTTP $code)")
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

    override suspend fun uploadFile(remotePath: String, sourceFile: File, contentType: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val fileLen = sourceFile.length()
            val conn = openHttpConn(buildUrl(remotePath), "PUT").apply {
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
                    throw IllegalStateException("WebDAV 上傳檔案失敗 (HTTP $code)：${SyncHttpUtils.readResponseText(conn).take(180)}")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun deleteFile(remotePath: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val conn = openHttpConn(buildUrl(remotePath), "DELETE")
            try {
                val code = conn.responseCode
                if (code !in 200..299 && code != 404) {
                    throw IllegalStateException("WebDAV 刪除失敗 (HTTP $code)")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun openHttpConn(urlStr: String, method: String): HttpURLConnection {
        return (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 20_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            authHeader()?.let { setRequestProperty("Authorization", it) }
        }
    }

    private fun mkcol(urlStr: String) {
        val resp = sendRawWebDavRequest("MKCOL", urlStr, emptyMap(), ByteArray(0))
        if (resp.statusCode in setOf(200, 201, 204, 405)) return
        if (resp.statusCode == 401 || resp.statusCode == 403) {
            throw IllegalStateException("WebDAV 帳密驗證失敗或無權限 (HTTP ${resp.statusCode})")
        }
        val probe = sendRawWebDavRequest("PROPFIND", urlStr, mapOf("Depth" to "0"), ByteArray(0))
        if (probe.statusCode !in 200..299) {
            throw IllegalStateException("建立 WebDAV 資料夾失敗 (MKCOL HTTP ${resp.statusCode})")
        }
    }

    private data class RawHttpResp(
        val statusCode: Int,
        val headers: Map<String, String>,
        val bodyBytes: ByteArray
    ) {
        val bodyText: String get() = String(bodyBytes, Charsets.UTF_8)
    }

    private fun sendRawWebDavRequest(
        method: String,
        urlStr: String,
        extraHeaders: Map<String, String>,
        bodyBytes: ByteArray,
        redirectDepth: Int = 0
    ): RawHttpResp {
        val url = URL(urlStr)
        val isHttps = url.protocol.equals("https", ignoreCase = true)
        val host = url.host
        val port = if (url.port > 0) url.port else if (isHttps) 443 else 80
        val hostHeader = if ((isHttps && port == 443) || (!isHttps && port == 80)) host else "$host:$port"
        val reqPath = buildString {
            append(if (url.path.isNullOrEmpty()) "/" else url.path)
            if (!url.query.isNullOrEmpty()) append("?").append(url.query)
        }

        val socket: Socket = if (isHttps) {
            val ssl = SSLSocketFactory.getDefault().createSocket(host, port) as SSLSocket
            ssl.soTimeout = 25_000
            ssl.startHandshake()
            ssl
        } else {
            Socket(host, port).apply { soTimeout = 25_000 }
        }

        val resp = socket.use { s ->
            val out = s.getOutputStream()
            val headerSb = StringBuilder()
            headerSb.append("$method $reqPath HTTP/1.1\r\n")
            headerSb.append("Host: $hostHeader\r\n")
            headerSb.append("User-Agent: Readify/1.0\r\n")
            authHeader()?.let { headerSb.append("Authorization: $it\r\n") }
            for ((k, v) in extraHeaders) {
                headerSb.append("$k: $v\r\n")
            }
            headerSb.append("Content-Length: ${bodyBytes.size}\r\n")
            headerSb.append("Connection: close\r\n\r\n")

            out.write(headerSb.toString().toByteArray(Charsets.ISO_8859_1))
            if (bodyBytes.isNotEmpty()) out.write(bodyBytes)
            out.flush()

            val input = BufferedInputStream(s.getInputStream())
            val allBytes = input.readBytes()
            parseRawHttpResponse(allBytes)
        }

        if (resp.statusCode in setOf(301, 302, 307, 308) && redirectDepth < 4) {
            val loc = resp.headers["location"]
            if (!loc.isNullOrBlank()) {
                val nextUrl = URL(url, loc).toString()
                return sendRawWebDavRequest(method, nextUrl, extraHeaders, bodyBytes, redirectDepth + 1)
            }
        }
        return resp
    }

    private fun parseRawHttpResponse(raw: ByteArray): RawHttpResp {
        val sepIdx = findHeaderEnd(raw)
        if (sepIdx < 0) return RawHttpResp(0, emptyMap(), raw)
        val headerStr = String(raw, 0, sepIdx, Charsets.ISO_8859_1)
        val lines = headerStr.split("\r\n")
        val statusCode = lines.firstOrNull()?.split(" ")?.getOrNull(1)?.toIntOrNull() ?: 0

        val headers = mutableMapOf<String, String>()
        for (i in 1 until lines.size) {
            val colon = lines[i].indexOf(':')
            if (colon > 0) {
                headers[lines[i].substring(0, colon).trim().lowercase()] = lines[i].substring(colon + 1).trim()
            }
        }

        val bodyStart = sepIdx + 4
        val rawBody = if (bodyStart < raw.size) raw.copyOfRange(bodyStart, raw.size) else ByteArray(0)
        val finalBody = if (headers["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true) {
            decodeChunked(rawBody)
        } else rawBody

        return RawHttpResp(statusCode, headers, finalBody)
    }

    private fun findHeaderEnd(raw: ByteArray): Int {
        var i = 0
        while (i + 3 < raw.size) {
            if (raw[i] == 13.toByte() && raw[i + 1] == 10.toByte() && raw[i + 2] == 13.toByte() && raw[i + 3] == 10.toByte()) {
                return i
            }
            i++
        }
        return -1
    }

    private fun decodeChunked(raw: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        var pos = 0
        while (pos < raw.size) {
            var lineEnd = -1
            var j = pos
            while (j + 1 < raw.size) {
                if (raw[j] == 13.toByte() && raw[j + 1] == 10.toByte()) {
                    lineEnd = j
                    break
                }
                j++
            }
            if (lineEnd < 0) break
            val sizeHex = String(raw, pos, lineEnd - pos, Charsets.US_ASCII).substringBefore(';').trim()
            pos = lineEnd + 2
            if (sizeHex.isEmpty()) continue
            val chunkLen = sizeHex.toIntOrNull(16) ?: break
            if (chunkLen == 0) break
            val safeLen = minOf(chunkLen, raw.size - pos)
            if (safeLen > 0) out.write(raw, pos, safeLen)
            pos += safeLen + 2
        }
        return out.toByteArray()
    }
}
