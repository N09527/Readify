package com.inkflow.reader.ui

import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.inkflow.reader.data.AppRepository
import com.inkflow.reader.engine.VisualPageCanvasView
import com.inkflow.reader.engine.VisualSpreadBitmaps
import com.inkflow.reader.model.*
import com.inkflow.reader.parser.VisualBookSource
import com.inkflow.reader.parser.VisualBookSourceFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VisualReaderScreen(
    book: BookItem,
    repository: AppRepository,
    settings: ReaderSettings,
    volumeController: ReaderVolumeController,
    onSettingsChange: (ReaderSettings) -> Unit,
    onSwitchToPdfReflow: (() -> Unit)?,
    onExitReader: () -> Unit
) {
    val context = LocalContext.current

    var source by remember(book.id) { mutableStateOf<VisualBookSource?>(null) }
    var isLoading by remember(book.id) { mutableStateOf(true) }
    var totalPages by remember(book.id) { mutableIntStateOf(0) }
    var currentPageIndex by remember(book.id) { mutableIntStateOf(0) }

    var viewportW by remember { mutableIntStateOf(0) }
    var viewportH by remember { mutableIntStateOf(0) }
    var isDualPage by remember { mutableStateOf(false) }

    var bitmapCache by remember(book.id) { mutableStateOf<Map<Int, Bitmap>>(emptyMap()) }
    var cacheEpoch by remember(book.id) { mutableIntStateOf(0) }

    var showMenu by remember(book.id) { mutableStateOf(false) }
    var showSettingsSheet by remember { mutableStateOf(false) }
    var showTapZoneDialog by remember { mutableStateOf(false) }
    var toastMessage by remember { mutableStateOf<String?>(null) }

    var canvasViewRef by remember { mutableStateOf<VisualPageCanvasView?>(null) }

    var hasExited by remember(book.id) { mutableStateOf(false) }

    fun exitReaderSafely() {
        if (hasExited) return
        hasExited = true
        if (!isLoading && totalPages > 0) {
            val step = if (isDualPage) 2 else 1
            val reachedPageCount = (currentPageIndex + step).coerceAtMost(totalPages)
            val progressFraction = if (reachedPageCount >= totalPages) {
                1f
            } else {
                (reachedPageCount.toFloat() / totalPages.toFloat()).coerceIn(0f, 1f)
            }
            repository.updateVisualBookProgress(book.id, currentPageIndex, progressFraction)
        }
        onExitReader()
    }

    // System Back button & Android gesture swipe-back inside comic/PDF reader flush progress & return to Bookshelf
    BackHandler {
        when {
            showTapZoneDialog -> showTapZoneDialog = false
            showSettingsSheet -> showSettingsSheet = false
            else -> exitReaderSafely()
        }
    }

    val isPdf = book.format == BookFormat.PDF
    val isRtlFlow = if (isPdf) false else settings.comicRtl

    LaunchedEffect(book.id) {
        isLoading = true
        val opened = VisualBookSourceFactory.open(context, book)
        source = opened
        totalPages = opened.pageCount
        currentPageIndex = book.lastPageIndex.coerceIn(0, (opened.pageCount - 1).coerceAtLeast(0))
        isLoading = false
    }

    DisposableEffect(book.id) {
        onDispose {
            source?.close()
            bitmapCache.values.forEach { if (!it.isRecycled) it.recycle() }
        }
    }

    LaunchedEffect(settings.pdfAutoCrop, isPdf) {
        if (isPdf) {
            bitmapCache.values.forEach { if (!it.isRecycled) it.recycle() }
            bitmapCache = emptyMap()
            cacheEpoch++
        }
    }

    LaunchedEffect(isDualPage) {
        if (isDualPage && currentPageIndex % 2 == 1) {
            currentPageIndex = (currentPageIndex - 1).coerceAtLeast(0)
        }
    }

    LaunchedEffect(currentPageIndex, totalPages, isDualPage) {
        if (totalPages > 0) {
            val step = if (isDualPage) 2 else 1
            val reachedPageCount = (currentPageIndex + step).coerceAtMost(totalPages)
            val progressFraction = if (reachedPageCount >= totalPages) {
                1f
            } else {
                (reachedPageCount.toFloat() / totalPages.toFloat()).coerceIn(0f, 1f)
            }
            withContext(Dispatchers.IO) {
                repository.updateVisualBookProgress(book.id, currentPageIndex, progressFraction)
            }
        }
    }

    LaunchedEffect(source, currentPageIndex, isDualPage, viewportW, viewportH, cacheEpoch) {
        val src = source ?: return@LaunchedEffect
        if (totalPages <= 0 || viewportW <= 0 || viewportH <= 0) return@LaunchedEffect

        val step = if (isDualPage) 2 else 1
        val targetMaxDim = if (isDualPage) {
            maxOf(viewportW / 2, viewportH).coerceIn(800, 2000)
        } else {
            maxOf(viewportW, viewportH).coerceIn(900, 2200)
        }

        val neededIndices = buildList {
            add(currentPageIndex)
            if (isDualPage) add(currentPageIndex + 1)
            add(currentPageIndex + step)
            if (isDualPage) add(currentPageIndex + step + 1)
            add(currentPageIndex - step)
            if (isDualPage) add(currentPageIndex - step + 1)
        }.filter { it in 0 until totalPages }.distinct()

        val working = bitmapCache.toMutableMap()
        var changed = false

        for (idx in neededIndices) {
            val existing = working[idx]
            if (existing == null || existing.isRecycled) {
                val rendered = src.renderPage(idx, targetMaxDim, autoCrop = isPdf && settings.pdfAutoCrop)
                if (rendered != null) {
                    working[idx] = rendered
                    changed = true
                    if (idx == currentPageIndex || (isDualPage && idx == currentPageIndex + 1)) {
                        bitmapCache = working.toMap()
                    }
                }
            }
        }

        val keepSet = neededIndices.toSet()
        val toEvict = working.keys.filter { it !in keepSet }
        for (ev in toEvict) {
            working.remove(ev)?.let { if (!it.isRecycled) it.recycle() }
            changed = true
        }

        if (changed) bitmapCache = working.toMap()
    }

    val pageStep = if (isDualPage) 2 else 1

    fun buildSpread(startIdx: Int): VisualSpreadBitmaps? {
        if (totalPages <= 0 || startIdx !in 0 until totalPages) return null
        val secondIdx = if (isDualPage && startIdx + 1 < totalPages) startIdx + 1 else null
        return VisualSpreadBitmaps(
            firstPageIndex = startIdx,
            secondPageIndex = secondIdx,
            firstBitmap = bitmapCache[startIdx]?.takeUnless { it.isRecycled },
            secondBitmap = secondIdx?.let { bitmapCache[it]?.takeUnless { b -> b.isRecycled } },
            totalPages = totalPages
        )
    }

    val currentSpread = buildSpread(currentPageIndex)
    val nextSpread = buildSpread(currentPageIndex + pageStep)
    val prevSpread = buildSpread(currentPageIndex - pageStep)

    val onNextAction by rememberUpdatedState {
        if (currentPageIndex + pageStep < totalPages) {
            currentPageIndex += pageStep
            true
        } else {
            toastMessage = "已經是最後一頁了"
            false
        }
    }

    val onPrevAction by rememberUpdatedState {
        if (currentPageIndex - pageStep >= 0) {
            currentPageIndex -= pageStep
            true
        } else {
            toastMessage = "已經是第一頁了"
            false
        }
    }

    val onBoundaryAction by rememberUpdatedState { isEnd: Boolean ->
        toastMessage = if (isEnd) {
            "已經是最後一頁了"
        } else if (isRtlFlow) {
            "已經是第一頁（漫畫右翻左模式：向右滑＝下一頁）"
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
                VisualPageCanvasView(ctx).also { view ->
                    canvasViewRef = view
                    view.listener = object : VisualPageCanvasView.Listener {
                        override fun onRequestNextSpread(): Boolean = onNextAction()
                        override fun onRequestPrevSpread(): Boolean = onPrevAction()
                        override fun onToggleMenu() = onToggleMenuAction()
                        override fun onBoundaryReached(isEnd: Boolean) = onBoundaryAction(isEnd)
                        override fun onViewportReady(w: Int, h: Int, dual: Boolean) {
                            viewportW = w
                            viewportH = h
                            isDualPage = dual
                        }
                    }
                }
            },
            update = { view ->
                view.updateState(
                    newSettings = settings,
                    rtlFlow = isRtlFlow,
                    invertPdfColors = isPdf && settings.pdfNightInvert,
                    current = currentSpread,
                    next = nextSpread,
                    prev = prevSpread
                )
            }
        )

        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(if (settings.eInkMode) Color.White else Color(0xFF1A1D21)),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = if (book.format == BookFormat.CBR) "正在解壓漫畫檔…" else "正在開啟頁面…",
                        color = if (settings.eInkMode) Color.Black else Color.White
                    )
                }
            }
        } else if (totalPages == 0) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(if (settings.eInkMode) Color.White else Color(0xFF1A1D21)),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(24.dp)) {
                    Text(
                        text = "此檔案內找不到可顯示的圖片或頁面",
                        color = if (settings.eInkMode) Color.Black else Color.White
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = { exitReaderSafely() }) { Text("返回書架") }
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
                                text = "${book.format.label} · 第 ${currentPageIndex + 1} / $totalPages 頁（支援雙指縮放）",
                                style = MaterialTheme.typography.labelSmall,
                                color = barFg.copy(alpha = 0.7f)
                            )
                        }
                    }

                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (isPdf) {
                            item {
                                VisualQuickChip(
                                    label = if (settings.pdfAutoCrop) "自動裁邊:開" else "自動裁邊",
                                    active = settings.pdfAutoCrop,
                                    eInkMode = settings.eInkMode,
                                    onClick = { onSettingsChange(settings.copy(pdfAutoCrop = !settings.pdfAutoCrop)) }
                                )
                            }
                            if (onSwitchToPdfReflow != null) {
                                item {
                                    VisualQuickChip(
                                        label = "文字重排",
                                        active = false,
                                        eInkMode = settings.eInkMode,
                                        onClick = {
                                            showMenu = false
                                            onSwitchToPdfReflow()
                                        }
                                    )
                                }
                            }
                            item {
                                VisualQuickChip(
                                    label = "夜間反白",
                                    active = settings.pdfNightInvert,
                                    eInkMode = settings.eInkMode,
                                    onClick = { onSettingsChange(settings.copy(pdfNightInvert = !settings.pdfNightInvert)) }
                                )
                            }
                        } else {
                            item {
                                VisualQuickChip(
                                    label = if (settings.comicRtl) "右翻左(日漫)" else "左翻右",
                                    active = settings.comicRtl,
                                    eInkMode = settings.eInkMode,
                                    onClick = { onSettingsChange(settings.copy(comicRtl = !settings.comicRtl)) }
                                )
                            }
                        }

                        item {
                            VisualQuickChip(
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
                            VisualQuickChip(
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
                    if (totalPages > 1) {
                        val maxPageIdx = (totalPages - 1).coerceAtLeast(1)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(text = "${currentPageIndex + 1}", style = MaterialTheme.typography.labelMedium, color = barFg)
                            Slider(
                                value = currentPageIndex.coerceIn(0, maxPageIdx).toFloat(),
                                onValueChange = { v ->
                                    val snapped = if (isDualPage) (v.toInt() / 2) * 2 else v.toInt()
                                    currentPageIndex = snapped.coerceIn(0, (totalPages - 1).coerceAtLeast(0))
                                },
                                valueRange = 0f..maxPageIdx.toFloat(),
                                modifier = Modifier
                                    .weight(1f)
                                    .padding(horizontal = 8.dp)
                            )
                            Text(text = "$totalPages", style = MaterialTheme.typography.labelMedium, color = barFg)
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceAround
                    ) {
                        VisualBottomButton(Icons.Default.Tune, "閱讀設定", barFg) { showSettingsSheet = true }
                        VisualBottomButton(Icons.Default.TouchApp, "點擊區域", barFg) { showTapZoneDialog = true }
                        VisualBottomButton(Icons.Default.Close, "隱藏選單", barFg) { showMenu = false }
                    }
                }
            }
        }
    }

    if (showSettingsSheet) {
        ModalBottomSheet(onDismissRequest = { showSettingsSheet = false }) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 8.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Text(
                    text = if (isPdf) "PDF 閱讀設定" else "漫畫閱讀設定",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )

                if (isPdf) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("PDF 自動裁切白邊", modifier = Modifier.weight(1f))
                        Switch(checked = settings.pdfAutoCrop, onCheckedChange = { onSettingsChange(settings.copy(pdfAutoCrop = it)) })
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("PDF 夜間深色反白", modifier = Modifier.weight(1f))
                        Switch(checked = settings.pdfNightInvert, onCheckedChange = { onSettingsChange(settings.copy(pdfNightInvert = it)) })
                    }
                    if (onSwitchToPdfReflow != null) {
                        Button(
                            onClick = {
                                showSettingsSheet = false
                                showMenu = false
                                onSwitchToPdfReflow()
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("切換至 PDF 文字重排模式（可調字體／直橫排）")
                        }
                    }
                } else {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("日漫右翻左順序（右頁→左頁，向右滑下一頁）", modifier = Modifier.weight(1f))
                        Switch(checked = settings.comicRtl, onCheckedChange = { onSettingsChange(settings.copy(comicRtl = it)) })
                    }
                }

                Text("翻頁動畫模式", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PageTurnAnimation.entries.forEach { anim ->
                        FilterChip(
                            selected = settings.pageTurnAnimation == anim,
                            onClick = { onSettingsChange(settings.copy(pageTurnAnimation = anim)) },
                            label = { Text(anim.label) }
                        )
                    }
                }

                Text("雙頁模式", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DualPageMode.entries.forEach { mode ->
                        FilterChip(
                            selected = settings.dualPageMode == mode,
                            onClick = { onSettingsChange(settings.copy(dualPageMode = mode)) },
                            label = { Text(mode.label) }
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("雙頁中間仿真接縫陰影", modifier = Modifier.weight(1f))
                    Switch(checked = settings.showSpineShadow, onCheckedChange = { onSettingsChange(settings.copy(showSpineShadow = it)) })
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("電子紙（E-ink）模式（關閉動畫）", modifier = Modifier.weight(1f))
                    Switch(checked = settings.eInkMode, onCheckedChange = { onSettingsChange(settings.copy(eInkMode = it)) })
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("音量鍵翻頁", modifier = Modifier.weight(1f))
                    Switch(checked = settings.volumeKeyPageTurn, onCheckedChange = { onSettingsChange(settings.copy(volumeKeyPageTurn = it)) })
                }

                Spacer(Modifier.height(16.dp))
            }
        }
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
                                        .height(60.dp)
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
                        ) { Text("左翻右預設") }
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = { onSettingsChange(settings.copy(tapZones = ReaderSettings.defaultVerticalTapZones())) }
                        ) { Text("日漫右翻左") }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showTapZoneDialog = false }) { Text("完成") }
            }
        )
    }
}

@Composable
private fun VisualQuickChip(
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
private fun VisualBottomButton(
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
