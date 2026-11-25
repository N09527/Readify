import Foundation

protocol CloudStorageClient {
    var providerType: CloudProviderType { get }
    func testConnection() async throws -> String
    func ensureRootFolder() async throws
    func listFiles(subFolder: String) async throws -> [RemoteFileEntry]
    func downloadBytes(remotePath: String) async throws -> Data?
    func uploadBytes(remotePath: String, data: Data, contentType: String) async throws
    func downloadFile(remotePath: String, destURL: URL) async throws -> Bool
    func uploadFile(remotePath: String, sourceURL: URL, contentType: String) async throws
    func deleteFile(remotePath: String) async throws
}

enum SyncHttpUtils {
    private static let unreservedCharset: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    static func urlEncodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: unreservedCharset) ?? segment
    }

    static func urlEncodePath(_ path: String) -> String {
        path.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { urlEncodeSegment($0) }
            .joined(separator: "/")
    }

    static func formEncode(_ params: [(String, String)]) -> Data {
        let body = params.map { (k, v) in
            "\(urlEncodeSegment(k))=\(urlEncodeSegment(v))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func extractErrorText(_ data: Data, maxLen: Int = 220) -> String {
        let str = String(data: data, encoding: .utf8) ?? ""
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLen { return trimmed }
        return String(trimmed.prefix(maxLen))
    }
}
