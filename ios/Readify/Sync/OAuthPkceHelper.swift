import AuthenticationServices
import CryptoKit
import Foundation
import Network
import SafariServices
import Security
import UIKit

struct OAuthTokenResult {
    var accessToken: String
    var refreshToken: String
    var expiresAtMs: Int64
}

enum OAuthPkceHelper {
    private static let googleAuthEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let googleTokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let googleDriveScope = "https://www.googleapis.com/auth/drive.file"
    private static let oneDriveScope = "offline_access Files.ReadWrite"

    @MainActor
    static func authorizeGoogle(config: GoogleDriveConfig) async throws -> OAuthTokenResult {
        let clientId = config.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            throw CloudSyncError("請先填寫 Google OAuth Client ID")
        }
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(verifier)
        let state = generateRandomState()
        let rawRedirect = config.redirectUri.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirect = rawRedirect.isEmpty ? "http://127.0.0.1:48123/callback" : rawRedirect

        var comps = URLComponents(string: googleAuthEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: googleDriveScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = comps.url else {
            throw CloudSyncError("無法產生 Google 授權網址")
        }

        let code = try await OAuthFlowCoordinator.shared.performAuth(
            authURL: authURL,
            redirectUri: redirect,
            expectedState: state
        )

        var params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", clientId),
            ("code", code),
            ("redirect_uri", redirect),
            ("code_verifier", verifier)
        ]
        let secret = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            params.append(("client_secret", secret))
        }
        return try await postTokenRequest(tokenUrl: googleTokenEndpoint, params: params, fallbackRefreshToken: "")
    }

    @MainActor
    static func authorizeOneDrive(config: OneDriveConfig) async throws -> OAuthTokenResult {
        let clientId = config.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            throw CloudSyncError("請先填寫 OneDrive Client ID")
        }
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(verifier)
        let state = generateRandomState()
        let rawTenant = config.tenantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenant = rawTenant.isEmpty ? "common" : rawTenant
        let rawRedirect = config.redirectUri.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirect = rawRedirect.isEmpty ? "com.inkflow.reader://oauth/onedrive" : rawRedirect

        var comps = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: oneDriveScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = comps.url else {
            throw CloudSyncError("無法產生 OneDrive 授權網址")
        }

        let code = try await OAuthFlowCoordinator.shared.performAuth(
            authURL: authURL,
            redirectUri: redirect,
            expectedState: state
        )

        let tokenUrl = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token"
        let params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", clientId),
            ("code", code),
            ("redirect_uri", redirect),
            ("code_verifier", verifier),
            ("scope", oneDriveScope)
        ]
        return try await postTokenRequest(tokenUrl: tokenUrl, params: params, fallbackRefreshToken: "")
    }

    @MainActor
    static func cancelActiveSession() {
        OAuthFlowCoordinator.shared.cancelCurrentFlow()
    }

    @MainActor
    static func handleRedirectURL(_ url: URL) -> Bool {
        OAuthFlowCoordinator.shared.handleIncomingURL(url)
    }

    static func refreshGoogleToken(config: GoogleDriveConfig) async throws -> OAuthTokenResult {
        let refresh = config.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty else {
            throw CloudSyncError("Google Drive 缺少 Refresh Token，請重新授權登入")
        }
        var params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", config.clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("refresh_token", refresh)
        ]
        let secret = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            params.append(("client_secret", secret))
        }
        return try await postTokenRequest(tokenUrl: googleTokenEndpoint, params: params, fallbackRefreshToken: refresh)
    }

    static func refreshOneDriveToken(config: OneDriveConfig) async throws -> OAuthTokenResult {
        let refresh = config.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty else {
            throw CloudSyncError("OneDrive 缺少 Refresh Token，請重新授權登入")
        }
        let rawTenant = config.tenantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenant = rawTenant.isEmpty ? "common" : rawTenant
        let tokenUrl = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token"
        let params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", config.clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("refresh_token", refresh),
            ("scope", oneDriveScope)
        ]
        return try await postTokenRequest(tokenUrl: tokenUrl, params: params, fallbackRefreshToken: refresh)
    }

    private static func postTokenRequest(
        tokenUrl: String,
        params: [(String, String)],
        fallbackRefreshToken: String
    ) async throws -> OAuthTokenResult {
        guard let url = URL(string: tokenUrl) else {
            throw CloudSyncError("無效的權杖交換網址")
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = SyncHttpUtils.formEncode(params)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let errDetail: String = {
                if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let e = (obj["error"] as? String) ?? ""
                    let d = (obj["error_description"] as? String) ?? ""
                    let joined = "\(e): \(d)".trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                    if !joined.isEmpty { return joined }
                }
                return SyncHttpUtils.extractErrorText(data)
            }()
            throw CloudSyncError("權杖交換失敗 (HTTP \(status))：\(errDetail)")
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw CloudSyncError("伺服器未回傳有效的 access_token")
        }

        let rawRefresh = (json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refreshToken = rawRefresh.isEmpty ? fallbackRefreshToken : rawRefresh
        let expiresInSec = (json["expires_in"] as? NSNumber)?.int64Value ?? 3600
        let expiresAtMs = BookItem.nowMs() + expiresInSec * 1000
        return OAuthTokenResult(accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func generateCodeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func generateRandomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class OAuthFlowCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding, SFSafariViewControllerDelegate {
    static let shared = OAuthFlowCoordinator()

    private var activeWebAuthSession: ASWebAuthenticationSession?
    private var activeListener: NWListener?
    private weak var activeSafariVC: SFSafariViewController?
    private var expectedState: String = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    func performAuth(authURL: URL, redirectUri: String, expectedState: String) async throws -> String {
        cancelCurrentFlow()
        self.expectedState = expectedState

        let parsed = URLComponents(string: redirectUri)
        let scheme = parsed?.scheme?.lowercased() ?? ""
        let host = parsed?.host?.lowercased() ?? ""
        let isLoopback = (scheme == "http") && (host == "127.0.0.1" || host == "localhost")

        if isLoopback {
            let portVal = UInt16(clamping: parsed?.port ?? 48123)
            let safePort: UInt16 = (portVal >= 1024) ? portVal : 48123
            return try await performLoopbackAuth(authURL: authURL, port: safePort)
        } else {
            guard !scheme.isEmpty else {
                throw CloudSyncError("無效的 Redirect URI：\(redirectUri)")
            }
            return try await performCustomSchemeAuth(authURL: authURL, callbackScheme: scheme)
        }
    }

    private func performCustomSchemeAuth(authURL: URL, callbackScheme: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeWebAuthSession = nil
                    if let callbackURL {
                        _ = self.handleIncomingURL(callbackURL)
                    } else if let authErr = error as? ASWebAuthenticationSessionError, authErr.code == .canceledLogin {
                        self.finishFlow(with: .failure(CloudSyncError("已取消授權登入")))
                    } else if let error {
                        self.finishFlow(with: .failure(CloudSyncError("授權失敗：\(error.localizedDescription)")))
                    } else {
                        self.finishFlow(with: .failure(CloudSyncError("未收到授權回呼")))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.activeWebAuthSession = session
            if !session.start() {
                self.activeWebAuthSession = nil
                self.finishFlow(with: .failure(CloudSyncError("無法啟動系統授權視窗")))
            }
        }
    }

    private func performLoopbackAuth(authURL: URL, port: UInt16) async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CloudSyncError("無效的本機回呼連接埠：\(port)")
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw CloudSyncError("無法啟動本機回呼監聽埠 \(port)：\(error.localizedDescription)")
        }

        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "ReadifyOAuthLoopback") { [weak self] in
            Task { @MainActor in
                self?.cancelCurrentFlow()
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            self.activeListener = listener

            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    guard let data, let reqText = String(data: data, encoding: .utf8) else {
                        conn.cancel()
                        return
                    }
                    let firstLine = reqText.components(separatedBy: "\r\n").first ?? ""
                    let parts = firstLine.split(separator: " ")
                    guard parts.count >= 2 else {
                        conn.cancel()
                        return
                    }
                    let target = String(parts[1])
                    if target.hasPrefix("/favicon.ico") {
                        let notFound = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
                        conn.send(content: notFound, completion: .contentProcessed { _ in conn.cancel() })
                        return
                    }

                    let fullURL = URL(string: "http://127.0.0.1:\(port)\(target)")
                    let items = fullURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                    let errVal = items.first(where: { $0.name == "error" })?.value ?? ""
                    let htmlBody: String
                    if !errVal.isEmpty {
                        htmlBody = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:40px;\"><h2>授權未完成</h2><p>\(errVal)</p><p>請關閉此視窗返回 Readify。</p></body></html>"
                    } else {
                        htmlBody = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:40px;\"><h2>授權成功！</h2><p>已取得存取權杖，正在自動返回 <b>Readify</b>…</p></body></html>"
                    }
                    let bodyBytes = Data(htmlBody.utf8)
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
                    var respData = Data(header.utf8)
                    respData.append(bodyBytes)

                    conn.send(content: respData, completion: .contentProcessed { _ in
                        conn.cancel()
                        if let fullURL {
                            Task { @MainActor in
                                _ = self?.handleIncomingURL(fullURL)
                            }
                        }
                    })
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    Task { @MainActor in
                        self?.finishFlow(with: .failure(CloudSyncError("本機回呼監聽失敗：\(err.localizedDescription)")))
                    }
                }
            }

            listener.start(queue: .main)

            if let topVC = Self.topViewController() {
                let safari = SFSafariViewController(url: authURL)
                safari.delegate = self
                safari.modalPresentationStyle = .pageSheet
                self.activeSafariVC = safari
                topVC.present(safari, animated: true)
            } else {
                UIApplication.shared.open(authURL)
            }
        }
    }

    func handleIncomingURL(_ url: URL) -> Bool {
        guard continuation != nil else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value, !err.isEmpty {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
            finishFlow(with: .failure(CloudSyncError("授權遭拒：\(err) \(desc)".trimmingCharacters(in: .whitespaces))))
            return true
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return false
        }
        if let returnedState = items.first(where: { $0.name == "state" })?.value,
           !expectedState.isEmpty && returnedState != expectedState {
            finishFlow(with: .failure(CloudSyncError("OAuth state 驗證不符，已中止授權")))
            return true
        }
        finishFlow(with: .success(code))
        return true
    }

    func cancelCurrentFlow() {
        finishFlow(with: .failure(CloudSyncError("授權流程已取消")))
    }

    private func finishFlow(with result: Result<String, Error>) {
        activeWebAuthSession?.cancel()
        activeWebAuthSession = nil
        activeListener?.cancel()
        activeListener = nil

        if let safari = activeSafariVC {
            activeSafariVC = nil
            safari.dismiss(animated: true)
        }

        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }

        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        }
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor in
            self.activeSafariVC = nil
            self.finishFlow(with: .failure(CloudSyncError("已關閉授權視窗")))
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let keyWin = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
                return keyWin
            }
            if let firstScene = scenes.first {
                return ASPresentationAnchor(windowScene: firstScene)
            }
            return ASPresentationAnchor()
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController
            ?? scenes.first?.windows.first?.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
