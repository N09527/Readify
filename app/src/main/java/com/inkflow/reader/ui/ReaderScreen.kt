package com.inkflow.reader.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.inkflow.reader.data.AppRepository
import com.inkflow.reader.data.FontManager
import com.inkflow.reader.engine.PageContent
import com.inkflow.reader.engine.ReaderCanvasView
import com.inkflow.reader.engine.ReaderLayoutMetrics
import com.inkflow.reader.engine.SpreadSnapshot
import com.inkflow.reader.engine.TextPaginator
import com.inkflow.reader.model.*
import com.inkflow.reader.parser.BookParser
import com.inkflow.reader.parser.ChineseConverter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

class ReaderVolumeController {
    var onVolumeNext: (() -> Unit)? = null
    var onVolumePrev: (() -> Unit)? = null
}

private data class PaginatedChapterData(
    val title: String,
    val pages: List<PageContent>
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    book: BookItem,
    repository: AppRepository,
    settings: ReaderSettings,
    fontScanVersion: Int,
    volumeController: ReaderVolumeController,
    onSettingsChange: (ReaderSettings) -> Unit,
    onRequestAllFilesAccess: () -> Unit,
    onPickFontsFolder: () -> Unit,
    onSwitchBackToPdfOriginal: (() -> Unit)? = null,
    onExitReader: () -> Unit
) {
    val scope = rememberCoroutineScope()

    var isLoading by remember { mutableStateOf(true) }
    var rawChapters by remember { mutableStateOf<List<Chapter>>(emptyList()) }
    var currentChapterIndex by remember { mutableIntStateOf(book.lastChapterIndex) }
    var targetCharOffset by remember { mutableIntStateOf(book.lastCharOffset) }

    var viewportWidthPx by remember { mutableIntStateOf(0) }
    var viewportHeightPx by remember { mutableIntStateOf(0) }
    var viewportDensity by remember { mutableFloatStateOf(1f) }

    val layoutMetrics = remember(
        viewportWidthPx,
        viewportHeightPx,
        viewportDensity,
        settings.dualPageMode,
        settings.marginHorizontalDp,
        settings.marginVerticalDp
    ) {
        if (viewportWidthPx > 0 && viewportHeightPx > 0) {
            ReaderLayoutMetrics.compute(viewportWidthPx, viewportHeightPx, viewportDensity, settings)
        } else null
    }

    val isDualPage = layoutMetrics?.isDualPage ?: false
    val contentWidthPx = layoutMetrics?.contentWidthPx ?: 0f
    val contentHeightPx = layoutMetrics?.contentHeightPx ?: 0f

    var chapterCache by remember { mutableStateOf<Map<Int, PaginatedChapterData>>(emptyMap()) }
    var currentPageIndex by remember { mutableIntStateOf(0) }

    var showMenu by remember { mutableStateOf(false) }
    var showSettingsSheet by remember { mutableStateOf(false) }
    var showTocAndBookmarks by remember { mutableStateOf(false) }
    var showSearchDialog by remember { mutableStateOf(false) }
    var showTapZoneDialog by remember { mutableStateOf(false) }
    var bookmarks by remember { mutableStateOf(repository.loadBookmarksForBook(book.id)) }
    var toastMessage by remember { mutableStateOf<String?>(null) }

    var availableFonts by remember { mutableStateOf<List<LocalFontItem>>(emptyList()) }
    var isScanningFonts by remember { mutableStateOf(false) }
    var hasAllFilesPermission by remember { mutableStateOf(FontManager.hasAllFilesAccess()) }

    var canvasViewRef by remember { mutableStateOf<ReaderCanvasView?>(null) }

    LaunchedEffect(showSettingsSheet, settings.customFontFolderUri, fontScanVersion) {
        hasAllFilesPermission = FontManager.hasAllFilesAccess()
        if (showSettingsSheet || availableFonts.isEmpty()) {
            isScanningFonts = true
            availableFonts = repository.scanLocalFonts(settings.customFontFolderUri)
            isScanningFonts = false
        }
    }

    LaunchedEffect(book.id) {
        isLoading = true
        val parsed = withContext(Dispatchers.IO) {
            BookParser.parseFullBook(File(book.localPath), book.format, book.title)
        }
        rawChapters = parsed.chapters
        currentChapterIndex = book.lastChapterIndex.coerceIn(0, (parsed.chapters.size - 1).coerceAtLeast(0))
        targetCharOffset = book.lastCharOffset
        isLoading = false
    }

    suspend fun paginateChapterIndex(index: Int): PaginatedChapterData? {
        val raw = rawChapters.getOrNull(index) ?: return null
        val view = canvasViewRef ?: return null
        if (contentWidthPx <= 0f || contentHeightPx <= 0f) return null
        val paint = view.getTextPaintForPagination(settings)
        return withContext(Dispatchers.Default) {
            val convTitle = ChineseConverter.convert(raw.title, settings.chineseConvertMode)
            val convContent = ChineseConverter.convert(raw.content, settings.chineseConvertMode)
            val pages = TextPaginator.paginate(
                chapterTitle = convTitle,
                chapterContent = convContent,
                writingMode = settings.writingMode,
                contentWidthPx = contentWidthPx,
                contentHeightPx = contentHeightPx,
                textPaint = paint,
                lineSpacingMultiplier = settings.lineSpacingMultiplier,
                letterSpacingEm = settings.letterSpacingEm,
                paragraphSpacingEm = settings.paragraphSpacingEm,
                paragraphIndentChars = settings.paragraphIndentChars
            )
            PaginatedChapterData(title = convTitle, pages = pages)
        }
    }

    LaunchedEffect(
        rawChapters,
        contentWidthPx,
        contentHeightPx,
        isDualPage,
        settings.writingMode,
        settings.fontSizeSp,
        settings.fontBold,
        settings.letterSpacingEm,
        settings.lineSpacingMultiplier,
        settings.paragraphSpacingEm,
        settings.paragraphIndentChars,
        settings.customFontPath,
        settings.chineseConvertMode
    ) {
        if (rawChapters.isEmpty() || contentWidthPx <= 0f || contentHeightPx <= 0f) return@LaunchedEffect
        val curData = paginateChapterIndex(currentChapterIndex) ?: return@LaunchedEffect
        val step = if (isDualPage) 2 else 1
        val matched = curData.pages.indexOfFirst { targetCharOffset in it.startOffset..it.endOffset }
            .takeIf { it >= 0 }
            ?: if (targetCharOffset == Int.MAX_VALUE) (curData.pages.size - 1).coerceAtLeast(0) else 0
        currentPageIndex = if (step == 2) (matched / 2) * 2 else matched

        val nextData = if (currentChapterIndex + 1 < rawChapters.size) paginateChapterIndex(currentChapterIndex + 1) else null
        val prevData = if (currentChapterIndex - 1 >= 0) paginateChapterIndex(currentChapterIndex - 1) else null

        val newMap = mutableMapOf(currentChapterIndex to curData)
        if (nextData != null) newMap[currentChapterIndex + 1] = nextData
        if (prevData != null) newMap[currentChapterIndex - 1] = prevData
        chapterCache = newMap
    }

    LaunchedEffect(currentChapterIndex) {
        if (rawChapters.isEmpty() || contentWidthPx <= 0f || contentHeightPx <= 0f) return@LaunchedEffect
        val updated = chapterCache.toMutableMap()
        if (!updated.containsKey(currentChapterIndex)) {
            paginateChapterIndex(currentChapterIndex)?.let { updated[currentChapterIndex] = it }
        }
        val curPages = updated[currentChapterIndex]?.pages.orEmpty()
        if (curPages.isNotEmpty()) {
            val step = if (isDualPage) 2 else 1
            val matched = if (targetCharOffset == Int.MAX_VALUE) {
                (curPages.size - 1).coerceAtLeast(0)
            } else {
                curPages.indexOfFirst { targetCharOffset in it.startOffset..it.endOffset }.takeIf { it >= 0 } ?: 0
            }
            currentPageIndex = if (step == 2) (matched / 2) * 2 else matched
        }
        if (currentChapterIndex + 1 < rawChapters.size && !updated.containsKey(currentChapterIndex + 1)) {
            paginateChapterIndex(currentChapterIndex + 1)?.let { updated[currentChapterIndex + 1] = it }
        }
        if (currentChapterIndex - 1 >= 0 && !updated.containsKey(currentChapterIndex - 1)) {
            paginateChapterIndex(currentChapterIndex - 1)?.let { updated[currentChapterIndex - 1] = it }
        }
        chapterCache = updated.filterKeys { kotlin.math.abs(it - currentChapterIndex) <= 2 }
    }

    val currentChapterData = chapterCache[currentChapterIndex]
    val pages = currentChapterData?.pages.orEmpty()

    val chapterPrefixChars = remember(rawChapters) {
        val prefix = LongArray(rawChapters.size + 1)
        for (i in rawChapters.indices) {
            prefix[i + 1] = prefix[i] + rawChapters[i].content.length.coerceAtLeast(1)
        }
        prefix
    }

    fun computeCurrentProgress(): Pair<Int, Float>? {
        val page = pages.getOrNull(currentPageIndex) ?: return null
        val totalBookChars = chapterPrefixChars.lastOrNull()?.coerceAtLeast(1L) ?: 1L
        val step = if (isDualPage) 2 else 1
        val isAtFinalSpread = rawChapters.isNotEmpty() &&
            currentChapterIndex >= rawChapters.lastIndex &&
            (currentPageIndex + step) >= pages.size

        val progressFraction = if (isAtFinalSpread) {
            1f
        } else {
            val prevChars = chapterPrefixChars.getOrElse(currentChapterIndex) { 0L }
            val curChChars = rawChapters.getOrNull(currentChapterIndex)?.content?.length?.coerceAtLeast(1) ?: 1
            val chPageRatio = (currentPageIndex + step).coerceAtMost(pages.size).toFloat() /
                pages.size.coerceAtLeast(1).toFloat()
            ((prevChars + curChChars * chPageRatio) / totalBookChars.toFloat()).coerceIn(0f, 1f)
        }
        return page.startOffset to progressFraction
    }

    var hasExited by remember(book.id) { mutableStateOf(false) }

    fun exitReaderSafely() {
        if (hasExited) return
        hasExited = true
        if (!isLoading) {
            computeCurrentProgress()?.let { (charOffset, progressFraction) ->
                repository.updateBookProgress(book.id, currentChapterIndex, charOffset, progressFraction)
            }
        }
        onExitReader()
    }

    // System Back button & Android gesture swipe-back inside reader flush progress & return to Bookshelf
    BackHandler {
        when {
            showTapZoneDialog -> showTapZoneDialog = false
            showSearchDialog -> showSearchDialog = false
            showSettingsSheet -> showSettingsSheet = false
            showTocAndBookmarks -> showTocAndBookmarks = false
            else -> exitReaderSafely()
        }
    }

    LaunchedEffect(currentChapterIndex, currentPageIndex, pages, isDualPage, chapterPrefixChars) {
        val (charOffset, progressFraction) = computeCurrentProgress() ?: return@LaunchedEffect
        targetCharOffset = charOffset

        withContext(Dispatchers.IO) {
            repository.updateBookProgress(book.id, currentChapterIndex, charOffset, progressFraction)
        }
    }

    val currentSpread = remember(currentChapterIndex, currentChapterData, currentPageIndex, isDualPage) {
        currentChapterData?.let { data ->
            SpreadSnapshot(
                chapterIndex = currentChapterIndex,
                chapterTitle = data.title,
                firstPage = data.pages.getOrNull(currentPageIndex),
                secondPage = if (isDualPage) data.pages.getOrNull(currentPageIndex + 1) else null,
                totalPagesInChapter = data.pages.size.coerceAtLeast(1)
            )
        }
    }

    val nextSpread = remember(currentChapterIndex, chapterCache, currentPageIndex, isDualPage, rawChapters) {
        val step = if (isDualPage) 2 else 1
        val cur = chapterCache[currentChapterIndex]
        if (cur != null && currentPageIndex + step < cur.pages.size) {
            SpreadSnapshot(
                chapterIndex = currentChapterIndex,
                chapterTitle = cur.title,
                firstPage = cur.pages.getOrNull(currentPageIndex + step),
                secondPage = if (isDualPage) cur.pages.getOrNull(currentPageIndex + step + 1) else null,
                totalPagesInChapter = cur.pages.size.coerceAtLeast(1)
            )
        } else if (currentChapterIndex + 1 < rawChapters.size) {
            val nxt = chapterCache[currentChapterIndex + 1]
            if (nxt != null) {
                SpreadSnapshot(
                    chapterIndex = currentChapterIndex + 1,
                    chapterTitle = nxt.title,
                    firstPage = nxt.pages.getOrNull(0),
                    secondPage = if (isDualPage) nxt.pages.getOrNull(1) else null,
                    totalPagesInChapter = nxt.pages.size.coerceAtLeast(1)
                )
            } else {
                SpreadSnapshot(
                    chapterIndex = currentChapterIndex + 1,
                    chapterTitle = rawChapters[currentChapterIndex + 1].title,
                    firstPage = null,
                    secondPage = null,
                    totalPagesInChapter = 1
                )
            }
        } else null
    }

    val prevSpread = remember(currentChapterIndex, chapterCache, currentPageIndex, isDualPage, rawChapters) {
        val step = if (isDualPage) 2 else 1
        val cur = chapterCache[currentChapterIndex]
        if (cur != null && currentPageIndex - step >= 0) {
            SpreadSnapshot(
                chapterIndex = currentChapterIndex,
                chapterTitle = cur.title,
                firstPage = cur.pages.getOrNull(currentPageIndex - step),
                secondPage = if (isDualPage) cur.pages.getOrNull(currentPageIndex - step + 1) else null,
                totalPagesInChapter = cur.pages.size.coerceAtLeast(1)
            )
        } else if (currentChapterIndex - 1 >= 0) {
            val prv = chapterCache[currentChapterIndex - 1]
            if (prv != null && prv.pages.isNotEmpty()) {
                val lastStart = if (isDualPage) ((prv.pages.size - 1) / 2) * 2 else prv.pages.size - 1
                SpreadSnapshot(
                    chapterIndex = currentChapterIndex - 1,
                    chapterTitle = prv.title,
                    firstPage = prv.pages.getOrNull(lastStart),
                    secondPage = if (isDualPage) prv.pages.getOrNull(lastStart + 1) else null,
                    totalPagesInChapter = prv.pages.size.coerceAtLeast(1)
                )
            } else {
                SpreadSnapshot(
                    chapterIndex = currentChapterIndex - 1,
                    chapterTitle = rawChapters[currentChapterIndex - 1].title,
                    firstPage = null,
                    secondPage = null,
                    totalPagesInChapter = 1
                )
            }
        } else null
    }

    val onNextSpreadAction by rememberUpdatedState {
        val step = if (isDualPage) 2 else 1
        if (pages.isEmpty()) {
            false
        } else if (currentPageIndex + step < pages.size) {
            currentPageIndex += step
            true
        } else if (currentChapterIndex + 1 < rawChapters.size) {
            currentChapterIndex += 1
            targetCharOffset = 0
            currentPageIndex = 0
            true
        } else {
            toastMessage = "已經是最後一頁了"
            false
        }
    }

    val onPrevSpreadAction by rememberUpdatedState {
        val step = if (isDualPage) 2 else 1
        if (pages.isEmpty()) {
            false
        } else if (currentPageIndex - step >= 0) {
            currentPageIndex -= step
            true
        } else if (currentChapterIndex - 1 >= 0) {
            val prevIdx = currentChapterIndex - 1
            val prevPages = chapterCache[prevIdx]?.pages
            currentChapterIndex = prevIdx
            if (prevPages != null && prevPages.isNotEmpty()) {
                val lastStart = if (isDualPage) ((prevPages.size - 1) / 2) * 2 else prevPages.size - 1
                currentPageIndex = lastStart
                targetCharOffset = prevPages[lastStart].startOffset
            } else {
                targetCharOffset = Int.MAX_VALUE
            }
            true
        } else {
            toastMessage = "已經是第一頁了"
            false
        }
    }

    val onBoundaryAction by rememberUpdatedState { isEnd: Boolean ->
        toastMessage = if (isEnd) {
            "已經是最後一頁了"
        } else if (settings.writingMode == WritingMode.VERTICAL && settings.verticalNaturalSwipe) {
            "已經是第一頁（直排模式向右滑為下一頁，可在設定切換方向）"
        } else {
            "已經是第一頁了"
        }
    }

    val onToggleMenuAction by rememberUpdatedState { showMenu = !showMenu }

    DisposableEffect(settings.volumeKeyPageTurn, canvasViewRef) {
        if (settings.volumeKeyPageTurn) {
            volumeController.onVolumeNext = { canvasViewRef?.triggerTurnNextAnimated() }
            volumeController.onVolumePrev = { canvasViewRef?.triggerTurnPrevAnimated() }
        } else {
            volumeController.onVolumeNext = null
            volumeController.onVolumePrev = null
        }
        onDispose {
            volumeController.onVolumeNext = null
            volumeController.onVolumePrev = null
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                ReaderCanvasView(ctx).also { view ->
                    canvasViewRef = view
                    view.listener = object : ReaderCanvasView.Listener {
                        override fun onRequestNextSpread(): Boolean = onNextSpreadAction()
                        override fun onRequestPrevSpread(): Boolean = onPrevSpreadAction()
                        override fun onToggleMenu() = onToggleMenuAction()
                        override fun onBoundaryReached(isEnd: Boolean) = onBoundaryAction(isEnd)
                        override fun onViewportReady(w: Int, h: Int, density: Float) {
                            viewportWidthPx = w
                            viewportHeightPx = h
                            viewportDensity = density
                        }
                    }
                }
            },
            update = { view ->
                view.updateState(
                    newSettings = settings,
                    bookTitle = ChineseConverter.convert(book.title, settings.chineseConvertMode),
                    totalChapters = rawChapters.size.coerceAtLeast(1),
                    currentSpread = currentSpread,
                    nextSpread = nextSpread,
                    prevSpread = prevSpread
                )
            }
        )

        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(settings.effectiveTheme.bgColor)),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = if (book.format == BookFormat.PDF) "正在擷取 PDF 文字重排…" else "正在解析電子書…",
                        color = Color(settings.effectiveTheme.textColor)
                    )
                }
            }
        }

        toastMessage?.let { msg ->
            LaunchedEffect(msg) {
                delay(2000)
                toastMessage = null
            }
            Surface(
                color = Color.Black.copy(alpha = 0.82f),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 20.dp, vertical = 96.dp)
            ) {
                Text(
                    text = msg,
                    color = Color.White,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                )
            }
        }

        if (showMenu) {
            val barBg = if (settings.eInkMode) Color.White else MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)
            val barFg = if (settings.eInkMode) Color.Black else MaterialTheme.colorScheme.onSurface

            Surface(
                color = barBg,
                tonalElevation = if (settings.eInkMode) 0.dp else 4.dp,
                shadowElevation = if (settings.eInkMode) 0.dp else 4.dp,
                border = if (settings.eInkMode) BorderStroke(1.dp, Color.Black) else null,
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.TopCenter)
            ) {
                Column(Modifier.statusBarsPadding()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = { exitReaderSafely() }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回書架", tint = barFg)
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                text = book.title,
                                style = MaterialTheme.typography.titleSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                color = barFg
                            )
                            Text(
                                text = currentChapterData?.title ?: "",
                                style = MaterialTheme.typography.labelSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                color = barFg.copy(alpha = 0.7f)
                            )
                        }
                        IconButton(onClick = { showSearchDialog = true }) {
                            Icon(Icons.Default.Search, contentDescription = "全書搜尋", tint = barFg)
                        }
                        IconButton(onClick = {
                            val title = currentChapterData?.title
                            val pg = pages.getOrNull(currentPageIndex)
                            if (title != null && pg != null) {
                                val preview = pg.lines.joinToString("") { it.text }.take(45)
                                val bm = BookmarkItem(
                                    id = UUID.randomUUID().toString(),
                                    bookId = book.id,
                                    chapterIndex = currentChapterIndex,
                                    chapterTitle = title,
                                    charOffset = pg.startOffset,
                                    preview = preview
                                )
                                repository.addBookmark(bm)
                                bookmarks = repository.loadBookmarksForBook(book.id)
                                toastMessage = "已加入書籤"
                            }
                        }) {
                            Icon(Icons.Default.BookmarkAdd, contentDescription = "加入書籤", tint = barFg)
                        }
                    }

                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (onSwitchBackToPdfOriginal != null) {
                            item {
                                QuickToggleChip(
                                    label = "切回 PDF 原版面",
                                    active = true,
                                    eInkMode = settings.eInkMode,
                                    onClick = {
                                        showMenu = false
                                        onSwitchBackToPdfOriginal()
                                    }
                                )
                            }
                        }
                        item {
                            QuickToggleChip(
                                label = if (settings.writingMode == WritingMode.VERTICAL) "直排" else "橫排",
                                active = settings.writingMode == WritingMode.VERTICAL,
                                eInkMode = settings.eInkMode,
                                onClick = {
                                    val nextMode = if (settings.writingMode == WritingMode.VERTICAL) {
                                        WritingMode.HORIZONTAL
                                    } else {
                                        WritingMode.VERTICAL
                                    }
                                    onSettingsChange(settings.copy(writingMode = nextMode))
                                }
                            )
                        }
                        item {
                            QuickToggleChip(
                                label = settings.dualPageMode.label,
                                active = settings.dualPageMode == DualPageMode.DUAL || isDualPage,
                                eInkMode = settings.eInkMode,
                                onClick = {
                                    val nextDual = when (settings.dualPageMode) {
                                        DualPageMode.AUTO -> DualPageMode.DUAL
                                        DualPageMode.DUAL -> DualPageMode.SINGLE
                                        DualPageMode.SINGLE -> DualPageMode.AUTO
                                    }
                                    onSettingsChange(settings.copy(dualPageMode = nextDual))
                                }
                            )
                        }
                        item {
                            QuickToggleChip(
                                label = settings.chineseConvertMode.label,
                                active = settings.chineseConvertMode != ChineseConvertMode.ORIGINAL,
                                eInkMode = settings.eInkMode,
                                onClick = {
                                    val nextConv = when (settings.chineseConvertMode) {
                                        ChineseConvertMode.ORIGINAL -> ChineseConvertMode.TO_TRADITIONAL_TW
                                        ChineseConvertMode.TO_TRADITIONAL_TW -> ChineseConvertMode.TO_SIMPLIFIED
                                        ChineseConvertMode.TO_SIMPLIFIED -> ChineseConvertMode.ORIGINAL
                                    }
                                    onSettingsChange(settings.copy(chineseConvertMode = nextConv))
                                }
                            )
                        }
                        item {
                            QuickToggleChip(
                                label = "電子紙",
                                active = settings.eInkMode,
                                eInkMode = settings.eInkMode,
                                onClick = { onSettingsChange(settings.copy(eInkMode = !settings.eInkMode)) }
                            )
                        }
                    }
                }
            }

            Surface(
                color = barBg,
                tonalElevation = if (settings.eInkMode) 0.dp else 4.dp,
                shadowElevation = if (settings.eInkMode) 0.dp else 4.dp,
                border = if (settings.eInkMode) BorderStroke(1.dp, Color.Black) else null,
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.BottomCenter)
            ) {
                Column(
                    modifier = Modifier
                        .navigationBarsPadding()
                        .padding(horizontal = 14.dp, vertical = 10.dp)
                ) {
                    if (pages.size > 1 || rawChapters.size > 1) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            TextButton(
                                enabled = currentChapterIndex > 0,
                                onClick = {
                                    currentChapterIndex = (currentChapterIndex - 1).coerceAtLeast(0)
                                    targetCharOffset = 0
                                    currentPageIndex = 0
                                }
                            ) { Text("上一章") }

                            if (pages.size > 1) {
                                Slider(
                                    value = currentPageIndex.toFloat(),
                                    onValueChange = { v ->
                                        val snapped = if (isDualPage) (v.toInt() / 2) * 2 else v.toInt()
                                        currentPageIndex = snapped.coerceIn(0, (pages.size - 1).coerceAtLeast(0))
                                    },
                                    valueRange = 0f..(pages.size - 1).coerceAtLeast(1).toFloat(),
                                    modifier = Modifier.weight(1f)
                                )
                            } else {
                                Spacer(Modifier.weight(1f))
                            }

                            TextButton(
                                enabled = currentChapterIndex < rawChapters.lastIndex,
                                onClick = {
                                    currentChapterIndex = (currentChapterIndex + 1).coerceAtMost(rawChapters.lastIndex)
                                    targetCharOffset = 0
                                    currentPageIndex = 0
                                }
                            ) { Text("下一章") }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceAround
                    ) {
                        BottomMenuButton(Icons.AutoMirrored.Filled.List, "目錄/書籤", barFg) { showTocAndBookmarks = true }
                        BottomMenuButton(Icons.Default.TextFields, "排版與字體", barFg) { showSettingsSheet = true }
                        BottomMenuButton(Icons.Default.TouchApp, "點擊區域", barFg) { showTapZoneDialog = true }
                        BottomMenuButton(Icons.Default.Close, "隱藏選單", barFg) { showMenu = false }
                    }
                }
            }
        }
    }

    // ---------------- Typography, Direct Numeric Input, Bold & Auto Local Fonts Sheet ----------------
    if (showSettingsSheet) {
        ModalBottomSheet(
            onDismissRequest = { showSettingsSheet = false },
            scrimColor = Color.Black.copy(alpha = 0.16f)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 580.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 6.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("排版、邊界與字體設定", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("字體（自動讀取本機 Fonts 資料夾）", style = MaterialTheme.typography.labelLarge)
                        Text(
                            text = "目前：${settings.customFontName ?: "系統預設明體（Serif）"}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    IconButton(onClick = {
                        scope.launch {
                            hasAllFilesPermission = FontManager.hasAllFilesAccess()
                            isScanningFonts = true
                            availableFonts = repository.scanLocalFonts(settings.customFontFolderUri)
                            isScanningFonts = false
                        }
                    }) {
                        Icon(Icons.Default.Refresh, contentDescription = "重新掃描字體")
                    }
                }

                if (!hasAllFilesPermission) {
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(
                            modifier = Modifier.padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Text(
                                text = "Android 13～16 需要授權「所有檔案存取權」才能自動掃描本機 /Fonts 資料夾（或直接指定字體資料夾）。",
                                style = MaterialTheme.typography.bodySmall
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(
                                    onClick = onRequestAllFilesAccess,
                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                ) { Text("授權讀取本機 Fonts", style = MaterialTheme.typography.labelMedium) }
                                OutlinedButton(
                                    onClick = onPickFontsFolder,
                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                                ) { Text("指定資料夾", style = MaterialTheme.typography.labelMedium) }
                            }
                        }
                    }
                } else {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = if (isScanningFonts) "正在掃描字體…" else "已自動掃描本機 Fonts（共 ${availableFonts.size} 套）",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        TextButton(onClick = onPickFontsFolder) { Text("額外指定資料夾") }
                    }
                }

                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item {
                        FilterChip(
                            selected = settings.customFontPath == null,
                            onClick = { onSettingsChange(settings.copy(customFontPath = null, customFontName = null)) },
                            label = { Text("系統預設明體") }
                        )
                    }
                    items(availableFonts, key = { it.pathOrUri }) { font ->
                        FilterChip(
                            selected = settings.customFontPath == font.pathOrUri,
                            onClick = {
                                onSettingsChange(
                                    settings.copy(customFontPath = font.pathOrUri, customFontName = font.displayName)
                                )
                            },
                            label = { Text(font.displayName, maxLines = 1) }
                        )
                    }
                }

                SettingSwitchRow(
                    title = "字體加粗（粗體渲染，適用所有自訂字體）",
                    checked = settings.fontBold,
                    onCheckedChange = { onSettingsChange(settings.copy(fontBold = it)) }
                )

                HorizontalDivider()

                NumericSliderControl(
                    label = "字體大小",
                    unit = "sp",
                    value = settings.fontSizeSp,
                    valueRange = 12f..48f,
                    decimals = 0,
                    onValueChange = { onSettingsChange(settings.copy(fontSizeSp = it)) }
                )

                NumericSliderControl(
                    label = "字距",
                    unit = "em",
                    value = settings.letterSpacingEm,
                    valueRange = 0f..0.50f,
                    decimals = 2,
                    onValueChange = { onSettingsChange(settings.copy(letterSpacingEm = it)) }
                )

                NumericSliderControl(
                    label = "行距倍率",
                    unit = "x",
                    value = settings.lineSpacingMultiplier,
                    valueRange = 1.10f..3.00f,
                    decimals = 2,
                    onValueChange = { onSettingsChange(settings.copy(lineSpacingMultiplier = it)) }
                )

                NumericSliderControl(
                    label = "段落距",
                    unit = "倍行高",
                    value = settings.paragraphSpacingEm,
                    valueRange = 0f..3.00f,
                    decimals = 2,
                    onValueChange = { onSettingsChange(settings.copy(paragraphSpacingEm = it)) }
                )

                Text("段首縮排（每段開頭空幾字）", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(0, 1, 2, 3, 4).forEach { chars ->
                        FilterChip(
                            selected = settings.paragraphIndentChars == chars,
                            onClick = { onSettingsChange(settings.copy(paragraphIndentChars = chars)) },
                            label = { Text(if (chars == 0) "不縮排" else "${chars}字") }
                        )
                    }
                }

                HorizontalDivider()

                NumericSliderControl(
                    label = "每頁左右邊界",
                    unit = "dp",
                    value = settings.marginHorizontalDp,
                    valueRange = 0f..80f,
                    decimals = 0,
                    onValueChange = { onSettingsChange(settings.copy(marginHorizontalDp = it)) }
                )

                NumericSliderControl(
                    label = "每頁上下邊界",
                    unit = "dp",
                    value = settings.marginVerticalDp,
                    valueRange = 0f..96f,
                    decimals = 0,
                    onValueChange = { onSettingsChange(settings.copy(marginVerticalDp = it)) }
                )

                HorizontalDivider()

                Text("背景主題", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ReaderTheme.entries.forEach { theme ->
                        FilterChip(
                            selected = settings.theme == theme && !settings.eInkMode,
                            onClick = {
                                onSettingsChange(settings.copy(theme = theme, eInkMode = theme == ReaderTheme.EINK))
                            },
                            label = { Text(theme.label) }
                        )
                    }
                }

                Text(
                    text = if (settings.eInkMode) "翻頁動畫模式（電子紙模式已自動停用動畫）" else "翻頁動畫模式",
                    style = MaterialTheme.typography.labelLarge
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PageTurnAnimation.entries.forEach { anim ->
                        FilterChip(
                            selected = settings.pageTurnAnimation == anim,
                            onClick = { onSettingsChange(settings.copy(pageTurnAnimation = anim)) },
                            label = { Text(anim.label) }
                        )
                    }
                }

                if (settings.writingMode == WritingMode.VERTICAL) {
                    SettingSwitchRow(
                        title = "直排依實體書方向滑動（向右滑＝下一頁；關閉則向左滑＝下一頁）",
                        checked = settings.verticalNaturalSwipe,
                        onCheckedChange = { onSettingsChange(settings.copy(verticalNaturalSwipe = it)) }
                    )
                }

                Text("雙頁模式（橫書與直書皆左右呈現）", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DualPageMode.entries.forEach { mode ->
                        FilterChip(
                            selected = settings.dualPageMode == mode,
                            onClick = { onSettingsChange(settings.copy(dualPageMode = mode)) },
                            label = { Text(mode.label) }
                        )
                    }
                }

                SettingSwitchRow(
                    title = "雙頁中間仿真接縫陰影",
                    checked = settings.showSpineShadow,
                    onCheckedChange = { onSettingsChange(settings.copy(showSpineShadow = it)) }
                )

                SettingSwitchRow(
                    title = "電子紙（E-ink）特化模式（純黑白、關閉動畫）",
                    checked = settings.eInkMode,
                    onCheckedChange = { onSettingsChange(settings.copy(eInkMode = it)) }
                )

                SettingSwitchRow(
                    title = "音量鍵翻頁",
                    checked = settings.volumeKeyPageTurn,
                    onCheckedChange = { onSettingsChange(settings.copy(volumeKeyPageTurn = it)) }
                )

                Spacer(Modifier.height(16.dp))
            }
        }
    }

    if (showTocAndBookmarks) {
        var selectedTab by remember { mutableIntStateOf(0) }
        ModalBottomSheet(onDismissRequest = { showTocAndBookmarks = false }) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 520.dp)
                    .navigationBarsPadding()
            ) {
                TabRow(selectedTabIndex = selectedTab) {
                    Tab(selected = selectedTab == 0, onClick = { selectedTab = 0 }, text = { Text("目錄 (${rawChapters.size})") })
                    Tab(selected = selectedTab == 1, onClick = { selectedTab = 1 }, text = { Text("書籤 (${bookmarks.size})") })
                }

                if (selectedTab == 0) {
                    LazyColumn(contentPadding = PaddingValues(12.dp)) {
                        items(rawChapters, key = { it.index }) { ch ->
                            val isCurrent = ch.index == currentChapterIndex
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        currentChapterIndex = ch.index
                                        targetCharOffset = 0
                                        currentPageIndex = 0
                                        showTocAndBookmarks = false
                                        showMenu = false
                                    }
                                    .padding(vertical = 12.dp, horizontal = 8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = ChineseConverter.convert(ch.title, settings.chineseConvertMode),
                                    fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                                    color = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            HorizontalDivider()
                        }
                    }
                } else {
                    if (bookmarks.isEmpty()) {
                        Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                            Text("尚未加入任何書籤")
                        }
                    } else {
                        LazyColumn(contentPadding = PaddingValues(12.dp)) {
                            items(bookmarks, key = { it.id }) { bm ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            currentChapterIndex = bm.chapterIndex
                                            targetCharOffset = bm.charOffset
                                            showTocAndBookmarks = false
                                            showMenu = false
                                        }
                                        .padding(vertical = 10.dp, horizontal = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(Modifier.weight(1f)) {
                                        Text(bm.chapterTitle, style = MaterialTheme.typography.labelLarge)
                                        Text(bm.preview, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    }
                                    IconButton(onClick = {
                                        repository.deleteBookmark(bm.id)
                                        bookmarks = repository.loadBookmarksForBook(book.id)
                                    }) {
                                        Icon(Icons.Default.Delete, contentDescription = "刪除書籤")
                                    }
                                }
                                HorizontalDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    if (showSearchDialog) {
        var query by remember { mutableStateOf("") }
        val results = remember(query, rawChapters) {
            val q = query.trim()
            if (q.isEmpty()) emptyList()
            else {
                val hits = mutableListOf<SearchHit>()
                for (ch in rawChapters) {
                    var idx = ch.content.indexOf(q, ignoreCase = true)
                    while (idx >= 0 && hits.size < 80) {
                        val s = (idx - 15).coerceAtLeast(0)
                        val e = (idx + q.length + 25).coerceAtMost(ch.content.length)
                        hits.add(
                            SearchHit(
                                chapterIndex = ch.index,
                                chapterTitle = ch.title,
                                charOffset = idx,
                                snippet = ch.content.substring(s, e).replace("\n", " ")
                            )
                        )
                        idx = ch.content.indexOf(q, idx + q.length, ignoreCase = true)
                    }
                }
                hits
            }
        }

        AlertDialog(
            onDismissRequest = { showSearchDialog = false },
            title = { Text("全書文字搜尋") },
            text = {
                Column(modifier = Modifier.heightIn(max = 420.dp)) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        label = { Text("輸入關鍵字") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.height(8.dp))
                    LazyColumn {
                        items(results) { hit ->
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        currentChapterIndex = hit.chapterIndex
                                        targetCharOffset = hit.charOffset
                                        showSearchDialog = false
                                        showMenu = false
                                    }
                                    .padding(vertical = 8.dp)
                            ) {
                                Text(hit.chapterTitle, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                                Text("…${hit.snippet}…", style = MaterialTheme.typography.bodySmall, maxLines = 2)
                            }
                            HorizontalDivider()
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSearchDialog = false }) { Text("關閉") }
            }
        )
    }

    if (showTapZoneDialog) {
        AlertDialog(
            onDismissRequest = { showTapZoneDialog = false },
            title = { Text("自訂九宮格點擊區域") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("點一下任意格子即可輪流切換：上一頁 / 下一頁 / 選單", style = MaterialTheme.typography.bodySmall)
                    for (row in 0 until 3) {
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            for (col in 0 until 3) {
                                val index = row * 3 + col
                                val action = settings.tapZones.getOrElse(index) { TapAction.TOGGLE_MENU }
                                val cellColor = when (action) {
                                    TapAction.PREV_PAGE -> Color(0xFFE0F2FE)
                                    TapAction.NEXT_PAGE -> Color(0xFFDCFCE7)
                                    TapAction.TOGGLE_MENU -> Color(0xFFFEF3C7)
                                }
                                Surface(
                                    color = cellColor,
                                    shape = RoundedCornerShape(8.dp),
                                    border = BorderStroke(1.dp, Color(0xFF94A3B8)),
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(64.dp)
                                        .clickable {
                                            val nextAction = when (action) {
                                                TapAction.PREV_PAGE -> TapAction.NEXT_PAGE
                                                TapAction.NEXT_PAGE -> TapAction.TOGGLE_MENU
                                                TapAction.TOGGLE_MENU -> TapAction.PREV_PAGE
                                            }
                                            val updated = settings.tapZones.toMutableList()
                                            updated[index] = nextAction
                                            onSettingsChange(settings.copy(tapZones = updated))
                                        }
                                ) {
                                    Box(contentAlignment = Alignment.Center) {
                                        Text(
                                            text = action.label,
                                            color = Color(0xFF0F172A),
                                            style = MaterialTheme.typography.labelMedium,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
                                }
                            }
                        }
                    }
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = { onSettingsChange(settings.copy(tapZones = ReaderSettings.defaultHorizontalTapZones())) }
                        ) { Text("套用橫書預設") }
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = { onSettingsChange(settings.copy(tapZones = ReaderSettings.defaultVerticalTapZones())) }
                        ) { Text("套用直書預設") }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showTapZoneDialog = false }) { Text("完成") }
            }
        )
    }
}

