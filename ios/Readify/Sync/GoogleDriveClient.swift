import Foundation

final class GoogleDriveClient: CloudStorageClient {
    let providerType: CloudProviderType = .GOOGLE_DRIVE

    private var config: GoogleDriveConfig
    private let rootFolderName: String
    private let onTokensUpdated: @Sendable (GoogleDriveConfig) -> Void

    private var cachedRootFolderId: String?
    private var cachedBooksFolderId: String?

    init(initialConfig: GoogleDriveConfig, onTokensUpdated: @escaping @Sendable (GoogleDriveConfig) -> Void) {
        self.config = initialConfig
        let trimmed = initialConfig.remoteFolder.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        self.rootFolderName = trimmed.isEmpty ? "Readify" : trimmed
        self.onTokensUpdated = onTokensUpdated
    }

    private func getValidAccessToken() async throws -> String {
        let now = BookItem.nowMs()
        if !config.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (config.tokenExpiresAtMs == 0 || now < config.tokenExpiresAtMs - 60_000) {
            return config.accessToken
        }
        let refreshed = try await OAuthPkceHelper.refreshGoogleToken(config: config)
        config.accessToken = refreshed.accessToken
        config.refreshToken = refreshed.refreshToken
        config.tokenExpiresAtMs = refreshed.expiresAtMs
        onTokensUpdated(config)
        return config.accessToken
    }

