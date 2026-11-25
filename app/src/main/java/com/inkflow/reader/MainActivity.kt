package com.inkflow.reader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.inkflow.reader.data.AppRepository
import com.inkflow.reader.model.BatchImportResult
import com.inkflow.reader.model.BookContentType
import com.inkflow.reader.model.BookFormat
import com.inkflow.reader.model.BookItem
import com.inkflow.reader.sync.OAuthPkceHelper
import com.inkflow.reader.ui.BookshelfScreen
import com.inkflow.reader.ui.CloudSyncScreen
import com.inkflow.reader.ui.ReaderScreen
import com.inkflow.reader.ui.ReaderVolumeController
import com.inkflow.reader.ui.VisualReaderScreen
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {

    private val volumeController = ReaderVolumeController()
    private var isReaderActive = false
    private val fontScanVersion = mutableIntStateOf(0)

    override fun onResume() {
        super.onResume()
        fontScanVersion.intValue += 1
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.let { uri ->
            OAuthPkceHelper.handleRedirectUri(uri)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        intent?.data?.let { uri -> OAuthPkceHelper.handleRedirectUri(uri) }

        runCatching { PDFBoxResourceLoader.init(applicationContext) }

        val repository = AppRepository(applicationContext)

        setContent {
            val scope = rememberCoroutineScope()
            var books by remember { mutableStateOf(repository.loadBooks()) }
            var settings by remember { mutableStateOf(repository.loadSettings()) }
            var activeBook by remember { mutableStateOf<BookItem?>(null) }
            var showCloudSync by remember { mutableStateOf(false) }
            var isImporting by remember { mutableStateOf(false) }
            var importStatus by remember { mutableStateOf<String?>(null) }

            LaunchedEffect(Unit) {
                if (repository.repairMissingMobiCovers()) {
                    books = repository.loadBooks()
                }
            }

            LaunchedEffect(activeBook, showCloudSync) {
                isReaderActive = activeBook != null && !showCloudSync
                setImmersiveMode(isReaderActive)
            }

            fun formatBatchSummary(prefix: String, res: BatchImportResult): String {
                if (res.importedCount == 0 && res.skippedDuplicateCount == 0 && res.unsupportedCount == 0 && res.failedCount == 0) {
                    return "${prefix}內找不到支援的電子書或漫畫檔案"
                }
                if (res.importedCount == 1 && res.skippedDuplicateCount == 0 && res.unsupportedCount == 0 && res.failedCount == 0 && res.lastImportedTitle != null) {
                    return "已成功匯入「${res.lastImportedTitle}」"
                }
                val parts = mutableListOf<String>()
                parts.add("成功 ${res.importedCount} 本")
                if (res.skippedDuplicateCount > 0) parts.add("略過重複 ${res.skippedDuplicateCount} 本")
                if (res.unsupportedCount > 0) parts.add("不支援格式 ${res.unsupportedCount} 個")
                if (res.failedCount > 0) parts.add("失敗 ${res.failedCount} 個")
                return "${prefix}完成：${parts.joinToString("、")}"
            }

            val importFilesLauncher = rememberLauncherForActivityResult(
                contract = ActivityResultContracts.OpenMultipleDocuments()
            ) { uris ->
                if (uris.isNotEmpty() && !isImporting) {
                    scope.launch {
                        isImporting = true
                        importStatus = "正在準備匯入 ${uris.size} 個檔案…"
                        val res = repository.importBooksFromUris(uris) { cur, total, name ->
                            withContext(Dispatchers.Main) {
                                importStatus = "正在匯入 ($cur / $total)：$name"
                                if (cur % 3 == 0) books = repository.loadBooks()
                            }
                        }
                        books = repository.loadBooks()
                        importStatus = formatBatchSummary("檔案匯入", res)
                        isImporting = false
                    }
                }
            }

            val importFolderLauncher = rememberLauncherForActivityResult(
                contract = ActivityResultContracts.OpenDocumentTree()
            ) { treeUri ->
                if (treeUri != null && !isImporting) {
                    scope.launch {
                        isImporting = true
                        importStatus = "正在掃描資料夾內的電子書與漫畫…"
                        val res = repository.importBooksFromFolderUri(treeUri) { cur, total, name ->
                            withContext(Dispatchers.Main) {
                                importStatus = "正在匯入資料夾 ($cur / $total)：$name"
                                if (cur % 3 == 0) books = repository.loadBooks()
                            }
                        }
                        books = repository.loadBooks()
                        importStatus = formatBatchSummary("資料夾匯入", res)
                        isImporting = false
                    }
                }
            }

            val pickFontsFolderLauncher = rememberLauncherForActivityResult(
                contract = ActivityResultContracts.OpenDocumentTree()
            ) { treeUri ->
                if (treeUri != null) {
                    runCatching {
                        contentResolver.takePersistableUriPermission(
                            treeUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                    }
                    val updated = settings.copy(customFontFolderUri = treeUri.toString())
                    settings = updated
                    repository.saveSettings(updated)
                    fontScanVersion.intValue += 1
                }
            }

            MaterialTheme(colorScheme = lightColorScheme()) {
                val current = activeBook
                when {
                    showCloudSync -> {
                        CloudSyncScreen(
                            repository = repository,
                            eInkMode = settings.eInkMode,
                            onSyncCompleted = {
                                books = repository.loadBooks()
                                settings = repository.loadSettings()
                            },
                            onBack = {
                                books = repository.loadBooks()
                                settings = repository.loadSettings()
                                showCloudSync = false
                            }
                        )
                    }

                    current == null -> {
                        BookshelfScreen(
                            books = books,
                            eInkMode = settings.eInkMode,
                            sortField = settings.shelfSortField,
                            sortAscending = settings.shelfSortAscending,
                            coverSize = settings.shelfCoverSize,
                            isImporting = isImporting,
                            importStatusMessage = importStatus,
                            onDismissStatus = { importStatus = null },
                            onImportFilesClick = { importFilesLauncher.launch(arrayOf("*/*")) },
                            onImportFolderClick = { importFolderLauncher.launch(null) },
                            onOpenBook = { book ->
                                scope.launch {
                                    val resolved = repository.refreshContentTypeIfNeeded(book)
                                    if (resolved != book) books = repository.loadBooks()
                                    activeBook = resolved
                                }
                            },
                            onDeleteBook = { book ->
                                repository.deleteBook(book.id)
                                books = repository.loadBooks()
                            },
                            onBatchDeleteBooks = { ids ->
                                repository.deleteBooks(ids)
                                books = repository.loadBooks()
                                importStatus = "已刪除 ${ids.size} 本書"
                            },
                            onUpdateBookTags = { book, tags ->
                                repository.updateBookTags(book.id, tags)
                                books = repository.loadBooks()
                            },
                            onBatchAddTags = { ids, tags ->
                                repository.addTagsToBooks(ids, tags)
                                books = repository.loadBooks()
                                val tagLabel = tags.joinToString(" ") { "#$it" }
                                importStatus = "已為 ${ids.size} 本書加入標籤：$tagLabel"
                            },
                            onBatchRemoveTags = { ids, tags ->
                                repository.removeTagsFromBooks(ids, tags)
                                books = repository.loadBooks()
                                val tagLabel = tags.joinToString(" ") { "#$it" }
                                importStatus = "已從 ${ids.size} 本書移除標籤：$tagLabel"
                            },
                            onSetBookReadStatus = { book, isRead ->
                                repository.setBookReadStatus(book.id, isRead)
                                books = repository.loadBooks()
                            },
                            onBatchSetReadStatus = { ids, isRead ->
                                repository.setBooksReadStatus(ids, isRead)
                                books = repository.loadBooks()
                                importStatus = if (isRead) {
                                    "已將 ${ids.size} 本書標記為已讀"
                                } else {
                                    "已將 ${ids.size} 本書標記為未讀"
                                }
                            },
                            onUpdateBookContentType = { book, newType ->
                                repository.updateBookContentType(book.id, newType)
                                books = repository.loadBooks()
                            },
                            onSortChange = { field, ascending ->
                                val updated = settings.copy(
                                    shelfSortField = field,
                                    shelfSortAscending = ascending
                                )
                                settings = updated
                                repository.saveSettings(updated)
                            },
                            onCoverSizeChange = { newSize ->
                                if (settings.shelfCoverSize != newSize) {
                                    val updated = settings.copy(shelfCoverSize = newSize)
                                    settings = updated
                                    repository.saveSettings(updated)
                                }
                            },
                            onToggleEInkMode = {
                                val updated = settings.copy(eInkMode = !settings.eInkMode)
                                settings = updated
                                repository.saveSettings(updated)
                            },
                            onOpenCloudSync = {
                                showCloudSync = true
                            }
                        )
                    }

                    else -> {
                        val useVisualReader = when (current.contentType) {
                            BookContentType.COMIC -> true
                            BookContentType.PDF -> !settings.pdfReflowMode
                            BookContentType.TEXT -> false
                        }

                        if (useVisualReader) {
                            VisualReaderScreen(
                                book = current,
                                repository = repository,
                                settings = settings,
                                volumeController = volumeController,
                                onSettingsChange = { updated ->
                                    settings = updated
                                    repository.saveSettings(updated)
                                },
                                onSwitchToPdfReflow = if (current.format == BookFormat.PDF) {
                                    {
                                        val updated = settings.copy(pdfReflowMode = true)
                                        settings = updated
                                        repository.saveSettings(updated)
                                    }
                                } else null,
                                onExitReader = {
                                    books = repository.loadBooks()
                                    activeBook = null
                                }
                            )
                        } else {
                            ReaderScreen(
                                book = current,
                                repository = repository,
                                settings = settings,
                                fontScanVersion = fontScanVersion.intValue,
                                volumeController = volumeController,
                                onSettingsChange = { updated ->
                                    settings = updated
                                    repository.saveSettings(updated)
                                },
                                onRequestAllFilesAccess = { openAllFilesAccessSettings() },
                                onPickFontsFolder = { pickFontsFolderLauncher.launch(null) },
                                onSwitchBackToPdfOriginal = if (current.format == BookFormat.PDF) {
                                    {
                                        val updated = settings.copy(pdfReflowMode = false)
                                        settings = updated
                                        repository.saveSettings(updated)
                                    }
                                } else null,
                                onExitReader = {
                                    books = repository.loadBooks()
                                    activeBook = null
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private fun openAllFilesAccessSettings() {
        runCatching {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
        }.onFailure {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    private fun setImmersiveMode(enabled: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (enabled) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isReaderActive) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeController.onVolumeNext?.let {
                        it.invoke()
                        return true
                    }
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeController.onVolumePrev?.let {
                        it.invoke()
                        return true
                    }
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
