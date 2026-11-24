package com.inkflow.reader.sync

import android.net.Uri
import android.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URL
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom

data class OAuthTokenResult(
    val accessToken: String,
    val refreshToken: String,
    val expiresAtMs: Long
)

data class PendingOAuthSession(
    val provider: CloudProviderType,
    val codeVerifier: String,
    val state: String,
    val redirectUri: String,
    val clientId: String,
    val clientSecret: String,
    val tenantId: String,
    val authUrl: String,
    val deferredCode: CompletableDeferred<Result<String>>
)

object OAuthPkceHelper {

    private const val GOOGLE_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
    private const val GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
    private const val GOOGLE_DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
    private const val ONEDRIVE_SCOPE = "offline_access Files.ReadWrite"

    @Volatile
    private var activeSession: PendingOAuthSession? = null

    @Volatile
    private var activeServerSocket: ServerSocket? = null

    fun createGoogleSession(config: GoogleDriveConfig): PendingOAuthSession {
        cancelActiveSession()
        val verifier = generateCodeVerifier()
        val challenge = generateCodeChallenge(verifier)
        val state = generateRandomState()
        val redirect = config.redirectUri.trim().ifBlank { "http://127.0.0.1:48123/callback" }

        val authUrl = Uri.parse(GOOGLE_AUTH_ENDPOINT).buildUpon()
            .appendQueryParameter("client_id", config.clientId.trim())
            .appendQueryParameter("redirect_uri", redirect)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("scope", GOOGLE_DRIVE_SCOPE)
            .appendQueryParameter("access_type", "offline")
            .appendQueryParameter("prompt", "consent")
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", state)
            .build()
            .toString()

        return PendingOAuthSession(
            provider = CloudProviderType.GOOGLE_DRIVE,
            codeVerifier = verifier,
            state = state,
            redirectUri = redirect,
            clientId = config.clientId.trim(),
            clientSecret = config.clientSecret.trim(),
            tenantId = "",
            authUrl = authUrl,
            deferredCode = CompletableDeferred()
        ).also { activeSession = it }
    }

    fun createOneDriveSession(config: OneDriveConfig): PendingOAuthSession {
        cancelActiveSession()
        val verifier = generateCodeVerifier()
        val challenge = generateCodeChallenge(verifier)
        val state = generateRandomState()
        val tenant = config.tenantId.trim().ifBlank { "common" }
        val redirect = config.redirectUri.trim().ifBlank { "com.inkflow.reader://oauth/onedrive" }

        val authUrl = Uri.parse("https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize").buildUpon()
            .appendQueryParameter("client_id", config.clientId.trim())
            .appendQueryParameter("redirect_uri", redirect)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("response_mode", "query")
            .appendQueryParameter("scope", ONEDRIVE_SCOPE)
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", state)
            .build()
            .toString()

        return PendingOAuthSession(
            provider = CloudProviderType.ONEDRIVE,
            codeVerifier = verifier,
            state = state,
            redirectUri = redirect,
            clientId = config.clientId.trim(),
            clientSecret = "",
            tenantId = tenant,
            authUrl = authUrl,
            deferredCode = CompletableDeferred()
        ).also { activeSession = it }
    }

    fun cancelActiveSession() {
        runCatching { activeServerSocket?.close() }
        activeServerSocket = null
        activeSession?.deferredCode?.cancel()
        activeSession = null
    }

    fun handleRedirectUri(uri: Uri): Boolean {
        val session = activeSession ?: return false
        val error = uri.getQueryParameter("error")
        if (!error.isNullOrBlank()) {
            val desc = uri.getQueryParameter("error_description").orEmpty()
            session.deferredCode.complete(Result.failure(IllegalStateException("授權遭拒：$error $desc".trim())))
            return true
        }
        val returnedState = uri.getQueryParameter("state")
        val code = uri.getQueryParameter("code")
        if (code.isNullOrBlank()) return false
        if (returnedState != null && returnedState != session.state) {
            session.deferredCode.complete(Result.failure(IllegalStateException("OAuth state 驗證不符，已中止授權")))
            return true
        }
        session.deferredCode.complete(Result.success(code))
        return true
    }

