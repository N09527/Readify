package com.inkflow.reader.sync

import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URLEncoder

interface CloudStorageClient {
    val providerType: CloudProviderType
    suspend fun testConnection(): Result<String>
    suspend fun ensureRootFolder(): Result<Unit>
    suspend fun listFiles(subFolder: String = ""): Result<List<RemoteFileEntry>>
    suspend fun downloadBytes(remotePath: String): Result<ByteArray?>
    suspend fun uploadBytes(remotePath: String, data: ByteArray, contentType: String = "application/octet-stream"): Result<Unit>
    suspend fun downloadFile(remotePath: String, destFile: File): Result<Boolean>
    suspend fun uploadFile(remotePath: String, sourceFile: File, contentType: String = "application/octet-stream"): Result<Unit>
    suspend fun deleteFile(remotePath: String): Result<Unit>
}

internal object SyncHttpUtils {

    fun urlEncodeSegment(segment: String): String {
        return URLEncoder.encode(segment, "UTF-8").replace("+", "%20")
    }

    fun urlEncodePath(path: String): String {
        return path.split("/")
            .filter { it.isNotEmpty() }
            .joinToString("/") { urlEncodeSegment(it) }
    }

    fun readResponseText(conn: HttpURLConnection): String {
        val stream: InputStream? = try {
            if (conn.responseCode in 200..399) conn.inputStream else conn.errorStream
        } catch (_: Exception) {
            conn.errorStream
        }
        return stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
    }

    fun formEncode(params: Map<String, String>): ByteArray {
        val body = params.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        return body.toByteArray(Charsets.UTF_8)
    }
}
