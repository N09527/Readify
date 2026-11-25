import Foundation

final class WebDavClient: CloudStorageClient {
    let providerType: CloudProviderType = .WEBDAV

    private let config: WebDavConfig
    private let baseUrl: String
    private let rootFolder: String
    private let session: URLSession

    init(config: WebDavConfig) {
        self.config = config
        var trimmedBase = config.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        self.baseUrl = trimmedBase

        let trimmedRoot = config.remoteFolder.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        self.rootFolder = trimmedRoot.isEmpty ? "Readify" : trimmedRoot

        let authValue: String? = {
            if config.username.isEmpty && config.password.isEmpty { return nil }
            let raw = Data("\(config.username):\(config.password)".utf8)
            return "Basic " + raw.base64EncodedString()
        }()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg, delegate: WebDavRedirectDelegate(authHeader: authValue), delegateQueue: nil)
    }

    private func authHeader() -> String? {
        if config.username.isEmpty && config.password.isEmpty { return nil }
        let raw = Data("\(config.username):\(config.password)".utf8)
        return "Basic " + raw.base64EncodedString()
    }

    private func buildURL(remotePath: String, trailingSlash: Bool = false) throws -> URL {
        guard !baseUrl.isEmpty else {
            throw CloudSyncError("請先填寫 WebDAV 伺服器網址")
        }
        let clean = remotePath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        let folderEnc = SyncHttpUtils.urlEncodePath(rootFolder)
        let pathEnc = clean.isEmpty ? "" : "/" + SyncHttpUtils.urlEncodePath(clean)
        let suffix = trailingSlash ? "/" : ""
        let fullStr = "\(baseUrl)/\(folderEnc)\(pathEnc)\(suffix)"
        guard let url = URL(string: fullStr) else {
            throw CloudSyncError("無效的 WebDAV 網址：\(fullStr)")
        }
        return url
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Readify/1.1", forHTTPHeaderField: "User-Agent")
        if let auth = authHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func testConnection() async throws -> String {
        guard !baseUrl.isEmpty else {
            throw CloudSyncError("請先填寫 WebDAV 伺服器網址")
        }
        try await ensureRootFolder()
        let files = try await listFiles(subFolder: "")
        return "WebDAV 連線成功！資料夾「\(rootFolder)」目前有 \(files.count) 個項目。"
    }

    func ensureRootFolder() async throws {
        guard !baseUrl.isEmpty else {
            throw CloudSyncError("WebDAV 伺服器網址為空")
        }
        let segments = rootFolder.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var accum = ""
        for seg in segments {
            accum += "/" + SyncHttpUtils.urlEncodeSegment(seg)
            if let segURL = URL(string: "\(baseUrl)\(accum)/") {
                try await mkcol(url: segURL)
            }
        }
        let booksURL = try buildURL(remotePath: "books", trailingSlash: true)
        try await mkcol(url: booksURL)
    }

    private func mkcol(url: URL) async throws {
        let req = makeRequest(url: url, method: "MKCOL")
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if [200, 201, 204, 405].contains(code) { return }
        if code == 401 || code == 403 {
            throw CloudSyncError("WebDAV 帳密驗證失敗或無權限 (HTTP \(code))")
        }
        var probe = makeRequest(url: url, method: "PROPFIND")
        probe.setValue("0", forHTTPHeaderField: "Depth")
        let (_, probeResp) = try await session.data(for: probe)
        let probeCode = (probeResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(probeCode) else {
            throw CloudSyncError("建立 WebDAV 資料夾失敗 (MKCOL HTTP \(code))")
        }
    }

    func listFiles(subFolder: String) async throws -> [RemoteFileEntry] {
        let targetURL = try buildURL(remotePath: subFolder, trailingSlash: true)
        let propfindXml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<d:propfind xmlns:d=\"DAV:\"><d:prop>" +
            "<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>" +
            "</d:prop></d:propfind>"

        var req = makeRequest(url: targetURL, method: "PROPFIND")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(propfindXml.utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return [] }
        guard (200...299).contains(code) else {
            throw CloudSyncError("PROPFIND 失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
        }

        let reqPath = (targetURL.path.removingPercentEncoding ?? targetURL.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let parserDelegate = WebDavPropfindParser(requestNormalizedPath: reqPath)
        let xml = XMLParser(data: data)
        xml.delegate = parserDelegate
        xml.shouldProcessNamespaces = true
        _ = xml.parse()
        return parserDelegate.entries
    }

    func downloadBytes(remotePath: String) async throws -> Data? {
        let url = try buildURL(remotePath: remotePath)
        let req = makeRequest(url: url, method: "GET")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard (200...299).contains(code) else {
            throw CloudSyncError("WebDAV 下載失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(data))")
        }
        return data
    }

    func uploadBytes(remotePath: String, data: Data, contentType: String) async throws {
        let url = try buildURL(remotePath: remotePath)
        var req = makeRequest(url: url, method: "PUT")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (respData, resp) = try await session.upload(for: req, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw CloudSyncError("WebDAV 上傳失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
    }

    func downloadFile(remotePath: String, destURL: URL) async throws -> Bool {
        let url = try buildURL(remotePath: remotePath)
        let req = makeRequest(url: url, method: "GET")
        let (tempURL, resp) = try await session.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return false }
        guard (200...299).contains(code) else {
            throw CloudSyncError("WebDAV 下載書檔失敗 (HTTP \(code))")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }
        try fm.moveItem(at: tempURL, to: destURL)
        return true
    }

    func uploadFile(remotePath: String, sourceURL: URL, contentType: String) async throws {
        let url = try buildURL(remotePath: remotePath)
        var req = makeRequest(url: url, method: "PUT")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (respData, resp) = try await session.upload(for: req, fromFile: sourceURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw CloudSyncError("WebDAV 上傳書檔失敗 (HTTP \(code))：\(SyncHttpUtils.extractErrorText(respData))")
        }
    }

    func deleteFile(remotePath: String) async throws {
        let url = try buildURL(remotePath: remotePath)
        let req = makeRequest(url: url, method: "DELETE")
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) || code == 404 else {
            throw CloudSyncError("WebDAV 刪除失敗 (HTTP \(code))")
        }
    }
}

private final class WebDavRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let authHeader: String?

    init(authHeader: String?) {
        self.authHeader = authHeader
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if let auth = authHeader,
           task.originalRequest?.url?.host?.lowercased() == request.url?.host?.lowercased() {
            redirected.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}

private final class WebDavPropfindParser: NSObject, XMLParserDelegate {
    private let requestNormalizedPath: String
    var entries: [RemoteFileEntry] = []

    private var inResponse = false
    private var inResourceType = false
    private var currentText = ""
    private var currentHref = ""
    private var currentDisplayName = ""
    private var currentLength: Int64 = 0
    private var currentIsCollection = false

    init(requestNormalizedPath: String) {
        self.requestNormalizedPath = requestNormalizedPath
    }

    private func localTag(_ elementName: String, qualifiedName: String?) -> String {
        let raw = elementName.isEmpty ? (qualifiedName ?? "") : elementName
        if let colon = raw.lastIndex(of: ":") {
            return String(raw[raw.index(after: colon)...]).lowercased()
        }
        return raw.lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = localTag(elementName, qualifiedName: qName)
        currentText = ""
        if tag == "response" {
            inResponse = true
            currentHref = ""
            currentDisplayName = ""
            currentLength = 0
            currentIsCollection = false
        } else if inResponse && tag == "resourcetype" {
            inResourceType = true
        } else if inResponse && inResourceType && tag == "collection" {
            currentIsCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inResponse {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = localTag(elementName, qualifiedName: qName)
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inResponse {
            switch tag {
            case "href":
                if currentHref.isEmpty { currentHref = trimmed }
            case "displayname":
                currentDisplayName = trimmed
            case "getcontentlength":
                currentLength = Int64(trimmed) ?? 0
            case "resourcetype":
                inResourceType = false
            case "response":
                inResponse = false
                finalizeResponseEntry()
            default:
                break
            }
        }
        currentText = ""
    }

    private func finalizeResponseEntry() {
        guard !currentHref.isEmpty else { return }
        let hrefPath: String = {
            if (currentHref.lowercased().hasPrefix("http://") || currentHref.lowercased().hasPrefix("https://")),
               let u = URL(string: currentHref) {
                return u.path
            }
            return currentHref
        }()

        let decodedPath = hrefPath.removingPercentEncoding ?? hrefPath
        let normalizedHref = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedHref.lowercased() == requestNormalizedPath {
            return
        }

        let isDir = currentIsCollection || decodedPath.hasSuffix("/")
        let lastComponent = normalizedHref.split(separator: "/").last.map(String.init) ?? ""
        let name = lastComponent.isEmpty ? currentDisplayName : lastComponent
        guard !name.isEmpty else { return }

        entries.append(
            RemoteFileEntry(
                name: name,
                sizeBytes: currentLength,
                modifiedMs: 0,
                isDirectory: isDir,
                remoteId: normalizedHref
            )
        )
    }
}