    suspend fun awaitAndExchangeToken(session: PendingOAuthSession): Result<OAuthTokenResult> = withContext(Dispatchers.IO) {
        val parsedRedirect = Uri.parse(session.redirectUri)
        val isLoopback = parsedRedirect.scheme.equals("http", ignoreCase = true) &&
            (parsedRedirect.host == "127.0.0.1" || parsedRedirect.host.equals("localhost", ignoreCase = true))

        val codeResult: Result<String> = if (isLoopback) {
            val port = parsedRedirect.port.takeIf { it in 1024..65535 } ?: 48123
            listenLoopbackCallback(port, session.state)
        } else {
            withTimeoutOrNull(180_000L) {
                session.deferredCode.await()
            } ?: Result.failure(IllegalStateException("等待瀏覽器回傳授權逾時（超過 3 分鐘），請重試"))
        }

        if (activeSession === session) {
            activeSession = null
        }

        val authCode = codeResult.getOrElse { return@withContext Result.failure(it) }
        exchangeCodeForTokens(session, authCode)
    }

    private fun listenLoopbackCallback(port: Int, expectedState: String): Result<String> {
        return runCatching {
            val server = ServerSocket(port, 2, InetAddress.getByName("127.0.0.1")).apply {
                reuseAddress = true
                soTimeout = 180_000
            }
            activeServerSocket = server
            try {
                while (true) {
                    val socket = server.accept()
                    socket.use { client ->
                        client.soTimeout = 5000
                        val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
                        val requestLine = reader.readLine() ?: return@use
                        val parts = requestLine.split(" ")
                        if (parts.size < 2) return@use
                        val target = parts[1]
                        if (target.startsWith("/favicon.ico")) {
                            client.getOutputStream().write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".toByteArray())
                            return@use
                        }

                        val query = target.substringAfter('?', "")
                        val params = parseQueryParams(query)
                        val err = params["error"]
                        val code = params["code"]
                        val state = params["state"]

                        val htmlBody = if (!err.isNullOrBlank()) {
                            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>" +
                                "<body style=\"font-family:sans-serif;text-align:center;padding:40px;\"><h2>授權未完成</h2><p>$err</p><p>請切回 Readify。</p></body></html>"
                        } else {
                            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>" +
                                "<body style=\"font-family:sans-serif;text-align:center;padding:40px;\"><h2>授權成功！</h2><p>已取得存取權杖，請直接切回 <b>Readify</b>。</p></body></html>"
                        }
                        val bodyBytes = htmlBody.toByteArray(Charsets.UTF_8)
                        val response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${bodyBytes.size}\r\nConnection: close\r\n\r\n"
                        client.getOutputStream().write(response.toByteArray(Charsets.UTF_8))
                        client.getOutputStream().write(bodyBytes)
                        client.getOutputStream().flush()

                        if (!err.isNullOrBlank()) {
                            throw IllegalStateException("授權遭拒：$err ${params["error_description"].orEmpty()}".trim())
                        }
                        if (state != null && state != expectedState) {
                            throw IllegalStateException("OAuth state 驗證不符")
                        }
                        if (code.isNullOrBlank()) {
                            throw IllegalStateException("回呼網址中未包含授權碼 (code)")
                        }
                        return@runCatching code
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                throw IllegalStateException("未收到授權回呼")
            } finally {
                runCatching { server.close() }
                if (activeServerSocket === server) activeServerSocket = null
            }
        }
    }

    private fun exchangeCodeForTokens(session: PendingOAuthSession, code: String): Result<OAuthTokenResult> {
        val tokenUrl = when (session.provider) {
            CloudProviderType.GOOGLE_DRIVE -> GOOGLE_TOKEN_ENDPOINT
            CloudProviderType.ONEDRIVE -> "https://login.microsoftonline.com/${session.tenantId}/oauth2/v2.0/token"
            CloudProviderType.WEBDAV -> return Result.failure(IllegalArgumentException("WebDAV 不使用 OAuth"))
        }

        val params = linkedMapOf(
            "grant_type" to "authorization_code",
            "client_id" to session.clientId,
            "code" to code,
            "redirect_uri" to session.redirectUri,
            "code_verifier" to session.codeVerifier
        )
        if (session.provider == CloudProviderType.GOOGLE_DRIVE && session.clientSecret.isNotBlank()) {
            params["client_secret"] = session.clientSecret
        }
        if (session.provider == CloudProviderType.ONEDRIVE) {
            params["scope"] = ONEDRIVE_SCOPE
        }

        return postTokenRequest(tokenUrl, params, fallbackRefreshToken = "")
    }

    suspend fun refreshGoogleToken(config: GoogleDriveConfig): Result<OAuthTokenResult> = withContext(Dispatchers.IO) {
        if (config.refreshToken.isBlank()) {
            return@withContext Result.failure(IllegalStateException("Google Drive 缺少 Refresh Token，請重新授權登入"))
        }
        val params = linkedMapOf(
            "grant_type" to "refresh_token",
            "client_id" to config.clientId.trim(),
            "refresh_token" to config.refreshToken.trim()
        )
        if (config.clientSecret.isNotBlank()) {
            params["client_secret"] = config.clientSecret.trim()
        }
        postTokenRequest(GOOGLE_TOKEN_ENDPOINT, params, fallbackRefreshToken = config.refreshToken.trim())
    }

    suspend fun refreshOneDriveToken(config: OneDriveConfig): Result<OAuthTokenResult> = withContext(Dispatchers.IO) {
        if (config.refreshToken.isBlank()) {
            return@withContext Result.failure(IllegalStateException("OneDrive 缺少 Refresh Token，請重新授權登入"))
        }
        val tenant = config.tenantId.trim().ifBlank { "common" }
        val url = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
        val params = linkedMapOf(
            "grant_type" to "refresh_token",
            "client_id" to config.clientId.trim(),
            "refresh_token" to config.refreshToken.trim(),
            "scope" to ONEDRIVE_SCOPE
        )
        postTokenRequest(url, params, fallbackRefreshToken = config.refreshToken.trim())
    }

    private fun postTokenRequest(
        tokenUrl: String,
        params: Map<String, String>,
        fallbackRefreshToken: String
    ): Result<OAuthTokenResult> {
        return runCatching {
            val conn = (URL(tokenUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 20_000
                readTimeout = 25_000
                doOutput = true
                setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                setRequestProperty("Accept", "application/json")
            }
            try {
                val payload = SyncHttpUtils.formEncode(params)
                conn.outputStream.use { it.write(payload) }
                val code = conn.responseCode
                val body = SyncHttpUtils.readResponseText(conn)
                if (code !in 200..299) {
                    val errMsg = runCatching {
                        val j = JSONObject(body)
                        "${j.optString("error")}: ${j.optString("error_description")}"
                    }.getOrDefault(body.take(240))
                    throw IllegalStateException("權杖交換失敗 (HTTP $code)：$errMsg")
                }
                val json = JSONObject(body)
                val accessToken = json.optString("access_token").trim()
                if (accessToken.isBlank()) {
                    throw IllegalStateException("伺服器未回傳 access_token")
                }
                val refreshToken = json.optString("refresh_token").trim().ifBlank { fallbackRefreshToken }
                val expiresInSec = json.optLong("expires_in", 3600L)
                val expiresAtMs = System.currentTimeMillis() + expiresInSec * 1000L
                OAuthTokenResult(accessToken, refreshToken, expiresAtMs)
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun parseQueryParams(query: String): Map<String, String> {
        if (query.isBlank()) return emptyMap()
        val map = mutableMapOf<String, String>()
        for (pair in query.split("&")) {
            val eq = pair.indexOf('=')
            if (eq > 0) {
                val k = URLDecoder.decode(pair.substring(0, eq), "UTF-8")
                val v = URLDecoder.decode(pair.substring(eq + 1), "UTF-8")
                map[k] = v
            }
        }
        return map
    }

    private fun generateCodeVerifier(): String {
        val bytes = ByteArray(48)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun generateCodeChallenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun generateRandomState(): String {
        val bytes = ByteArray(18)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }
}