/**
 * Combined Slider + Compact Direct Numeric Input (BasicTextField so text is never clipped).
 */
@Composable
private fun NumericSliderControl(
    label: String,
    unit: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    decimals: Int,
    onValueChange: (Float) -> Unit
) {
    val focusManager = LocalFocusManager.current
    fun formatVal(v: Float): String = if (decimals == 0) v.toInt().toString() else "%.${decimals}f".format(v)

    var textValue by remember { mutableStateOf(formatVal(value)) }
    var isFocused by remember { mutableStateOf(false) }

    LaunchedEffect(value, isFocused) {
        if (!isFocused) {
            textValue = formatVal(value)
        }
    }

    fun commitText() {
        val parsed = textValue.trim().toFloatOrNull()
        if (parsed != null) {
            val clamped = parsed.coerceIn(valueRange.start, valueRange.endInclusive)
            onValueChange(clamped)
            textValue = formatVal(clamped)
        } else {
            textValue = formatVal(value)
        }
    }

    val borderColor = if (isFocused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    val textColor = MaterialTheme.colorScheme.onSurface

    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.weight(1f)
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .width(74.dp)
                        .height(34.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))
                        .border(1.dp, borderColor, RoundedCornerShape(8.dp))
                        .padding(horizontal = 6.dp)
                ) {
                    BasicTextField(
                        value = textValue,
                        onValueChange = { input ->
                            val filtered = input.filter { it.isDigit() || (decimals > 0 && it == '.') }
                            if (filtered.count { it == '.' } <= 1) {
                                textValue = filtered
                                filtered.toFloatOrNull()?.let { parsed ->
                                    if (parsed in valueRange.start..valueRange.endInclusive) {
                                        onValueChange(parsed)
                                    }
                                }
                            }
                        },
                        singleLine = true,
                        textStyle = MaterialTheme.typography.bodyMedium.copy(
                            color = textColor,
                            textAlign = TextAlign.Center,
                            fontWeight = FontWeight.Medium
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        keyboardOptions = KeyboardOptions(
                            keyboardType = if (decimals > 0) KeyboardType.Decimal else KeyboardType.Number,
                            imeAction = ImeAction.Done
                        ),
                        keyboardActions = KeyboardActions(
                            onDone = {
                                commitText()
                                focusManager.clearFocus()
                            }
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .onFocusChanged { state ->
                                if (isFocused && !state.isFocused) {
                                    commitText()
                                }
                                isFocused = state.isFocused
                            }
                    )
                }
                Text(
                    text = unit,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Slider(
            value = value.coerceIn(valueRange.start, valueRange.endInclusive),
            onValueChange = { v ->
                isFocused = false
                onValueChange(v)
            },
            valueRange = valueRange
        )
    }
}

@Composable
private fun QuickToggleChip(
    label: String,
    active: Boolean,
    eInkMode: Boolean,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = when {
            eInkMode && active -> Color.Black
            eInkMode -> Color.White
            active -> MaterialTheme.colorScheme.primary
            else -> MaterialTheme.colorScheme.surfaceVariant
        },
        border = if (eInkMode) BorderStroke(1.dp, Color.Black) else null
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = when {
                eInkMode && active -> Color.White
                eInkMode -> Color.Black
                active -> MaterialTheme.colorScheme.onPrimary
                else -> MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
        )
    }
}

@Composable
private fun BottomMenuButton(
    icon: ImageVector,
    label: String,
    tint: Color,
    onClick: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp)
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(2.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, color = tint)
    }
}

@Composable
private fun SettingSwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}
