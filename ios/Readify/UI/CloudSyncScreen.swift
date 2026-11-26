import SwiftUI

struct CloudSyncScreen: View {
    let repository: AppRepository
    let eInkMode: Bool
    let onSyncCompleted: () -> Void
    let onBack: () -> Void

    @State private var config: CloudSyncConfig = CloudSyncConfig()
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showPassword = false
    @State private var showGuide = false
    @State private var remoteFilesPreview: [RemoteFileEntry]?

    private var bgColor: Color {
        eInkMode ? .white : Color(uiColor: .systemBackground)
    }

    private var fgColor: Color {
        eInkMode ? .black : .primary
    }

    private var cardBgColor: Color {
        eInkMode ? .white : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var cardBorderColor: Color {
        eInkMode ? .black : Color.secondary.opacity(0.25)
    }

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        providerSelectorSection

                        if let msg = statusMessage {
                            statusBanner(msg)
                        }

                        providerConfigCard

                        syncScopeAndActionsCard

                        if let files = remoteFilesPreview {
                            cloudFilesPreviewCard(files)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear {
            config = repository.loadCloudSyncConfig()
        }
    }

    private func updateConfig(_ updated: CloudSyncConfig) {
        config = updated
        repository.saveCloudSyncConfig(updated)
    }

    // MARK: - Top Header (Custom, Immune to iOS 26 Liquid Glass Toolbar Compression)

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button {
                OAuthPkceHelper.cancelActiveSession()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(fgColor)
                    .frame(width: 36, height: 36)
                    .background(eInkMode ? Color.white : Color(uiColor: .tertiarySystemFill))
                    .clipShape(Circle())
                    .overlay {
                        if eInkMode {
                            Circle().strokeBorder(Color.black, lineWidth: 1)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("雲端同步設定")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(fgColor)
                    .lineLimit(1)
                Text("WebDAV · Google Drive · OneDrive（與 Android 版雙向互通）")
                    .font(.caption)
                    .foregroundStyle(fgColor.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Provider Selector

    private var providerSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("選擇雲端服務")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fgColor)

            HStack(spacing: 8) {
                ForEach(CloudProviderType.allCases) { provider in
                    let selected = config.activeProvider == provider
                    Button {
                        guard !isBusy else { return }
                        showGuide = false
                        remoteFilesPreview = nil
                        var copy = config
                        copy.activeProvider = provider
                        updateConfig(copy)
                    } label: {
                        Text(provider.label)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(
                                eInkMode
                                    ? (selected ? Color.white : Color.black)
                                    : (selected ? Color.white : fgColor)
                            )
                            .background(
                                eInkMode
                                    ? (selected ? Color.black : Color.white)
                                    : (selected ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        eInkMode ? Color.black : (selected ? Color.accentColor : Color.secondary.opacity(0.25)),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func statusBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(
                    eInkMode ? .black : (statusIsError ? Color.red : fgColor)
                )
            if isBusy {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            eInkMode
                ? Color(white: 0.94)
                : (statusIsError ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            if eInkMode {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black, lineWidth: 1)
            }
        }
    }

    // MARK: - Provider Config Card

    private var providerConfigCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch config.activeProvider {
            case .WEBDAV:
                webDavFields
            case .GOOGLE_DRIVE:
                googleDriveFields
            case .ONEDRIVE:
                oneDriveFields
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBgColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(cardBorderColor, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var webDavFields: some View {
        Text("WebDAV 伺服器設定")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(fgColor)

        Text("適用 Nextcloud、Synology/QNAP NAS、Alist、堅果雲或任何標準 WebDAV 服務。")
            .font(.caption)
            .foregroundStyle(fgColor.opacity(0.7))

        labeledTextField(
            label: "伺服器網址",
            placeholder: "例如：https://nas.example.com:5006/dav",
            text: Binding(
                get: { config.webDav.serverUrl },
                set: { val in var c = config; c.webDav.serverUrl = val; updateConfig(c) }
            ),
            keyboard: .URL
        )

        labeledTextField(
            label: "帳號",
            placeholder: "輸入 WebDAV 帳號",
            text: Binding(
                get: { config.webDav.username },
                set: { val in var c = config; c.webDav.username = val; updateConfig(c) }
            )
        )

        labeledSecureField(
            label: "密碼 / 應用程式密碼",
            placeholder: "輸入密碼",
            text: Binding(
                get: { config.webDav.password },
                set: { val in var c = config; c.webDav.password = val; updateConfig(c) }
            )
        )

        labeledTextField(
            label: "遠端同步資料夾名稱",
            placeholder: "Readify",
            text: Binding(
                get: { config.webDav.remoteFolder },
                set: { val in var c = config; c.webDav.remoteFolder = val; updateConfig(c) }
            )
        )
    }

    @ViewBuilder
    private var googleDriveFields: some View {
        HStack {
            Text("Google Drive 授權設定")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(fgColor)
            Spacer()
            Button(showGuide ? "收合申請說明" : "申請步驟說明") {
                showGuide.toggle()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }

        if showGuide {
            Text(
                "1. 前往 Google Cloud Console 建立專案並啟用「Google Drive API」。\n" +
                "2. 在「OAuth 同意畫面」加入你自己的 Gmail 為測試使用者。\n" +
                "3. 到「憑證 → 建立憑證 → OAuth 用戶端 ID」，可直接選用與 Android 相同的「電腦版應用程式 (Desktop app)」（Redirect URI 維持 http://127.0.0.1:48123/callback），或建立「iOS」憑證。\n" +
                "4. 貼上 Client ID 與 Client Secret 後點「授權登入 Google」，授權完成後視窗會自動返回 Readify。"
            )
            .font(.caption)
            .foregroundStyle(fgColor.opacity(0.85))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        Text(config.googleDrive.isAuthorized ? "授權狀態：已連線 Google Drive" : "授權狀態：尚未授權")
            .font(.caption.weight(.semibold))
            .foregroundStyle(config.googleDrive.isAuthorized ? (eInkMode ? .black : Color.accentColor) : fgColor.opacity(0.65))

        labeledTextField(
            label: "Google OAuth Client ID",
            placeholder: "xxxx.apps.googleusercontent.com",
            text: Binding(
                get: { config.googleDrive.clientId },
                set: { val in var c = config; c.googleDrive.clientId = val; updateConfig(c) }
            )
        )

        labeledSecureField(
            label: "Client Secret（Desktop 憑證必填）",
            placeholder: "GOCSPX-...",
            text: Binding(
                get: { config.googleDrive.clientSecret },
                set: { val in var c = config; c.googleDrive.clientSecret = val; updateConfig(c) }
            )
        )

        labeledTextField(
            label: "Redirect URI",
            placeholder: "http://127.0.0.1:48123/callback",
            text: Binding(
                get: { config.googleDrive.redirectUri },
                set: { val in var c = config; c.googleDrive.redirectUri = val; updateConfig(c) }
            ),
            keyboard: .URL
        )

        labeledTextField(
            label: "Google Drive 同步資料夾名稱",
            placeholder: "Readify",
            text: Binding(
                get: { config.googleDrive.remoteFolder },
                set: { val in var c = config; c.googleDrive.remoteFolder = val; updateConfig(c) }
            )
        )

        HStack(spacing: 8) {
            Button {
                startGoogleOAuth()
            } label: {
                Text(config.googleDrive.isAuthorized ? "重新授權登入" : "瀏覽器授權登入 Google")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(eInkMode ? .black : .accentColor)
            .disabled(isBusy || config.googleDrive.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if config.googleDrive.isAuthorized {
                Button("登出") {
                    var c = config
                    c.googleDrive.accessToken = ""
                    c.googleDrive.refreshToken = ""
                    c.googleDrive.tokenExpiresAtMs = 0
                    updateConfig(c)
                    statusIsError = false
                    statusMessage = "已清除 Google Drive 登入憑證"
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
    }

    @ViewBuilder
    private var oneDriveFields: some View {
        HStack {
            Text("Microsoft OneDrive 授權設定")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(fgColor)
            Spacer()
            Button(showGuide ? "收合申請說明" : "申請步驟說明") {
                showGuide.toggle()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }

        if showGuide {
            Text(
                "1. 前往 Microsoft Entra 管理中心（Azure Portal → 應用程式註冊 → 新增註冊）。\n" +
                "2. 支援的帳戶類型請選「任何組織目錄中的帳戶和個人 Microsoft 帳戶」（Tenant 保持 common）。\n" +
                "3. 重新導向 URI 平台選「行動裝置和傳統型應用程式」，填入：\n" +
                "   com.inkflow.reader://oauth/onedrive\n" +
                "4. 在「API 權限」確認已加入 Microsoft Graph 委派權限：Files.ReadWrite 與 offline_access。\n" +
                "5. 將與 Android 相同的「應用程式 (用戶端) 識別碼 (Client ID)」貼到下方後點登入即可（免 Client Secret）。"
            )
            .font(.caption)
            .foregroundStyle(fgColor.opacity(0.85))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        Text(config.oneDrive.isAuthorized ? "授權狀態：已連線 Microsoft OneDrive" : "授權狀態：尚未授權")
            .font(.caption.weight(.semibold))
            .foregroundStyle(config.oneDrive.isAuthorized ? (eInkMode ? .black : Color.accentColor) : fgColor.opacity(0.65))

        labeledTextField(
            label: "Azure 應用程式 (用戶端) 識別碼 Client ID",
            placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            text: Binding(
                get: { config.oneDrive.clientId },
                set: { val in var c = config; c.oneDrive.clientId = val; updateConfig(c) }
            )
        )

        labeledTextField(
            label: "Tenant（預設 common，僅個人帳號可填 consumers）",
            placeholder: "common",
            text: Binding(
                get: { config.oneDrive.tenantId },
                set: { val in var c = config; c.oneDrive.tenantId = val; updateConfig(c) }
            )
        )

        labeledTextField(
            label: "Redirect URI",
            placeholder: "com.inkflow.reader://oauth/onedrive",
            text: Binding(
                get: { config.oneDrive.redirectUri },
                set: { val in var c = config; c.oneDrive.redirectUri = val; updateConfig(c) }
            ),
            keyboard: .URL
        )

        labeledTextField(
            label: "OneDrive 同步資料夾名稱",
            placeholder: "Readify",
            text: Binding(
                get: { config.oneDrive.remoteFolder },
                set: { val in var c = config; c.oneDrive.remoteFolder = val; updateConfig(c) }
            )
        )

        HStack(spacing: 8) {
            Button {
                startOneDriveOAuth()
            } label: {
                Text(config.oneDrive.isAuthorized ? "重新授權登入" : "瀏覽器授權登入 Microsoft")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(eInkMode ? .black : .accentColor)
            .disabled(isBusy || config.oneDrive.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if config.oneDrive.isAuthorized {
                Button("登出") {
                    var c = config
                    c.oneDrive.accessToken = ""
                    c.oneDrive.refreshToken = ""
                    c.oneDrive.tokenExpiresAtMs = 0
                    updateConfig(c)
                    statusIsError = false
                    statusMessage = "已清除 OneDrive 登入憑證"
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
    }

    // MARK: - Sync Scope & Actions Card

    private var syncScopeAndActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("同步項目與執行")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(fgColor)

            Toggle(isOn: Binding(
                get: { config.autoSyncOnBookOpenClose },
                set: { val in var c = config; c.autoSyncOnBookOpenClose = val; updateConfig(c) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("開啟與離開書本時自動同步")
                        .font(.subheadline)
                        .foregroundStyle(fgColor)
                    Text("已設定雲端服務時，開書前自動抓取最新進度、按返回離開時自動同步至雲端")
                        .font(.caption2)
                        .foregroundStyle(fgColor.opacity(0.65))
                }
            }

            Toggle(isOn: Binding(
                get: { config.syncBookFiles },
                set: { val in var c = config; c.syncBookFiles = val; updateConfig(c) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步電子書／漫畫書檔本體")
                        .font(.subheadline)
                        .foregroundStyle(fgColor)
                    Text("關閉時僅同步書架分組、閱讀進度與書籤（最省流量）")
                        .font(.caption2)
                        .foregroundStyle(fgColor.opacity(0.65))
                }
            }

            Toggle(isOn: Binding(
                get: { config.syncReaderSettings },
                set: { val in var c = config; c.syncReaderSettings = val; updateConfig(c) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步排版與閱讀設定")
                        .font(.subheadline)
                        .foregroundStyle(fgColor)
                    Text("同步字級、行距、邊界、主題與點擊區域（保留各裝置本機字體與書封大小）")
                        .font(.caption2)
                        .foregroundStyle(fgColor.opacity(0.65))
                }
            }

            if config.lastSyncTimeMs > 0 {
                Divider()
                Text("上次同步：\(formatTimestamp(config.lastSyncTimeMs))\n\(config.lastSyncSummary)")
                    .font(.caption)
                    .foregroundStyle(fgColor.opacity(0.75))
            }

            HStack(spacing: 10) {
                Button {
                    runTestConnection()
                } label: {
                    Label("測試連線", systemImage: "wifi")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button {
                    runSyncNow()
                } label: {
                    Label("立即雙向同步", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(eInkMode ? .black : .accentColor)
                .disabled(isBusy)
            }

            Button {
                runListCloudFiles()
            } label: {
                Label("檢視雲端檔案清單", systemImage: "icloud")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBgColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(cardBorderColor, lineWidth: 1)
        }
    }

    private func cloudFilesPreviewCard(_ files: [RemoteFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("雲端檔案（共 \(files.count) 項）")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(fgColor)

            if files.isEmpty {
                Text("目前資料夾是空的")
                    .font(.footnote)
                    .foregroundStyle(fgColor.opacity(0.65))
            } else {
                ForEach(files.prefix(40)) { entry in
                    HStack {
                        Text(entry.name)
                            .font(.footnote)
                            .foregroundStyle(fgColor)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.isDirectory ? "資料夾" : formatBytes(entry.sizeBytes))
                            .font(.caption2)
                            .foregroundStyle(fgColor.opacity(0.65))
                    }
                }
                if files.count > 40 {
                    Text("…還有 \(files.count - 40) 個檔案")
                        .font(.caption2)
                        .foregroundStyle(fgColor.opacity(0.65))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBgColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(cardBorderColor, lineWidth: 1)
        }
    }

    // MARK: - Field Helpers

    private func labeledTextField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(fgColor.opacity(0.8))
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func labeledSecureField(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(fgColor.opacity(0.8))
            HStack(spacing: 6) {
                Group {
                    if showPassword {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Async Actions

    private func startGoogleOAuth() {
        Task { @MainActor in
            isBusy = true
            statusIsError = false
            statusMessage = "正在開啟授權視窗進行 Google 登入…"
            do {
                let token = try await OAuthPkceHelper.authorizeGoogle(config: config.googleDrive)
                var updated = config
                updated.googleDrive.accessToken = token.accessToken
                updated.googleDrive.refreshToken = token.refreshToken
                updated.googleDrive.tokenExpiresAtMs = token.expiresAtMs
                updateConfig(updated)
                statusIsError = false
                statusMessage = "Google Drive 授權成功！現在可以點「測試連線」或「立即雙向同步」。"
            } catch {
                statusIsError = true
                statusMessage = "Google Drive 授權失敗：\(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func startOneDriveOAuth() {
        Task { @MainActor in
            isBusy = true
            statusIsError = false
            statusMessage = "正在開啟授權視窗進行 Microsoft OneDrive 登入…"
            do {
                let token = try await OAuthPkceHelper.authorizeOneDrive(config: config.oneDrive)
                var updated = config
                updated.oneDrive.accessToken = token.accessToken
                updated.oneDrive.refreshToken = token.refreshToken
                updated.oneDrive.tokenExpiresAtMs = token.expiresAtMs
                updateConfig(updated)
                statusIsError = false
                statusMessage = "Microsoft OneDrive 授權成功！現在可以點「測試連線」或「立即雙向同步」。"
            } catch {
                statusIsError = true
                statusMessage = "OneDrive 授權失敗：\(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func runTestConnection() {
        let currentCfg = config
        let repo = repository
        Task {
            await MainActor.run {
                isBusy = true
                statusIsError = false
                statusMessage = "正在測試 \(currentCfg.activeProvider.label) 連線…"
            }
            let manager = CloudSyncManager(repository: repo)
            do {
                let msg = try await manager.testConnection(config: currentCfg) { updated in
                    Task { @MainActor in config = updated }
                }
                await MainActor.run {
                    statusIsError = false
                    statusMessage = msg
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    statusIsError = true
                    statusMessage = "連線測試失敗：\(error.localizedDescription)"
                    isBusy = false
                }
            }
        }
    }

    private func runSyncNow() {
        let currentCfg = config
        let repo = repository
        Task {
            await MainActor.run {
                isBusy = true
                statusIsError = false
                statusMessage = "準備開始雙向同步…"
            }
            let manager = CloudSyncManager(repository: repo)
            do {
                let report = try await manager.syncNow(
                    config: currentCfg,
                    onConfigUpdated: { updated in
                        Task { @MainActor in config = updated }
                    },
                    onProgress: { progressMsg in
                        await MainActor.run { statusMessage = progressMsg }
                    }
                )
                await MainActor.run {
                    statusIsError = !report.errors.isEmpty
                    if report.errors.isEmpty {
                        statusMessage = "同步完成！\(report.toDisplaySummary())"
                    } else {
                        let topErrs = report.errors.prefix(3).joined(separator: "\n")
                        statusMessage = "同步已完成（部分異常）：\(report.toDisplaySummary())\n\(topErrs)"
                    }
                    onSyncCompleted()
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    statusIsError = true
                    statusMessage = "同步失敗：\(error.localizedDescription)"
                    isBusy = false
                }
            }
        }
    }

    private func runListCloudFiles() {
        let currentCfg = config
        let repo = repository
        Task {
            await MainActor.run {
                isBusy = true
                statusIsError = false
                statusMessage = "正在讀取雲端同步資料夾清單…"
            }
            let manager = CloudSyncManager(repository: repo)
            do {
                let list = try await manager.listCloudFiles(config: currentCfg) { updated in
                    Task { @MainActor in config = updated }
                }
                await MainActor.run {
                    remoteFilesPreview = list
                    statusIsError = false
                    statusMessage = "雲端共偵測到 \(list.count) 個項目"
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    statusIsError = true
                    statusMessage = "讀取雲端清單失敗：\(error.localizedDescription)"
                    isBusy = false
                }
            }
        }
    }

    private func formatTimestamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return df.string(from: date)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024.0)
    }
}
