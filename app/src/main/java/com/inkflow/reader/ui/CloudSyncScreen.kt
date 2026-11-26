package com.inkflow.reader.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.inkflow.reader.data.AppRepository
import com.inkflow.reader.sync.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudSyncScreen(
    repository: AppRepository,
    eInkMode: Boolean,
    onSyncCompleted: () -> Unit,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val syncManager = remember { CloudSyncManager(repository) }

    var config by remember { mutableStateOf(repository.loadCloudSyncConfig()) }
    var isBusy by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var statusIsError by remember { mutableStateOf(false) }
    var showPassword by remember { mutableStateOf(false) }
    var showGuide by remember { mutableStateOf(false) }
    var remoteFilesPreview by remember { mutableStateOf<List<RemoteFileEntry>?>(null) }

    BackHandler {
        OAuthPkceHelper.cancelActiveSession()
        onBack()
    }

    fun updateConfig(updated: CloudSyncConfig) {
        config = updated
        repository.saveCloudSyncConfig(updated)
    }

    val bgColor = if (eInkMode) Color.White else MaterialTheme.colorScheme.background
    val textColor = if (eInkMode) Color.Black else MaterialTheme.colorScheme.onBackground
    val cardBorder = BorderStroke(1.dp, if (eInkMode) Color.Black else MaterialTheme.colorScheme.outlineVariant)
    val cardColors = CardDefaults.outlinedCardColors(
        containerColor = if (eInkMode) Color.White else MaterialTheme.colorScheme.surface
    )

    Scaffold(
        containerColor = bgColor,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = bgColor,
                    titleContentColor = textColor,
                    navigationIconContentColor = textColor
                ),
                navigationIcon = {
                    IconButton(onClick = {
                        OAuthPkceHelper.cancelActiveSession()
                        onBack()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回書架")
                    }
                },
                title = {
                    Column {
                        Text("雲端同步設定", fontWeight = FontWeight.Bold)
                        Text(
                            text = "WebDAV · Google Drive · OneDrive",
                            style = MaterialTheme.typography.labelSmall,
                            color = textColor.copy(alpha = 0.65f)
                        )
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // ---------------- Provider Selector ----------------
            Text("選擇雲端服務", style = MaterialTheme.typography.labelLarge, color = textColor)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                CloudProviderType.entries.forEach { provider ->
                    FilterChip(
                        selected = config.activeProvider == provider,
                        onClick = {
                            if (!isBusy) {
                                showGuide = false
                                remoteFilesPreview = null
                                updateConfig(config.copy(activeProvider = provider))
                            }
                        },
                        label = { Text(provider.label, maxLines = 1) },
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            // ---------------- Live Status Banner ----------------
            if (statusMessage != null) {
                Surface(
                    color = when {
                        eInkMode -> Color(0xFFEEEEEE)
                        statusIsError -> MaterialTheme.colorScheme.errorContainer
                        else -> MaterialTheme.colorScheme.secondaryContainer
                    },
                    shape = RoundedCornerShape(10.dp),
                    border = if (eInkMode) BorderStroke(1.dp, Color.Black) else null,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            text = statusMessage!!,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (eInkMode) Color.Black else if (statusIsError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSecondaryContainer
                        )
                        if (isBusy) {
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        }
                    }
                }
            }

            // ---------------- Provider Configuration Card ----------------
            OutlinedCard(
                colors = cardColors,
                border = cardBorder,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    when (config.activeProvider) {
                        CloudProviderType.WEBDAV -> {
                            Text("WebDAV 伺服器設定", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                            Text(
                                text = "適用 Nextcloud、Synology/QNAP NAS、堅果雲或任何標準 WebDAV 服務。",
                                style = MaterialTheme.typography.bodySmall,
                                color = textColor.copy(alpha = 0.7f)
                            )
                            OutlinedTextField(
                                value = config.webDav.serverUrl,
                                onValueChange = { updateConfig(config.copy(webDav = config.webDav.copy(serverUrl = it))) },
                                label = { Text("伺服器網址") },
                                placeholder = { Text("例如：https://nas.example.com:5006/dav") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.webDav.username,
                                onValueChange = { updateConfig(config.copy(webDav = config.webDav.copy(username = it))) },
                                label = { Text("帳號") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.webDav.password,
                                onValueChange = { updateConfig(config.copy(webDav = config.webDav.copy(password = it))) },
                                label = { Text("密碼 / 應用程式密碼") },
                                singleLine = true,
                                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                                trailingIcon = {
                                    IconButton(onClick = { showPassword = !showPassword }) {
                                        Icon(
                                            imageVector = if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                            contentDescription = "顯示密碼"
                                        )
                                    }
                                },
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.webDav.remoteFolder,
                                onValueChange = { updateConfig(config.copy(webDav = config.webDav.copy(remoteFolder = it))) },
                                label = { Text("遠端同步資料夾名稱") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }

                        CloudProviderType.GOOGLE_DRIVE -> {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text("Google Drive 授權設定", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                                AssistChip(
                                    onClick = { showGuide = !showGuide },
                                    label = { Text(if (showGuide) "收合申請說明" else "申請步驟說明") }
                                )
                            }

                            if (showGuide) {
                                Surface(
                                    color = if (eInkMode) Color(0xFFF5F5F5) else MaterialTheme.colorScheme.surfaceVariant,
                                    shape = RoundedCornerShape(8.dp),
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text(
                                        text = "1. 前往 Google Cloud Console 建立專案並啟用「Google Drive API」。\n" +
                                            "2. 在「OAuth 同意畫面」加入你自己的 Gmail 為測試使用者。\n" +
                                            "3. 到「憑證 → 建立憑證 → OAuth 用戶端 ID」，類型選「電腦版應用程式 (Desktop app)」（最簡單、免填 SHA-1，且支援本機迴路 http://127.0.0.1:48123/callback）。\n" +
                                            "4. 將取得的 Client ID 與 Client Secret 貼到下方後點「使用瀏覽器授權登入 Google」即可。",
                                        style = MaterialTheme.typography.bodySmall,
                                        modifier = Modifier.padding(10.dp)
                                    )
                                }
                            }

                            Text(
                                text = if (config.googleDrive.isAuthorized) "授權狀態：已連線 Google Drive" else "授權狀態：尚未授權",
                                style = MaterialTheme.typography.bodySmall,
                                fontWeight = FontWeight.Medium,
                                color = if (config.googleDrive.isAuthorized) {
                                    if (eInkMode) Color.Black else MaterialTheme.colorScheme.primary
                                } else textColor.copy(alpha = 0.65f)
                            )

                            OutlinedTextField(
                                value = config.googleDrive.clientId,
                                onValueChange = { updateConfig(config.copy(googleDrive = config.googleDrive.copy(clientId = it))) },
                                label = { Text("Google OAuth Client ID") },
                                placeholder = { Text("xxxx.apps.googleusercontent.com") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.googleDrive.clientSecret,
                                onValueChange = { updateConfig(config.copy(googleDrive = config.googleDrive.copy(clientSecret = it))) },
                                label = { Text("Client Secret（Desktop 憑證必填）") },
                                singleLine = true,
                                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                                trailingIcon = {
                                    IconButton(onClick = { showPassword = !showPassword }) {
                                        Icon(
                                            imageVector = if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                            contentDescription = "顯示 Secret"
                                        )
                                    }
                                },
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.googleDrive.redirectUri,
                                onValueChange = { updateConfig(config.copy(googleDrive = config.googleDrive.copy(redirectUri = it))) },
                                label = { Text("Redirect URI") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.googleDrive.remoteFolder,
                                onValueChange = { updateConfig(config.copy(googleDrive = config.googleDrive.copy(remoteFolder = it))) },
                                label = { Text("Google Drive 同步資料夾名稱") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Button(
                                    enabled = !isBusy && config.googleDrive.clientId.isNotBlank(),
                                    onClick = {
                                        scope.launch {
                                            isBusy = true
                                            statusIsError = false
                                            statusMessage = "正在開啟瀏覽器進行 Google 授權，完成後請切回 Readify…"
                                            val session = OAuthPkceHelper.createGoogleSession(config.googleDrive)
                                            runCatching {
                                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(session.authUrl)))
                                            }.onFailure { err ->
                                                isBusy = false
                                                statusIsError = true
                                                statusMessage = "無法開啟瀏覽器：${err.message}"
                                                return@launch
                                            }
                                            val res = OAuthPkceHelper.awaitAndExchangeToken(session)
                                            res.onSuccess { token ->
                                                updateConfig(
                                                    config.copy(
                                                        googleDrive = config.googleDrive.copy(
                                                            accessToken = token.accessToken,
                                                            refreshToken = token.refreshToken,
                                                            tokenExpiresAtMs = token.expiresAtMs
                                                        )
                                                    )
                                                )
                                                statusIsError = false
                                                statusMessage = "Google Drive 授權成功！現在可以點「測試連線」或「立即雙向同步」。"
                                            }.onFailure { err ->
                                                statusIsError = true
                                                statusMessage = "Google Drive 授權失敗：${err.message}"
                                            }
                                            isBusy = false
                                        }
                                    },
                                    modifier = Modifier.weight(1f)
                                ) {
                                    Text(if (config.googleDrive.isAuthorized) "重新授權登入" else "瀏覽器授權登入 Google")
                                }

                                if (config.googleDrive.isAuthorized) {
                                    OutlinedButton(
                                        enabled = !isBusy,
                                        onClick = {
                                            updateConfig(
                                                config.copy(
                                                    googleDrive = config.googleDrive.copy(
                                                        accessToken = "",
                                                        refreshToken = "",
                                                        tokenExpiresAtMs = 0L
                                                    )
                                                )
                                            )
                                            statusIsError = false
                                            statusMessage = "已清除 Google Drive 登入憑證"
                                        }
                                    ) { Text("登出") }
                                }
                            }
                        }

                        CloudProviderType.ONEDRIVE -> {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text("Microsoft OneDrive 授權設定", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                                AssistChip(
                                    onClick = { showGuide = !showGuide },
                                    label = { Text(if (showGuide) "收合申請說明" else "申請步驟說明") }
                                )
                            }

                            if (showGuide) {
                                Surface(
                                    color = if (eInkMode) Color(0xFFF5F5F5) else MaterialTheme.colorScheme.surfaceVariant,
                                    shape = RoundedCornerShape(8.dp),
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text(
                                        text = "1. 前往 Microsoft Entra 管理中心（Azure Portal → 應用程式註冊 → 新增註冊）。\n" +
                                            "2. 支援的帳戶類型請選「任何組織目錄中的帳戶和個人 Microsoft 帳戶」（Tenant 保持 common）。\n" +
                                            "3. 重新導向 URI 平台選「行動裝置和傳統型應用程式」，填入：\n" +
                                            "   com.inkflow.reader://oauth/onedrive\n" +
                                            "4. 在「API 權限」確認已加入 Microsoft Graph 委派權限：Files.ReadWrite 與 offline_access。\n" +
                                            "5. 複製「應用程式 (用戶端) 識別碼 (Client ID)」貼到下方後點登入即可（免 Client Secret）。",
                                        style = MaterialTheme.typography.bodySmall,
                                        modifier = Modifier.padding(10.dp)
                                    )
                                }
                            }

                            Text(
                                text = if (config.oneDrive.isAuthorized) "授權狀態：已連線 Microsoft OneDrive" else "授權狀態：尚未授權",
                                style = MaterialTheme.typography.bodySmall,
                                fontWeight = FontWeight.Medium,
                                color = if (config.oneDrive.isAuthorized) {
                                    if (eInkMode) Color.Black else MaterialTheme.colorScheme.primary
                                } else textColor.copy(alpha = 0.65f)
                            )

                            OutlinedTextField(
                                value = config.oneDrive.clientId,
                                onValueChange = { updateConfig(config.copy(oneDrive = config.oneDrive.copy(clientId = it))) },
                                label = { Text("Azure 應用程式 (用戶端) 識別碼 Client ID") },
                                placeholder = { Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.oneDrive.tenantId,
                                onValueChange = { updateConfig(config.copy(oneDrive = config.oneDrive.copy(tenantId = it))) },
                                label = { Text("Tenant（預設 common，僅個人帳號可填 consumers）") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.oneDrive.redirectUri,
                                onValueChange = { updateConfig(config.copy(oneDrive = config.oneDrive.copy(redirectUri = it))) },
                                label = { Text("Redirect URI") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )
                            OutlinedTextField(
                                value = config.oneDrive.remoteFolder,
                                onValueChange = { updateConfig(config.copy(oneDrive = config.oneDrive.copy(remoteFolder = it))) },
                                label = { Text("OneDrive 同步資料夾名稱") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth()
                            )

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Button(
                                    enabled = !isBusy && config.oneDrive.clientId.isNotBlank(),
                                    onClick = {
                                        scope.launch {
                                            isBusy = true
                                            statusIsError = false
                                            statusMessage = "正在開啟瀏覽器進行 Microsoft 授權，授權完會自動跳回 Readify…"
                                            val session = OAuthPkceHelper.createOneDriveSession(config.oneDrive)
                                            runCatching {
                                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(session.authUrl)))
                                            }.onFailure { err ->
                                                isBusy = false
                                                statusIsError = true
                                                statusMessage = "無法開啟瀏覽器：${err.message}"
                                                return@launch
                                            }
                                            val res = OAuthPkceHelper.awaitAndExchangeToken(session)
                                            res.onSuccess { token ->
                                                updateConfig(
                                                    config.copy(
                                                        oneDrive = config.oneDrive.copy(
                                                            accessToken = token.accessToken,
                                                            refreshToken = token.refreshToken,
                                                            tokenExpiresAtMs = token.expiresAtMs
                                                        )
                                                    )
                                                )
                                                statusIsError = false
                                                statusMessage = "Microsoft OneDrive 授權成功！現在可以點「測試連線」或「立即雙向同步」。"
                                            }.onFailure { err ->
                                                statusIsError = true
                                                statusMessage = "OneDrive 授權失敗：${err.message}"
                                            }
                                            isBusy = false
                                        }
                                    },
                                    modifier = Modifier.weight(1f)
                                ) {
                                    Text(if (config.oneDrive.isAuthorized) "重新授權登入" else "瀏覽器授權登入 Microsoft")
                                }

                                if (config.oneDrive.isAuthorized) {
                                    OutlinedButton(
                                        enabled = !isBusy,
                                        onClick = {
                                            updateConfig(
                                                config.copy(
                                                    oneDrive = config.oneDrive.copy(
                                                        accessToken = "",
                                                        refreshToken = "",
                                                        tokenExpiresAtMs = 0L
                                                    )
                                                )
                                            )
                                            statusIsError = false
                                            statusMessage = "已清除 OneDrive 登入憑證"
                                        }
                                    ) { Text("登出") }
                                }
                            }
                        }
                    }
                }
            }

            // ---------------- Sync Scope Options & Action Buttons ----------------
            OutlinedCard(
                colors = cardColors,
                border = cardBorder,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("同步項目與執行", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("開啟與離開書本時自動同步", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                text = "已設定雲端服務時，開書前自動抓取最新進度、按返回離開時自動同步至雲端",
                                style = MaterialTheme.typography.labelSmall,
                                color = textColor.copy(alpha = 0.65f)
                            )
                        }
                        Switch(
                            checked = config.autoSyncOnBookOpenClose,
                            onCheckedChange = { updateConfig(config.copy(autoSyncOnBookOpenClose = it)) }
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("同步電子書／漫畫書檔本體", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                text = "關閉時僅同步書架分組、閱讀進度與書籤（最省流量）",
                                style = MaterialTheme.typography.labelSmall,
                                color = textColor.copy(alpha = 0.65f)
                            )
                        }
                        Switch(
                            checked = config.syncBookFiles,
                            onCheckedChange = { updateConfig(config.copy(syncBookFiles = it)) }
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("同步排版與閱讀設定", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                text = "同步字級、行距、邊界、主題與點擊區域（保留各裝置本機字體路徑）",
                                style = MaterialTheme.typography.labelSmall,
                                color = textColor.copy(alpha = 0.65f)
                            )
                        }
                        Switch(
                            checked = config.syncReaderSettings,
                            onCheckedChange = { updateConfig(config.copy(syncReaderSettings = it)) }
                        )
                    }

                    if (config.lastSyncTimeMs > 0L) {
                        val timeStr = remember(config.lastSyncTimeMs) {
                            SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.getDefault()).format(Date(config.lastSyncTimeMs))
                        }
                        HorizontalDivider()
                        Text(
                            text = "上次同步：$timeStr\n${config.lastSyncSummary}",
                            style = MaterialTheme.typography.bodySmall,
                            color = textColor.copy(alpha = 0.75f)
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedButton(
                            enabled = !isBusy,
                            onClick = {
                                scope.launch {
                                    isBusy = true
                                    statusIsError = false
                                    statusMessage = "正在測試 ${config.activeProvider.label} 連線…"
                                    val res = syncManager.testConnection(config) { updated -> config = updated }
                                    res.onSuccess { msg ->
                                        statusIsError = false
                                        statusMessage = msg
                                    }.onFailure { err ->
                                        statusIsError = true
                                        statusMessage = "連線測試失敗：${err.message}"
                                    }
                                    isBusy = false
                                }
                            },
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Default.Wifi, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("測試連線")
                        }

                        Button(
                            enabled = !isBusy,
                            onClick = {
                                scope.launch {
                                    isBusy = true
                                    statusIsError = false
                                    statusMessage = "準備開始雙向同步…"
                                    val res = syncManager.syncNow(
                                        config = config,
                                        onConfigUpdated = { updated -> config = updated },
                                        onProgress = { msg ->
                                            withContext(Dispatchers.Main) {
                                                statusMessage = msg
                                            }
                                        }
                                    )
                                    res.onSuccess { report ->
                                        statusIsError = report.errors.isNotEmpty()
                                        statusMessage = if (report.errors.isEmpty()) {
                                            "同步完成！${report.toDisplaySummary()}"
                                        } else {
                                            "同步已完成（部分異常）：${report.toDisplaySummary()}\n${report.errors.take(3).joinToString("\n")}"
                                        }
                                        onSyncCompleted()
                                    }.onFailure { err ->
                                        statusIsError = true
                                        statusMessage = "同步失敗：${err.message}"
                                    }
                                    isBusy = false
                                }
                            },
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Default.Sync, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("立即雙向同步")
                        }
                    }

                    OutlinedButton(
                        enabled = !isBusy,
                        onClick = {
                            scope.launch {
                                isBusy = true
                                statusIsError = false
                                statusMessage = "正在讀取雲端同步資料夾清單…"
                                val res = syncManager.listCloudFiles(config) { updated -> config = updated }
                                res.onSuccess { list ->
                                    remoteFilesPreview = list
                                    statusMessage = "雲端共偵測到 ${list.size} 個項目"
                                }.onFailure { err ->
                                    statusIsError = true
                                    statusMessage = "讀取雲端清單失敗：${err.message}"
                                }
                                isBusy = false
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.CloudQueue, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("檢視雲端檔案清單")
                    }
                }
            }

            // ---------------- Cloud Files Preview List ----------------
            remoteFilesPreview?.let { files ->
                OutlinedCard(
                    colors = cardColors,
                    border = cardBorder,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text("雲端檔案（共 ${files.size} 項）", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                        if (files.isEmpty()) {
                            Text("目前資料夾是空的", style = MaterialTheme.typography.bodySmall)
                        } else {
                            files.take(40).forEach { entry ->
                                val sizeStr = if (entry.isDirectory) "資料夾" else formatBytes(entry.sizeBytes)
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Text(
                                        text = entry.name,
                                        style = MaterialTheme.typography.bodySmall,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Text(
                                        text = sizeStr,
                                        style = MaterialTheme.typography.labelSmall,
                                        color = textColor.copy(alpha = 0.65f)
                                    )
                                }
                            }
                            if (files.size > 40) {
                                Text("…還有 ${files.size - 40} 個檔案", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(20.dp))
        }
    }
}

private fun formatBytes(bytes: Long): String {
    if (bytes <= 0L) return "0 B"
    if (bytes < 1024L) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024.0) return "%.1f KB".format(kb)
    return "%.2f MB".format(kb / 1024.0)
}
