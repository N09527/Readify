package com.inkflow.reader.sync

enum class CloudProviderType(val label: String) {
    WEBDAV("WebDAV"),
    GOOGLE_DRIVE("Google Drive"),
    ONEDRIVE("OneDrive")
}

data class WebDavConfig(
    val serverUrl: String = "",
    val username: String = "",
    val password: String = "",
    val remoteFolder: String = "Readify"
) {
    val isConfigured: Boolean
        get() = serverUrl.trim().isNotBlank()
}

data class GoogleDriveConfig(
    val clientId: String = "",
    val clientSecret: String = "",
    val redirectUri: String = "http://127.0.0.1:48123/callback",
    val accessToken: String = "",
    val refreshToken: String = "",
    val tokenExpiresAtMs: Long = 0L,
    val remoteFolder: String = "Readify"
) {
    val isAuthorized: Boolean
        get() = accessToken.isNotBlank() || refreshToken.isNotBlank()
}

data class OneDriveConfig(
    val clientId: String = "",
    val tenantId: String = "common",
    val redirectUri: String = "com.inkflow.reader://oauth/onedrive",
    val accessToken: String = "",
    val refreshToken: String = "",
    val tokenExpiresAtMs: Long = 0L,
    val remoteFolder: String = "Readify"
) {
    val isAuthorized: Boolean
        get() = accessToken.isNotBlank() || refreshToken.isNotBlank()
}

data class CloudSyncConfig(
    val activeProvider: CloudProviderType = CloudProviderType.WEBDAV,
    val autoSyncOnBookOpenClose: Boolean = true,
    val syncBookFiles: Boolean = true,
    val syncReaderSettings: Boolean = true,
    val lastSyncTimeMs: Long = 0L,
    val lastSyncSummary: String = "",
    val webDav: WebDavConfig = WebDavConfig(),
    val googleDrive: GoogleDriveConfig = GoogleDriveConfig(),
    val oneDrive: OneDriveConfig = OneDriveConfig()
) {
    val isActiveProviderConfigured: Boolean
        get() = when (activeProvider) {
            CloudProviderType.WEBDAV -> webDav.isConfigured
            CloudProviderType.GOOGLE_DRIVE -> googleDrive.isAuthorized
            CloudProviderType.ONEDRIVE -> oneDrive.isAuthorized
        }

    val shouldAutoSync: Boolean
        get() = autoSyncOnBookOpenClose && isActiveProviderConfigured
}

data class RemoteFileEntry(
    val name: String,
    val sizeBytes: Long = 0L,
    val modifiedMs: Long = 0L,
    val isDirectory: Boolean = false,
    val remoteId: String = ""
)

data class SyncReport(
    val provider: CloudProviderType,
    val uploadedBooks: Int,
    val downloadedBooks: Int,
    val mergedBooksCount: Int,
    val mergedBookmarksCount: Int,
    val settingsSynced: Boolean,
    val errors: List<String> = emptyList()
) {
    fun toDisplaySummary(): String {
        val parts = mutableListOf<String>()
        if (uploadedBooks > 0) parts.add("上傳書檔 $uploadedBooks 本")
        if (downloadedBooks > 0) parts.add("下載書檔 $downloadedBooks 本")
        parts.add("已同步 $mergedBooksCount 本進度")
        parts.add("$mergedBookmarksCount 筆書籤")
        if (settingsSynced) parts.add("已同步閱讀設定")
        if (errors.isNotEmpty()) parts.add("${errors.size} 項異常")
        return "[${provider.label}] ${parts.joinToString(" · ")}"
    }
}
