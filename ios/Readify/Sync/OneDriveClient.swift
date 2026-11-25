import Foundation

final class OneDriveClient: CloudStorageClient {
    let providerType: CloudProviderType = .ONEDRIVE

    private var config: OneDriveConfig
    private let rootFolderName: String
    private let onTokensUpdated: @Sendable (OneDriveConfig) -> Void
    private let noRedirectSession: URLSession

    private let simpleUploadLimit: Int64 = 4 * 1024 * 1024
    private let uploadChunkSize: Int = 10 * 320 * 1024 // 3,276,800 bytes

    init(initialConfig: OneDriveConfig, onTokensUpdated: @escaping @Sendable (OneDriveConfig) -> Void) {
        self.config = initialConfig
        let trimmed = initialConfig.remoteFolder.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        self.rootFolderName = trimmed.isEmpty ? "Readify" : trimmed
        self.onTokensUpdated = onTokensUpdated

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        self.noRedirectSession = URLSession(configuration: cfg, delegate: OneDriveNoRedirectDelegate(), delegateQueue: nil)
    }

    private func getValidAccessToken() async throws -> String {
        let now = BookItem.nowMs()
        if !config.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (config.tokenExpiresAtMs == 0 || now < config.tokenExpiresAtMs - 60_000) {
            return config.accessToken
        }
        let refreshed = try await OAuthPkceHelper.refreshOneDriveToken(config: config)
        config.accessToken = refreshed.accessToken
        config.refreshToken = refreshed.refreshToken
        config.tokenExpiresAtMs = refreshed.expiresAtMs
        onTokensUpdated(config)
        return config.accessToken
    }

    private func buildItemPathUrl(remotePath: String, suffix: String = "") -> String {
        let clean = remotePath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        let fullPath = clean.isEmpty ? rootFolderName : "\(rootFolderName)/\(clean)"
        let encoded = SyncHttpUtils.urlEncodePath(fullPath)
        return "https://graph.microsoft.com/v1.0/me/drive/root:/\(encoded)\(suffix)"
    }