    private func makeAuthedRequest(urlStr: String, method: String, token: String, timeout: TimeInterval = 60) throws -> URLRequest {
        guard let url = URL(string: urlStr) else {
            throw CloudSyncError("無效的 Google Drive API 網址")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    func testConnection() async throws -> String {
        guard config.isAuthorized else {
            throw CloudSyncError("尚未授權 Google Drive，請先點擊登入")
        }
        try await ensureRootFolder()
        let files = try await listFiles(subFolder: "")
        return "Google Drive 連線成功！資料夾「\(rootFolderName)」目前有 \(files.count) 個項目。"
    }

    func ensureRootFolder() async throws {
        let token = try await getValidAccessToken()
        let rootId: String
        if let cached = cachedRootFolderId {
            rootId = cached
        } else {
            rootId = try await findOrCreateFolder(token: token, name: rootFolderName, parentId: nil)
            cachedRootFolderId = rootId
        }

        if cachedBooksFolderId == nil {
            cachedBooksFolderId = try await findOrCreateFolder(token: token, name: "books", parentId: rootId)
        }
    }

    func listFiles(subFolder: String) async throws -> [RemoteFileEntry] {
        try await ensureRootFolder()
        let token = try await getValidAccessToken()
        let cleanSub = subFolder.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        let folderId = try await resolveParentFolderId(token: token, subFolder: cleanSub)
        let q = "'\(folderId)' in parents and trashed = false"
        let urlStr = "https://www.googleapis.com/drive/v3/files" +
            "?q=\(SyncHttpUtils.urlEncodeSegment(q))" +
            "&fields=\(SyncHttpUtils.urlEncodeSegment("files(id,name,size,mimeType)"))" +
            "&pageSize=1000"

        let data = try await executeDataGet(token: token, urlStr: urlStr)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let filesArr = obj["files"] as? [[String: Any]] else {
            return []
        }

        return filesArr.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let sizeStr = (item["size"] as? String) ?? "0"
            let sizeVal = Int64(sizeStr) ?? (item["size"] as? NSNumber)?.int64Value ?? 0
            let mime = (item["mimeType"] as? String) ?? ""
            let id = (item["id"] as? String) ?? ""
            return RemoteFileEntry(
                name: name,
                sizeBytes: sizeVal,
                modifiedMs: 0,
                isDirectory: mime == "application/vnd.google-apps.folder",
                remoteId: id
            )
        }
    }

    func downloadBytes(remotePath: String) async throws -> Data? {
        try await ensureRootFolder()
        let token = try await getValidAccessToken()
        let (folderId, fileName) = try await resolveParentAndFileName(token: token, remotePath: remotePath)
        guard let fileId = try await findFileIdInFolder(token: token, folderId: folderId, fileName: fileName) else {
            return nil
        }

        let req = try makeAuthedRequest(urlStr: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media", method: "GET", token: token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard (200...299).contains(code) else {
            throw CloudSyncError("Google Drive 下載失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
        }
        return data
    }

    func downloadFile(remotePath: String, destURL: URL) async throws -> Bool {
        try await ensureRootFolder()
        let token = try await getValidAccessToken()
        let (folderId, fileName) = try await resolveParentAndFileName(token: token, remotePath: remotePath)
        guard let fileId = try await findFileIdInFolder(token: token, folderId: folderId, fileName: fileName) else {
            return false
        }

        let req = try makeAuthedRequest(urlStr: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media", method: "GET", token: token, timeout: 180)
        let (tempURL, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return false }
        guard (200...299).contains(code) else {
            throw CloudSyncError("Google Drive 下載書檔失敗 (HTTP \(code))")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }
        try fm.moveItem(at: tempURL, to: destURL)
        return true
    }

    func uploadBytes(remotePath: String, data: Data, contentType: String) async throws {
        try await ensureRootFolder()
        let token = try await getValidAccessToken()
        let (folderId, fileName) = try await resolveParentAndFileName(token: token, remotePath: remotePath)
        let existingId = try await findFileIdInFolder(token: token, folderId: folderId, fileName: fileName)
        let uploadURLStr = try await initiateResumableSession(
            token: token,
            folderId: folderId,
            fileName: fileName,
            existingFileId: existingId,
            contentType: contentType,
            contentLength: Int64(data.count)
        )
        guard let uploadURL = URL(string: uploadURLStr) else {
            throw CloudSyncError("Google Drive 回傳的上傳網址無效")
        }
        var req = URLRequest(url: uploadURL, timeoutInterval: 90)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (respData, resp) = try await URLSession.shared.upload(for: req, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw CloudSyncError("Google Drive 上傳資料失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
    }

    func uploadFile(remotePath: String, sourceURL: URL, contentType: String) async throws {
        try await ensureRootFolder()
        let token = try await getValidAccessToken()
        let (folderId, fileName) = try await resolveParentAndFileName(token: token, remotePath: remotePath)
        let existingId = try await findFileIdInFolder(token: token, folderId: folderId, fileName: fileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileLen = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let uploadURLStr = try await initiateResumableSession(
            token: token,
            folderId: folderId,
            fileName: fileName,
            existingFileId: existingId,
            contentType: contentType,
            contentLength: fileLen
        )
        guard let uploadURL = URL(string: uploadURLStr) else {
            throw CloudSyncError("Google Drive 回傳的上傳網址無效")
        }
        var req = URLRequest(url: uploadURL, timeoutInterval: 300)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (respData, resp) = try await URLSession.shared.upload(for: req, fromFile: sourceURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw CloudSyncError("Google Drive 上傳書檔失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
    }

    func deleteFile(remotePath: String) async throws {
        try await ensureRootFolder()
        let token = try await getValidAccessToken()
        let (folderId, fileName) = try await resolveParentAndFileName(token: token, remotePath: remotePath)
        guard let fileId = try await findFileIdInFolder(token: token, folderId: folderId, fileName: fileName) else {
            return
        }
        let req = try makeAuthedRequest(urlStr: "https://www.googleapis.com/drive/v3/files/\(fileId)", method: "DELETE", token: token)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) || code == 404 else {
            throw CloudSyncError("Google Drive 刪除失敗 (HTTP \(code))")
        }
    }

    private func resolveParentAndFileName(token: String, remotePath: String) async throws -> (String, String) {
        let clean = remotePath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        if let slash = clean.lastIndex(of: "/") {
            let sub = String(clean[..<slash])
            let name = String(clean[clean.index(after: slash)...])
            let folderId = try await resolveParentFolderId(token: token, subFolder: sub)
            return (folderId, name)
        } else {
            let folderId = try await resolveParentFolderId(token: token, subFolder: "")
            return (folderId, clean)
        }
    }

    private func resolveParentFolderId(token: String, subFolder: String) async throws -> String {
        guard let rootId = cachedRootFolderId else {
            throw CloudSyncError("尚未初始化 Google Drive 根目錄")
        }
        if subFolder.isEmpty { return rootId }
        if subFolder == "books", let booksId = cachedBooksFolderId {
            return booksId
        }
        var cur = rootId
        for seg in subFolder.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            cur = try await findOrCreateFolder(token: token, name: seg, parentId: cur)
        }
        return cur
    }

    private func findOrCreateFolder(token: String, name: String, parentId: String?) async throws -> String {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        let parentClause = parentId != nil ? " and '\(parentId!)' in parents" : " and 'root' in parents"
        let q = "name = '\(escaped)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false\(parentClause)"
        let urlStr = "https://www.googleapis.com/drive/v3/files?q=\(SyncHttpUtils.urlEncodeSegment(q))&fields=files(id,name)&pageSize=5"

        let data = try await executeDataGet(token: token, urlStr: urlStr)
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let arr = obj["files"] as? [[String: Any]],
           let firstId = arr.first?["id"] as? String, !firstId.isEmpty {
            return firstId
        }

        var meta: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        if let parentId {
            meta["parents"] = [parentId]
        }
        var req = try makeAuthedRequest(urlStr: "https://www.googleapis.com/drive/v3/files?fields=id", method: "POST", token: token)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: meta)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code),
              let created = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let createdId = created["id"] as? String else {
            throw CloudSyncError("建立 Google Drive 資料夾失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
        return createdId
    }

    private func findFileIdInFolder(token: String, folderId: String, fileName: String) async throws -> String? {
        let escaped = fileName.replacingOccurrences(of: "'", with: "\\'")
        let q = "name = '\(escaped)' and '\(folderId)' in parents and trashed = false"
        let urlStr = "https://www.googleapis.com/drive/v3/files?q=\(SyncHttpUtils.urlEncodeSegment(q))&fields=files(id)&pageSize=5"
        let data = try await executeDataGet(token: token, urlStr: urlStr)
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let arr = obj["files"] as? [[String: Any]],
           let firstId = arr.first?["id"] as? String {
            return firstId
        }
        return nil
    }

    private func initiateResumableSession(
        token: String,
        folderId: String,
        fileName: String,
        existingFileId: String?,
        contentType: String,
        contentLength: Int64
    ) async throws -> String {
        let urlStr: String
        let method: String
        if let existingFileId {
            urlStr = "https://www.googleapis.com/upload/drive/v3/files/\(existingFileId)?uploadType=resumable"
            method = "PATCH"
        } else {
            urlStr = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable"
            method = "POST"
        }

        var meta: [String: Any] = ["name": fileName]
        if existingFileId == nil {
            meta["parents"] = [folderId]
        }

        var req = try makeAuthedRequest(urlStr: urlStr, method: method, token: token)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(contentType, forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue("\(contentLength)", forHTTPHeaderField: "X-Upload-Content-Length")
        req.httpBody = try JSONSerialization.data(withJSONObject: meta)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudSyncError("初始化 Google Drive 上傳失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
        guard let loc = httpResp.value(forHTTPHeaderField: "Location"), !loc.isEmpty else {
            throw CloudSyncError("Google Drive 未回傳上傳網址 (Location)")
        }
        return loc
    }

    private func executeDataGet(token: String, urlStr: String) async throws -> Data {
        let req = try makeAuthedRequest(urlStr: urlStr, method: "GET", token: token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw CloudSyncError("Google Drive API 錯誤 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
        }
        return data
    }
}
