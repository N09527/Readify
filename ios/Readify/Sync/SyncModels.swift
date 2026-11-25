import Foundation

enum CloudProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case WEBDAV
    case GOOGLE_DRIVE
    case ONEDRIVE

    var id: String { rawValue }

    var label: String {
        switch self {
        case .WEBDAV: return "WebDAV"
        case .GOOGLE_DRIVE: return "Google Drive"
        case .ONEDRIVE: return "OneDrive"
        }
    }
}

struct WebDavConfig: Equatable, Sendable {
    var serverUrl: String = ""
    var username: String = ""
    var password: String = ""
    var remoteFolder: String = "Readify"

    var isConfigured: Bool {
        !serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct GoogleDriveConfig: Equatable, Sendable {
    var clientId: String = ""
    var clientSecret: String = ""
    var redirectUri: String = "http://127.0.0.1:48123/callback"
    var accessToken: String = ""
    var refreshToken: String = ""
    var tokenExpiresAtMs: Int64 = 0
    var remoteFolder: String = "Readify"

    var isAuthorized: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct OneDriveConfig: Equatable, Sendable {
    var clientId: String = ""
    var tenantId: String = "common"
    var redirectUri: String = "com.inkflow.reader://oauth/onedrive"
    var accessToken: String = ""
    var refreshToken: String = ""
    var tokenExpiresAtMs: Int64 = 0
    var remoteFolder: String = "Readify"

    var isAuthorized: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CloudSyncConfig: Equatable, Sendable {
    var activeProvider: CloudProviderType = .WEBDAV
    var syncBookFiles: Bool = true
    var syncReaderSettings: Bool = true
    var lastSyncTimeMs: Int64 = 0
    var lastSyncSummary: String = ""
    var webDav: WebDavConfig = WebDavConfig()
    var googleDrive: GoogleDriveConfig = GoogleDriveConfig()
    var oneDrive: OneDriveConfig = OneDriveConfig()
}

struct RemoteFileEntry: Identifiable, Equatable, Sendable {
    var id: String { remoteId.isEmpty ? name : "\(remoteId)-\(name)" }
    var name: String
    var sizeBytes: Int64 = 0
    var modifiedMs: Int64 = 0
    var isDirectory: Bool = false
    var remoteId: String = ""
}

struct SyncReport: Equatable, Sendable {
    var provider: CloudProviderType
    var uploadedBooks: Int
    var downloadedBooks: Int
    var mergedBooksCount: Int
    var mergedBookmarksCount: Int
    var settingsSynced: Bool
    var errors: [String] = []

    func toDisplaySummary() -> String {
        var parts: [String] = []
        if uploadedBooks > 0 { parts.append("上傳書檔 \(uploadedBooks) 本") }
        if downloadedBooks > 0 { parts.append("下載書檔 \(downloadedBooks) 本") }
        parts.append("已同步 \(mergedBooksCount) 本進度")
        parts.append("\(mergedBookmarksCount) 筆書籤")
        if settingsSynced { parts.append("已同步閱讀設定") }
        if !errors.isEmpty { parts.append("\(errors.count) 項異常") }
        return "[\(provider.label)] " + parts.joined(separator: " · ")
    }
}

struct CloudSyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}