    private func makeGraphRequest(urlStr: String, method: String, token: String, timeout: TimeInterval = 60) throws -> URLRequest {
        guard let url = URL(string: urlStr) else {
            throw CloudSyncError("無效的 OneDrive API 網址")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    func testConnection() async throws -> String {
        guard config.isAuthorized else {
            throw CloudSyncError("尚未授權 OneDrive，請先點擊登入")
        }
        try await ensureRootFolder()
        let files = try await listFiles(subFolder: "")
        return "OneDrive 連線成功！資料夾「\(rootFolderName)」目前有 \(files.count) 個項目。"
    }

    func ensureRootFolder() async throws {
        let token = try await getValidAccessToken()
        var parentPath = ""
        for seg in rootFolderName.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            try await ensureSingleFolder(token: token, parentPath: parentPath, folderName: seg)
            parentPath = parentPath.isEmpty ? seg : "\(parentPath)/\(seg)"
        }
        try await ensureSingleFolder(token: token, parentPath: parentPath, folderName: "books")
    }

    private func ensureSingleFolder(token: String, parentPath: String, folderName: String) async throws {
        let checkPath = parentPath.isEmpty ? folderName : "\(parentPath)/\(folderName)"
        let checkUrl = "https://graph.microsoft.com/v1.0/me/drive/root:/\(SyncHttpUtils.urlEncodePath(checkPath))"
        let checkReq = try makeGraphRequest(urlStr: checkUrl, method: "GET", token: token)
        let (checkData, checkResp) = try await URLSession.shared.data(for: checkReq)
        let checkCode = (checkResp as? HTTPURLResponse)?.statusCode ?? 0
        if (200...299).contains(checkCode) { return }
        if checkCode != 404 {
            throw CloudSyncError("檢查 OneDrive 資料夾失敗 (HTTP \(checkCode))：\(SyncHttpUtils.extractErrorText(checkData))")
        }

        let createUrl = parentPath.isEmpty
            ? "https://graph.microsoft.com/v1.0/me/drive/root/children"
            : "https://graph.microsoft.com/v1.0/me/drive/root:/\(SyncHttpUtils.urlEncodePath(parentPath)):/children"

        let payload: [String: Any] = [
            "name": folderName,
            "folder": [String: Any](),
            "@microsoft.graph.conflictBehavior": "fail"
        ]
        var createReq = try makeGraphRequest(urlStr: createUrl, method: "POST", token: token)
        createReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (createData, createResp) = try await URLSession.shared.data(for: createReq)
        let createCode = (createResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(createCode) || createCode == 409 else {
            throw CloudSyncError("建立 OneDrive 資料夾失敗 (HTTP \(createCode))：\(SyncHttpUtils.extractErrorText(createData))")
        }
    }

    func listFiles(subFolder: String) async throws -> [RemoteFileEntry] {
        let token = try await getValidAccessToken()
        var entries: [RemoteFileEntry] = []
        var nextUrl: String? = buildItemPathUrl(remotePath: subFolder, suffix: ":/children?$top=1000")

        while let urlStr = nextUrl, !urlStr.isEmpty {
            let req = try makeGraphRequest(urlStr: urlStr, method: "GET", token: token)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return [] }
            guard (200...299).contains(code) else {
                throw CloudSyncError("列出 OneDrive 檔案失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
            }

            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                break
            }
            if let arr = json["value"] as? [[String: Any]] {
                for obj in arr {
                    guard let name = obj["name"] as? String else { continue }
                    let size = (obj["size"] as? NSNumber)?.int64Value ?? 0
                    let isDir = obj["folder"] != nil
                    let id = (obj["id"] as? String) ?? ""
                    entries.append(
                        RemoteFileEntry(
                            name: name,
                            sizeBytes: size,
                            modifiedMs: 0,
                            isDirectory: isDir,
                            remoteId: id
                        )
                    )
                }
            }
            let nextLink = (json["@odata.nextLink"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            nextUrl = (nextLink?.isEmpty == false) ? nextLink : nil
        }
        return entries
    }

    func downloadBytes(remotePath: String) async throws -> Data? {
        let token = try await getValidAccessToken()
        let initialUrl = buildItemPathUrl(remotePath: remotePath, suffix: ":/content")
        let req = try makeGraphRequest(urlStr: initialUrl, method: "GET", token: token)
        let (data, resp) = try await noRedirectSession.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse else { return nil }
        let code = httpResp.statusCode
        if code == 404 { return nil }

        if [301, 302, 303, 307, 308].contains(code) {
            guard let loc = httpResp.value(forHTTPHeaderField: "Location"),
                  let locURL = URL(string: loc) else {
                throw CloudSyncError("OneDrive 下載重導向缺少 Location")
            }
            let (dlData, dlResp) = try await URLSession.shared.data(from: locURL)
            let dlCode = (dlResp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(dlCode) else {
                throw CloudSyncError("OneDrive 下載內容失敗 (HTTP \(dlCode))：\(SyncHttpUtils.extractErrorText(dlData))")
            }
            return dlData
        }

        guard (200...299).contains(code) else {
            throw CloudSyncError("OneDrive 下載失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
        }
        return data
    }

    func downloadFile(remotePath: String, destURL: URL) async throws -> Bool {
        let token = try await getValidAccessToken()
        let initialUrl = buildItemPathUrl(remotePath: remotePath, suffix: ":/content")
        let req = try makeGraphRequest(urlStr: initialUrl, method: "GET", token: token)
        let (data, resp) = try await noRedirectSession.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse else { return false }
        let code = httpResp.statusCode
        if code == 404 { return false }

        let fm = FileManager.default
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if [301, 302, 303, 307, 308].contains(code) {
            guard let loc = httpResp.value(forHTTPHeaderField: "Location"),
                  let locURL = URL(string: loc) else {
                throw CloudSyncError("OneDrive 下載重導向缺少 Location")
            }
            var dlReq = URLRequest(url: locURL, timeoutInterval: 240)
            dlReq.httpMethod = "GET"
            let (tempURL, dlResp) = try await URLSession.shared.download(for: dlReq)
            let dlCode = (dlResp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(dlCode) else {
                throw CloudSyncError("OneDrive 下載書檔失敗 (HTTP \(dlCode))")
            }
            if fm.fileExists(atPath: destURL.path) {
                try? fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)
            return true
        }

        guard (200...299).contains(code) else {
            throw CloudSyncError("OneDrive 下載書檔失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
        }
        try data.write(to: destURL, options: .atomic)
        return true
    }

    func uploadBytes(remotePath: String, data: Data, contentType: String) async throws {
        let token = try await getValidAccessToken()
        var req = try makeGraphRequest(urlStr: buildItemPathUrl(remotePath: remotePath, suffix: ":/content"), method: "PUT", token: token)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (respData, resp) = try await URLSession.shared.upload(for: req, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw CloudSyncError("OneDrive 上傳失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
    }

    func uploadFile(remotePath: String, sourceURL: URL, contentType: String) async throws {
        let token = try await getValidAccessToken()
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        if totalSize <= simpleUploadLimit {
            var req = try makeGraphRequest(urlStr: buildItemPathUrl(remotePath: remotePath, suffix: ":/content"), method: "PUT", token: token, timeout: 180)
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let (respData, resp) = try await URLSession.shared.upload(for: req, fromFile: sourceURL)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                throw CloudSyncError("OneDrive 上傳書檔失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
            }
        } else {
            try await uploadLargeFileChunked(token: token, remotePath: remotePath, sourceURL: sourceURL, totalSize: totalSize)
        }
    }

    private func uploadLargeFileChunked(token: String, remotePath: String, sourceURL: URL, totalSize: Int64) async throws {
        let sessionUrl = buildItemPathUrl(remotePath: remotePath, suffix: ":/createUploadSession")
        let reqBody: [String: Any] = [
            "item": ["@microsoft.graph.conflictBehavior": "replace"]
        ]
        var sessionReq = try makeGraphRequest(urlStr: sessionUrl, method: "POST", token: token)
        sessionReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        sessionReq.httpBody = try JSONSerialization.data(withJSONObject: reqBody)

        let (sessData, sessResp) = try await URLSession.shared.data(for: sessionReq)
        let sessCode = (sessResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(sessCode),
              let sessJson = (try? JSONSerialization.jsonObject(with: sessData)) as? [String: Any],
              let uploadUrlStr = sessJson["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadUrlStr) else {
            throw CloudSyncError("建立 OneDrive 大檔上傳工作階段失敗 (HTTP \(sessCode))：\(SyncHttpUtils.extractErrorText(sessData))")
        }

        let fh = try FileHandle(forReadingFrom: sourceURL)
        defer { try? fh.close() }

        var offset: Int64 = 0
        while offset < totalSize {
            let toRead = Int(min(Int64(uploadChunkSize), totalSize - offset))
            try fh.seek(toOffset: UInt64(offset))
            guard let chunkData = try fh.read(upToCount: toRead), !chunkData.isEmpty else {
                break
            }
            let bytesRead = Int64(chunkData.count)
            let rangeEnd = offset + bytesRead - 1

            var chunkReq = URLRequest(url: uploadURL, timeoutInterval: 120)
            chunkReq.httpMethod = "PUT"
            chunkReq.setValue("bytes \(offset)-\(rangeEnd)/\(totalSize)", forHTTPHeaderField: "Content-Range")
            chunkReq.setValue("\(bytesRead)", forHTTPHeaderField: "Content-Length")

            let (chunkRespData, chunkResp) = try await URLSession.shared.upload(for: chunkReq, from: chunkData)
            let chunkCode = (chunkResp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(chunkCode) else {
                throw CloudSyncError("OneDrive 分塊上傳失敗 (HTTP \(chunkCode))：\(SyncHttpUtils.extractErrorText(chunkRespData))")
            }
            offset += bytesRead
        }
    }

    func deleteFile(remotePath: String) async throws {
        let token = try await getValidAccessToken()
        let req = try makeGraphRequest(urlStr: buildItemPathUrl(remotePath: remotePath), method: "DELETE", token: token)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) || code == 404 else {
            throw CloudSyncError("OneDrive 刪除失敗 (HTTP \(code))")
        }
    }
}

private final class OneDriveNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
