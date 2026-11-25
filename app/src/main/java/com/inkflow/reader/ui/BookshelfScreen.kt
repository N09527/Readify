package com.inkflow.reader.ui

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.inkflow.reader.model.BookContentType
import com.inkflow.reader.model.BookFormat
import com.inkflow.reader.model.BookItem
import com.inkflow.reader.model.ReadStatusFilter
import com.inkflow.reader.model.ShelfCoverSize
import com.inkflow.reader.model.ShelfSortField
import com.inkflow.reader.parser.NaturalSort
import kotlinx.coroutines.delay
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookshelfScreen(
    books: List<BookItem>,
    eInkMode: Boolean,
    sortField: ShelfSortField,
    sortAscending: Boolean,
    coverSize: ShelfCoverSize,
    isImporting: Boolean,
    importStatusMessage: String?,
    onDismissStatus: () -> Unit,
    onImportFilesClick: () -> Unit,
    onImportFolderClick: () -> Unit,
    onOpenBook: (BookItem) -> Unit,
    onDeleteBook: (BookItem) -> Unit,
    onBatchDeleteBooks: (Set<String>) -> Unit,
    onUpdateBookTags: (BookItem, List<String>) -> Unit,
    onBatchAddTags: (Set<String>, List<String>) -> Unit,
    onBatchRemoveTags: (Set<String>, List<String>) -> Unit,
    onSetBookReadStatus: (BookItem, Boolean) -> Unit,
    onBatchSetReadStatus: (Set<String>, Boolean) -> Unit,
    onUpdateBookContentType: (BookItem, BookContentType) -> Unit,
    onSortChange: (ShelfSortField, Boolean) -> Unit,
    onCoverSizeChange: (ShelfCoverSize) -> Unit,
    onToggleEInkMode: () -> Unit,
    onOpenCloudSync: () -> Unit
) {
    var isGridView by remember { mutableStateOf(true) }
    val haptic = LocalHapticFeedback.current
    val currentCoverSizeState = rememberUpdatedState(coverSize)
    val currentOnCoverSizeChange = rememberUpdatedState(onCoverSizeChange)

    // Separate, orthogonal filters: Read Status vs Multi-Tags vs Search Query
    var selectedStatus by remember { mutableStateOf(ReadStatusFilter.ALL) }
    var selectedTags by remember { mutableStateOf<Set<String>>(emptySet()) }
    var isSearchActive by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    var showSortMenu by remember { mutableStateOf(false) }
    var showViewMenu by remember { mutableStateOf(false) }
    var zoomToastText by remember { mutableStateOf<String?>(null) }
    var zoomToastTick by remember { mutableIntStateOf(0) }

    LaunchedEffect(zoomToastTick) {
        if (zoomToastTick > 0) {
            delay(1300L)
            zoomToastText = null
        }
    }

    var editingBook by remember { mutableStateOf<BookItem?>(null) }

    var isSelectionMode by remember { mutableStateOf(false) }
    var selectedBookIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var showBatchTagDialog by remember { mutableStateOf(false) }
    var showBatchDeleteConfirm by remember { mutableStateOf(false) }

    var showImportSheet by remember { mutableStateOf(false) }

    val allAvailableTags = remember(books) {
        books.flatMap { it.tags }
            .map { it.trim() }
            .filter { it.isNotBlank() && it != "未分類" }
            .distinct()
            .sortedWith(NaturalSort.COMPARATOR)
    }

    // Prune any selected tag that no longer exists on any book
    LaunchedEffect(allAvailableTags) {
        val validTags = allAvailableTags.toSet()
        val pruned = selectedTags.intersect(validTags)
        if (pruned != selectedTags) selectedTags = pruned
    }

    LaunchedEffect(books) {
        val validIds = books.map { it.id }.toSet()
        val pruned = selectedBookIds.intersect(validIds)
        if (pruned != selectedBookIds) selectedBookIds = pruned
        if (books.isEmpty()) isSelectionMode = false
    }

    BackHandler(enabled = isSelectionMode || isSearchActive) {
        when {
            isSelectionMode -> {
                isSelectionMode = false
                selectedBookIds = emptySet()
            }
            isSearchActive -> {
                isSearchActive = false
                searchQuery = ""
            }
        }
    }

    val filteredBooks = remember(books, selectedStatus, selectedTags, searchQuery, sortField, sortAscending) {
        val q = searchQuery.trim()
        val filtered = books.filter { book ->
            val statusMatches = when (selectedStatus) {
                ReadStatusFilter.ALL -> true
                ReadStatusFilter.UNREAD -> book.isUnread
                ReadStatusFilter.READING -> book.isInProgress
                ReadStatusFilter.FINISHED -> book.isMarkedOrFinishedRead
            }
            val tagsMatch = selectedTags.isEmpty() || selectedTags.all { tag -> tag in book.tags }
            val queryMatches = q.isEmpty() ||
                book.title.contains(q, ignoreCase = true) ||
                book.author.contains(q, ignoreCase = true)
            statusMatches && tagsMatch && queryMatches
        }

        val comparator = Comparator<BookItem> { a, b ->
            val primary = when (sortField) {
                ShelfSortField.ADDED_TIME -> a.addedTime.compareTo(b.addedTime)
                ShelfSortField.TITLE -> NaturalSort.compareNatural(a.title.lowercase(), b.title.lowercase())
                ShelfSortField.AUTHOR -> {
                    val c = NaturalSort.compareNatural(a.author.lowercase(), b.author.lowercase())
                    if (c != 0) c else NaturalSort.compareNatural(a.title.lowercase(), b.title.lowercase())
                }
            }
            val ordered = if (sortAscending) primary else -primary
            if (ordered != 0) ordered else a.id.compareTo(b.id)
        }
        filtered.sortedWith(comparator)
    }

    val allVisibleSelected = remember(filteredBooks, selectedBookIds) {
        filteredBooks.isNotEmpty() && filteredBooks.all { it.id in selectedBookIds }
    }

    fun toggleBookSelection(bookId: String) {
        selectedBookIds = if (bookId in selectedBookIds) {
            selectedBookIds - bookId
        } else {
            selectedBookIds + bookId
        }
    }

    fun exitSelectionMode() {
        isSelectionMode = false
        selectedBookIds = emptySet()
    }

    val bgColor = if (eInkMode) Color.White else MaterialTheme.colorScheme.background
    val textColor = if (eInkMode) Color.Black else MaterialTheme.colorScheme.onBackground
    val sortArrow = if (sortAscending) "↑" else "↓"

    Scaffold(
        containerColor = bgColor,
        topBar = {
            if (isSelectionMode) {
                TopAppBar(
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = if (eInkMode) Color(0xFFEEEEEE) else MaterialTheme.colorScheme.secondaryContainer,
                        titleContentColor = textColor,
                        navigationIconContentColor = textColor,
                        actionIconContentColor = textColor
                    ),
                    navigationIcon = {
                        IconButton(onClick = { exitSelectionMode() }) {
                            Icon(Icons.Default.Close, contentDescription = "結束多選")
                        }
                    },
                    title = {
                        Text(
                            text = "已選取 ${selectedBookIds.size} 本",
                            fontWeight = FontWeight.Bold
                        )
                    },
                    actions = {
                        TextButton(
                            onClick = {
                                val visibleIds = filteredBooks.map { it.id }.toSet()
                                selectedBookIds = if (allVisibleSelected) {
                                    selectedBookIds - visibleIds
                                } else {
                                    selectedBookIds + visibleIds
                                }
                            }
                        ) {
                            Text(
                                text = if (allVisibleSelected) "取消全選" else "全選",
                                color = textColor,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                )
            } else {
                TopAppBar(
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = bgColor,
                        titleContentColor = textColor,
                        actionIconContentColor = textColor
                    ),
                    title = {
                        Column {
                            Text("Readify 書架", fontWeight = FontWeight.Bold)
                            val countText = if (filteredBooks.size != books.size) {
                                "${filteredBooks.size}/${books.size} 本"
                            } else {
                                "${books.size} 本"
                            }
                            Text(
                                text = "$countText · ${sortField.label}$sortArrow" + if (eInkMode) " · 電子紙" else "",
                                style = MaterialTheme.typography.labelSmall,
                                color = textColor.copy(alpha = 0.65f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    },
                    actions = {
                        IconButton(onClick = {
                            if (isSearchActive) {
                                isSearchActive = false
                                searchQuery = ""
                            } else {
                                isSearchActive = true
                            }
                        }) {
                            Icon(
                                imageVector = if (isSearchActive) Icons.Default.SearchOff else Icons.Default.Search,
                                contentDescription = "搜尋書名或作者"
                            )
                        }
                        Box {
                            IconButton(onClick = { showSortMenu = true }) {
                                Icon(Icons.Default.Sort, contentDescription = "排序方式")
                            }
                            DropdownMenu(
                                expanded = showSortMenu,
                                onDismissRequest = { showSortMenu = false }
                            ) {
                                ShelfSortField.entries.forEach { field ->
                                    val selected = sortField == field
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                text = "依${field.label}",
                                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal
                                            )
                                        },
                                        leadingIcon = {
                                            if (selected) {
                                                Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                            }
                                        },
                                        onClick = {
                                            val defaultAsc = when (field) {
                                                ShelfSortField.ADDED_TIME -> false
                                                ShelfSortField.TITLE, ShelfSortField.AUTHOR -> true
                                            }
                                            val nextAsc = if (sortField == field) sortAscending else defaultAsc
                                            onSortChange(field, nextAsc)
                                            showSortMenu = false
                                        }
                                    )
                                }
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            text = "升序（↑）",
                                            fontWeight = if (sortAscending) FontWeight.Bold else FontWeight.Normal
                                        )
                                    },
                                    leadingIcon = {
                                        if (sortAscending) {
                                            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                        }
                                    },
                                    onClick = {
                                        onSortChange(sortField, true)
                                        showSortMenu = false
                                    }
                                )
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            text = "降序（↓）",
                                            fontWeight = if (!sortAscending) FontWeight.Bold else FontWeight.Normal
                                        )
                                    },
                                    leadingIcon = {
                                        if (!sortAscending) {
                                            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                        }
                                    },
                                    onClick = {
                                        onSortChange(sortField, false)
                                        showSortMenu = false
                                    }
                                )
                            }
                        }
                        if (books.isNotEmpty()) {
                            IconButton(
                                onClick = {
                                    isSelectionMode = true
                                    selectedBookIds = emptySet()
                                },
                                modifier = Modifier.size(38.dp)
                            ) {
                                Icon(Icons.Default.CheckBox, contentDescription = "多選管理")
                            }
                        }
                        IconButton(onClick = onOpenCloudSync, modifier = Modifier.size(38.dp)) {
                            Icon(Icons.Default.CloudSync, contentDescription = "雲端同步")
                        }
                        IconButton(onClick = onToggleEInkMode, modifier = Modifier.size(38.dp)) {
                            Icon(Icons.Default.Contrast, contentDescription = "電子紙模式")
                        }
                        Box {
                            IconButton(onClick = { showViewMenu = true }, modifier = Modifier.size(38.dp)) {
                                Icon(
                                    imageVector = if (isGridView) Icons.Default.GridView else Icons.AutoMirrored.Filled.ViewList,
                                    contentDescription = "檢視與書封大小"
                                )
                            }
                            DropdownMenu(
                                expanded = showViewMenu,
                                onDismissRequest = { showViewMenu = false }
                            ) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            text = "網格書封檢視",
                                            fontWeight = if (isGridView) FontWeight.Bold else FontWeight.Normal
                                        )
                                    },
                                    leadingIcon = {
                                        if (isGridView) {
                                            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                        }
                                    },
                                    onClick = {
                                        isGridView = true
                                        showViewMenu = false
                                    }
                                )
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            text = "清單檢視",
                                            fontWeight = if (!isGridView) FontWeight.Bold else FontWeight.Normal
                                        )
                                    },
                                    leadingIcon = {
                                        if (!isGridView) {
                                            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                        }
                                    },
                                    onClick = {
                                        isGridView = false
                                        showViewMenu = false
                                    }
                                )
                                HorizontalDivider()
                                Text(
                                    text = "書封大小（亦支援雙指縮放）",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
                                )
                                ShelfCoverSize.entries.forEach { sizeOption ->
                                    val selected = isGridView && coverSize == sizeOption
                                    val titleText = if (sizeOption == ShelfCoverSize.STANDARD) {
                                        "${sizeOption.label}（預設）"
                                    } else {
                                        sizeOption.label
                                    }
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                text = titleText,
                                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal
                                            )
                                        },
                                        leadingIcon = {
                                            if (selected) {
                                                Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                            }
                                        },
                                        onClick = {
                                            isGridView = true
                                            onCoverSizeChange(sizeOption)
                                            zoomToastText = "書封尺寸：${sizeOption.label}"
                                            zoomToastTick++
                                            showViewMenu = false
                                        }
                                    )
                                }
                            }
                        }
                    }
                )
            }
        },
        bottomBar = {
            if (isSelectionMode) {
                val hasSelection = selectedBookIds.isNotEmpty()
                val actionTint = if (eInkMode) Color.Black else MaterialTheme.colorScheme.onSurface
                val deleteTint = if (eInkMode) Color.Black else MaterialTheme.colorScheme.error
                Surface(
                    color = if (eInkMode) Color.White else MaterialTheme.colorScheme.surface,
                    tonalElevation = if (eInkMode) 0.dp else 6.dp,
                    shadowElevation = if (eInkMode) 0.dp else 6.dp,
                    border = if (eInkMode) BorderStroke(1.dp, Color.Black) else null
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = 8.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceEvenly
                    ) {
                        BatchActionItem(
                            icon = Icons.Default.CheckCircle,
                            label = "設為已讀",
                            enabled = hasSelection,
                            tint = actionTint,
                            onClick = {
                                onBatchSetReadStatus(selectedBookIds, true)
                                exitSelectionMode()
                            }
                        )
                        BatchActionItem(
                            icon = Icons.Default.RadioButtonUnchecked,
                            label = "設為未讀",
                            enabled = hasSelection,
                            tint = actionTint,
                            onClick = {
                                onBatchSetReadStatus(selectedBookIds, false)
                                exitSelectionMode()
                            }
                        )
                        BatchActionItem(
                            icon = Icons.Default.LocalOffer,
                            label = "批次標籤",
                            enabled = hasSelection,
                            tint = actionTint,
                            onClick = { showBatchTagDialog = true }
                        )
                        BatchActionItem(
                            icon = Icons.Default.Delete,
                            label = "刪除選取",
                            enabled = hasSelection,
                            tint = deleteTint,
                            onClick = { showBatchDeleteConfirm = true }
                        )
                    }
                }
            }
        },
        floatingActionButton = {
            if (!isSelectionMode) {
                ExtendedFloatingActionButton(
                    onClick = { if (!isImporting) showImportSheet = true },
                    containerColor = if (eInkMode) Color.Black else MaterialTheme.colorScheme.primary,
                    contentColor = Color.White,
                    icon = {
                        if (isImporting) {
                            CircularProgressIndicator(
                                color = Color.White,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(18.dp)
                            )
                        } else {
                            Icon(Icons.Default.Add, contentDescription = null)
                        }
                    },
                    text = { Text(if (isImporting) "匯入中…" else "匯入電子書 / 漫畫") }
                )
            }
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            // ---------------- Bookshelf Search Bar (Title + Author, assisted by Status & Tags) ----------------
            if (isSearchActive && !isSelectionMode) {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = { Text("搜尋書名或作者…") },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    trailingIcon = {
                        IconButton(onClick = {
                            if (searchQuery.isNotEmpty()) {
                                searchQuery = ""
                            } else {
                                isSearchActive = false
                            }
                        }) {
                            Icon(Icons.Default.Close, contentDescription = "清除搜尋")
                        }
                    },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 4.dp)
                )
            }

            // ---------------- Import / Action Status Banner ----------------
            if (importStatusMessage != null) {
                Surface(
                    color = if (eInkMode) Color(0xFFEEEEEE) else MaterialTheme.colorScheme.secondaryContainer,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 4.dp),
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = importStatusMessage,
                                modifier = Modifier.weight(1f),
                                style = MaterialTheme.typography.bodySmall,
                                color = textColor
                            )
                            if (!isImporting) {
                                IconButton(onClick = onDismissStatus, modifier = Modifier.size(24.dp)) {
                                    Icon(Icons.Default.Close, contentDescription = "關閉", tint = textColor)
                                }
                            }
                        }
                        if (isImporting) {
                            Spacer(Modifier.height(6.dp))
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        }
                    }
                }
            }

            // ---------------- Row 1: Reading Status Filter (全部 / 未讀 / 閱讀中 / 已讀) ----------------
            LazyRow(
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                items(ReadStatusFilter.entries) { status ->
                    FilterChip(
                        selected = selectedStatus == status,
                        onClick = { selectedStatus = status },
                        label = { Text(status.label) }
                    )
                }
            }

            // ---------------- Row 2: Multi-Tag Filter Bar (completely separate from Status, no "未分類") ----------------
            if (allAvailableTags.isNotEmpty()) {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    item {
                        Icon(
                            imageVector = Icons.Default.LocalOffer,
                            contentDescription = "標籤分類",
                            tint = textColor.copy(alpha = 0.55f),
                            modifier = Modifier
                                .padding(end = 2.dp)
                                .size(16.dp)
                        )
                    }
                    if (selectedTags.isNotEmpty()) {
                        item {
                            AssistChip(
                                onClick = { selectedTags = emptySet() },
                                label = { Text("清除標籤 (${selectedTags.size})") },
                                leadingIcon = {
                                    Icon(Icons.Default.Close, contentDescription = null, modifier = Modifier.size(14.dp))
                                }
                            )
                        }
                    }
                    items(allAvailableTags, key = { it }) { tag ->
                        val isTagSelected = tag in selectedTags
                        FilterChip(
                            selected = isTagSelected,
                            onClick = {
                                selectedTags = if (isTagSelected) selectedTags - tag else selectedTags + tag
                            },
                            label = { Text("#$tag") }
                        )
                    }
                }
            }

            // ---------------- Books Grid / List / Empty State ----------------
            if (filteredBooks.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(24.dp)) {
                        Icon(
                            imageVector = Icons.Default.Book,
                            contentDescription = null,
                            modifier = Modifier.size(56.dp),
                            tint = textColor.copy(alpha = 0.35f)
                        )
                        Spacer(Modifier.height(12.dp))
                        if (books.isEmpty()) {
                            Text("書架目前是空的", style = MaterialTheme.typography.titleMedium, color = textColor)
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "支援 TXT / EPUB(文字+漫畫) / PDF / CBZ / CBR / ZIP / MOBI / AZW3",
                                style = MaterialTheme.typography.bodySmall,
                                color = textColor.copy(alpha = 0.6f)
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "可點右下角選擇單檔、多檔或整個資料夾匯入",
                                style = MaterialTheme.typography.labelSmall,
                                color = textColor.copy(alpha = 0.5f)
                            )
                        } else {
                            val activeFiltersDesc = buildList {
                                if (selectedStatus != ReadStatusFilter.ALL) add(selectedStatus.label)
                                if (selectedTags.isNotEmpty()) add(selectedTags.joinToString(" ") { "#$it" })
                                if (searchQuery.isNotBlank()) add("「${searchQuery.trim()}」")
                            }.joinToString(" · ")
                            Text(
                                text = "符合條件（$activeFiltersDesc）的書籍目前為 0 本",
                                style = MaterialTheme.typography.titleSmall,
                                color = textColor
                            )
                            Spacer(Modifier.height(10.dp))
                            OutlinedButton(onClick = {
                                selectedStatus = ReadStatusFilter.ALL
                                selectedTags = emptySet()
                                searchQuery = ""
                            }) {
                                Text("重設篩選條件")
                            }
                        }
                    }
                }
            } else if (isGridView) {
                val hSpacing = when (coverSize) {
                    ShelfCoverSize.COMPACT -> 10.dp
                    ShelfCoverSize.STANDARD -> 12.dp
                    ShelfCoverSize.MEDIUM -> 14.dp
                    ShelfCoverSize.LARGE -> 18.dp
                    ShelfCoverSize.EXTRA_LARGE -> 22.dp
                }
                val vSpacing = hSpacing + 2.dp

                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .pointerInput(isGridView) {
                            awaitEachGesture {
                                var accumScale = 1f
                                do {
                                    val event = awaitPointerEvent()
                                    val pressedCount = event.changes.count { it.pressed }
                                    if (pressedCount >= 2) {
                                        val zoom = event.calculateZoom()
                                        if (zoom > 0f && zoom != 1f) {
                                            accumScale *= zoom
                                            val cur = currentCoverSizeState.value
                                            if (accumScale >= 1.28f) {
                                                val next = cur.stepLarger()
                                                accumScale = 1f
                                                if (next != cur) {
                                                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                                    currentOnCoverSizeChange.value(next)
                                                    zoomToastText = "書封尺寸：${next.label}"
                                                    zoomToastTick++
                                                }
                                            } else if (accumScale <= 0.78f) {
                                                val prev = cur.stepSmaller()
                                                accumScale = 1f
                                                if (prev != cur) {
                                                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                                    currentOnCoverSizeChange.value(prev)
                                                    zoomToastText = "書封尺寸：${prev.label}"
                                                    zoomToastTick++
                                                }
                                            }
                                            event.changes.forEach { change ->
                                                if (change.position != change.previousPosition) {
                                                    change.consume()
                                                }
                                            }
                                        }
                                    } else {
                                        accumScale = 1f
                                    }
                                } while (event.changes.any { it.pressed })
                            }
                        }
                ) {
                    LazyVerticalGrid(
                        columns = GridCells.Adaptive(minSize = coverSize.minWidthDp.dp),
                        contentPadding = PaddingValues(12.dp, 8.dp, 12.dp, 88.dp),
                        horizontalArrangement = Arrangement.spacedBy(hSpacing),
                        verticalArrangement = Arrangement.spacedBy(vSpacing),
                        modifier = Modifier.fillMaxSize()
                    ) {
                        items(filteredBooks, key = { it.id }) { book ->
                            val isSelected = book.id in selectedBookIds
                            BookGridCard(
                                book = book,
                                coverSize = coverSize,
                                eInkMode = eInkMode,
                                isSelectionMode = isSelectionMode,
                                isSelected = isSelected,
                                onClick = {
                                    if (isSelectionMode) toggleBookSelection(book.id)
                                    else onOpenBook(book)
                                },
                                onLongClick = {
                                    if (!isSelectionMode) {
                                        isSelectionMode = true
                                        selectedBookIds = setOf(book.id)
                                    } else {
                                        toggleBookSelection(book.id)
                                    }
                                },
                                onMoreClick = { editingBook = book }
                            )
                        }
                    }

                    zoomToastText?.let { toast ->
                        Surface(
                            color = if (eInkMode) Color.Black else Color(0xD9111827),
                            shape = CircleShape,
                            shadowElevation = if (eInkMode) 0.dp else 4.dp,
                            modifier = Modifier
                                .align(Alignment.TopCenter)
                                .padding(top = 12.dp)
                        ) {
                            Text(
                                text = toast,
                                color = Color.White,
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 7.dp)
                            )
                        }
                    }
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(12.dp, 8.dp, 12.dp, 88.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(filteredBooks, key = { it.id }) { book ->
                        val isSelected = book.id in selectedBookIds
                        BookListRow(
                            book = book,
                            eInkMode = eInkMode,
                            isSelectionMode = isSelectionMode,
                            isSelected = isSelected,
                            onClick = {
                                if (isSelectionMode) toggleBookSelection(book.id)
                                else onOpenBook(book)
                            },
                            onLongClick = {
                                if (!isSelectionMode) {
                                    isSelectionMode = true
                                    selectedBookIds = setOf(book.id)
                                } else {
                                    toggleBookSelection(book.id)
                                }
                            },
                            onMoreClick = { editingBook = book }
                        )
                    }
                }
            }
        }
    }

    // ---------------- Import Method Bottom Sheet (No auto-folder-tagging!) ----------------
    if (showImportSheet) {
        ModalBottomSheet(onDismissRequest = { showImportSheet = false }) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 8.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("匯入電子書 / 漫畫", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    text = "支援 TXT、EPUB（文字與漫畫）、PDF、CBZ、CBR、ZIP、MOBI、AZW3",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                OutlinedCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            showImportSheet = false
                            onImportFilesClick()
                        }
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.Description,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(28.dp)
                        )
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text("選擇檔案匯入（支援單選 / 多選）", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
                            Text(
                                "在檔案總管中長按可一次勾選多本電子書匯入",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                OutlinedCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            showImportSheet = false
                            onImportFolderClick()
                        }
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.FolderOpen,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(28.dp)
                        )
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text("選擇整個資料夾匯入", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
                            Text(
                                "自動遞迴掃描資料夾與子資料夾內所有支援格式，並略過重複檔案",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                Spacer(Modifier.height(12.dp))
            }
        }
    }

    // ---------------- Batch Tag Dialog (Multi-Tag Add / Remove) ----------------
    if (showBatchTagDialog) {
        var newTagInput by remember { mutableStateOf("") }
        var pickedTags by remember { mutableStateOf<Set<String>>(emptySet()) }

        fun parseTypedTags(): List<String> {
            return newTagInput
                .split(',', '，', '、', ';', '；')
                .map { it.trim().removePrefix("#") }
                .filter { it.isNotBlank() && it != "未分類" }
        }

        val combinedTags = (pickedTags + parseTypedTags()).toList()

        AlertDialog(
            onDismissRequest = { showBatchTagDialog = false },
            title = { Text("批次標籤（已選 ${selectedBookIds.size} 本）") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = newTagInput,
                        onValueChange = { newTagInput = it },
                        label = { Text("輸入標籤（多個可用逗號分隔）") },
                        placeholder = { Text("例如：科幻, 最愛") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    if (allAvailableTags.isNotEmpty()) {
                        Text("點選現有標籤（可複選）：", style = MaterialTheme.typography.labelMedium)
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            items(allAvailableTags) { tag ->
                                val active = tag in pickedTags
                                FilterChip(
                                    selected = active,
                                    onClick = {
                                        pickedTags = if (active) pickedTags - tag else pickedTags + tag
                                    },
                                    label = { Text("#$tag") }
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    TextButton(
                        enabled = combinedTags.isNotEmpty(),
                        onClick = {
                            onBatchRemoveTags(selectedBookIds, combinedTags)
                            showBatchTagDialog = false
                            exitSelectionMode()
                        }
                    ) { Text("移除標籤") }
                    Button(
                        enabled = combinedTags.isNotEmpty(),
                        onClick = {
                            onBatchAddTags(selectedBookIds, combinedTags)
                            showBatchTagDialog = false
                            exitSelectionMode()
                        }
                    ) { Text("加入標籤") }
                }
            },
            dismissButton = {
                TextButton(onClick = { showBatchTagDialog = false }) { Text("取消") }
            }
        )
    }

    // ---------------- Batch Delete Confirm Dialog ----------------
    if (showBatchDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showBatchDeleteConfirm = false },
            title = { Text("確定要刪除 ${selectedBookIds.size} 本書嗎？") },
            text = {
                Text("刪除後會移除 App 內匯入的書檔與對應書籤（不會影響你手機原本資料夾裡的原始檔）。")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onBatchDeleteBooks(selectedBookIds)
                        showBatchDeleteConfirm = false
                        exitSelectionMode()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) { Text("確定刪除") }
            },
            dismissButton = {
                TextButton(onClick = { showBatchDeleteConfirm = false }) { Text("取消") }
            }
        )
    }

    // ---------------- Single Book Manage Dialog (Multi-Tags + Read Status + Comic Switch) ----------------
    editingBook?.let { book ->
        var currentTags by remember(book.id) { mutableStateOf(book.tags) }
        var tagInput by remember(book.id) { mutableStateOf("") }

        fun addTagsFromInput() {
            val added = tagInput
                .split(',', '，', '、', ';', '；')
                .map { it.trim().removePrefix("#") }
                .filter { it.isNotBlank() && it != "未分類" }
            if (added.isNotEmpty()) {
                currentTags = (currentTags + added).distinct()
                tagInput = ""
            }
        }

        val statusLabel = when {
            book.isMarkedOrFinishedRead -> "已讀"
            book.isInProgress -> "閱讀中 (${book.displayProgressPercent}%)"
            else -> "未讀"
        }

        AlertDialog(
            onDismissRequest = { editingBook = null },
            title = { Text(book.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "作者：${book.author.ifBlank { "未知作者" }} · ${book.format.label}（${book.contentType.label}）\n狀態：$statusLabel",
                        style = MaterialTheme.typography.bodySmall
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        FilterChip(
                            selected = book.isMarkedOrFinishedRead,
                            onClick = {
                                onSetBookReadStatus(book, true)
                                editingBook = book.copy(isRead = true, hasStartedReading = true, readingProgress = 1f)
                            },
                            leadingIcon = {
                                Icon(Icons.Default.CheckCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                            },
                            label = { Text("標記已讀") },
                            modifier = Modifier.weight(1f)
                        )
                        FilterChip(
                            selected = book.isUnread,
                            onClick = {
                                onSetBookReadStatus(book, false)
                                editingBook = book.copy(
                                    isRead = false,
                                    hasStartedReading = false,
                                    readingProgress = 0f,
                                    lastChapterIndex = 0,
                                    lastCharOffset = 0,
                                    lastPageIndex = 0
                                )
                            },
                            leadingIcon = {
                                Icon(Icons.Default.RadioButtonUnchecked, contentDescription = null, modifier = Modifier.size(16.dp))
                            },
                            label = { Text("標記未讀") },
                            modifier = Modifier.weight(1f)
                        )
                    }

                    HorizontalDivider()
                    Text("標籤分類（可設定多個 Tag）", style = MaterialTheme.typography.labelLarge)

                    if (currentTags.isNotEmpty()) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            items(currentTags, key = { it }) { tag ->
                                InputChip(
                                    selected = true,
                                    onClick = { currentTags = currentTags - tag },
                                    label = { Text("#$tag") },
                                    trailingIcon = {
                                        Icon(Icons.Default.Close, contentDescription = "移除標籤", modifier = Modifier.size(14.dp))
                                    }
                                )
                            }
                        }
                    } else {
                        Text(
                            text = "目前無標籤",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedTextField(
                            value = tagInput,
                            onValueChange = { tagInput = it },
                            label = { Text("新增標籤") },
                            placeholder = { Text("例：推理, 收藏") },
                            singleLine = true,
                            modifier = Modifier.weight(1f)
                        )
                        FilledTonalButton(
                            onClick = { addTagsFromInput() },
                            enabled = tagInput.isNotBlank()
                        ) { Text("加入") }
                    }

                    val suggestedTags = allAvailableTags.filterNot { it in currentTags }
                    if (suggestedTags.isNotEmpty()) {
                        Text("點選加入現有標籤：", style = MaterialTheme.typography.labelSmall)
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            items(suggestedTags, key = { it }) { tag ->
                                AssistChip(
                                    onClick = { currentTags = (currentTags + tag).distinct() },
                                    label = { Text("+#$tag") }
                                )
                            }
                        }
                    }

                    if (book.format in setOf(BookFormat.EPUB, BookFormat.MOBI, BookFormat.AZW3)) {
                        HorizontalDivider()
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("以漫畫圖片模式閱讀", style = MaterialTheme.typography.bodyMedium)
                            Switch(
                                checked = book.contentType == BookContentType.COMIC,
                                onCheckedChange = { isComic ->
                                    val newType = if (isComic) BookContentType.COMIC else BookContentType.TEXT
                                    onUpdateBookContentType(book, newType)
                                    editingBook = book.copy(contentType = newType)
                                }
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    addTagsFromInput()
                    onUpdateBookTags(book, currentTags)
                    editingBook = null
                }) { Text("儲存標籤") }
            },
            dismissButton = {
                Row {
                    TextButton(
                        onClick = {
                            onDeleteBook(book)
                            editingBook = null
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                    ) { Text("刪除書籍") }
                    TextButton(onClick = { editingBook = null }) { Text("取消") }
                }
            }
        )
    }
}

@Composable
private fun BatchActionItem(
    icon: ImageVector,
    label: String,
    enabled: Boolean,
    tint: Color,
    onClick: () -> Unit
) {
    val effectiveTint = if (enabled) tint else tint.copy(alpha = 0.35f)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp)
    ) {
        Icon(icon, contentDescription = label, tint = effectiveTint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(2.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, color = effectiveTint)
    }
}

@Composable
private fun ReadStatusCornerBadge(
    book: BookItem,
    eInkMode: Boolean,
    modifier: Modifier = Modifier
) {
    when {
        book.isMarkedOrFinishedRead -> {
            Surface(
                color = if (eInkMode) Color.Black else Color(0xE615803D),
                shape = RoundedCornerShape(topStart = 6.dp),
                modifier = modifier
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.CheckCircle,
                        contentDescription = "已讀",
                        tint = Color.White,
                        modifier = Modifier.size(12.dp)
                    )
                    Text(
                        text = "已讀",
                        color = Color.White,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        }
        book.isInProgress -> {
            Surface(
                color = if (eInkMode) Color.White else Color.Black.copy(alpha = 0.76f),
                border = if (eInkMode) BorderStroke(1.dp, Color.Black) else null,
                shape = RoundedCornerShape(topStart = 6.dp),
                modifier = modifier
            ) {
                Text(
                    text = "${book.displayProgressPercent}%",
                    color = if (eInkMode) Color.Black else Color.White,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BookGridCard(
    book: BookItem,
    coverSize: ShelfCoverSize,
    eInkMode: Boolean,
    isSelectionMode: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onMoreClick: () -> Unit
) {
    val border = when {
        isSelected && eInkMode -> BorderStroke(3.dp, Color.Black)
        isSelected -> BorderStroke(2.5.dp, MaterialTheme.colorScheme.primary)
        eInkMode -> BorderStroke(1.dp, Color.Black)
        else -> null
    }
    val cornerRadius = when (coverSize) {
        ShelfCoverSize.COMPACT, ShelfCoverSize.STANDARD -> 6.dp
        ShelfCoverSize.MEDIUM -> 8.dp
        ShelfCoverSize.LARGE -> 10.dp
        ShelfCoverSize.EXTRA_LARGE -> 12.dp
    }
    val titleStyle = when (coverSize) {
        ShelfCoverSize.COMPACT -> MaterialTheme.typography.bodySmall
        ShelfCoverSize.STANDARD, ShelfCoverSize.MEDIUM -> MaterialTheme.typography.bodyMedium
        ShelfCoverSize.LARGE, ShelfCoverSize.EXTRA_LARGE -> MaterialTheme.typography.titleSmall
    }
    val authorStyle = when (coverSize) {
        ShelfCoverSize.LARGE, ShelfCoverSize.EXTRA_LARGE -> MaterialTheme.typography.bodySmall
        else -> MaterialTheme.typography.labelSmall
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cornerRadius))
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(0.70f),
            shape = RoundedCornerShape(cornerRadius),
            border = border,
            tonalElevation = if (eInkMode) 0.dp else 2.dp,
            color = if (eInkMode) Color.White else Color(0xFF2B3440)
        ) {
            Box(Modifier.fillMaxSize()) {
                BookCoverVisual(book = book, eInkMode = eInkMode)

                if (isSelected && !eInkMode) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.22f))
                    )
                }

                Surface(
                    color = Color.Black.copy(alpha = 0.72f),
                    shape = RoundedCornerShape(bottomEnd = 6.dp),
                    modifier = Modifier.align(Alignment.TopStart)
                ) {
                    Text(
                        text = if (book.contentType == BookContentType.COMIC && book.format in setOf(BookFormat.EPUB, BookFormat.MOBI, BookFormat.AZW3)) "${book.format.label}·漫" else book.format.label,
                        color = Color.White,
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }

                ReadStatusCornerBadge(
                    book = book,
                    eInkMode = eInkMode,
                    modifier = Modifier.align(Alignment.BottomEnd)
                )

                if (isSelectionMode) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(5.dp)
                            .size(24.dp)
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.92f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = if (isSelected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                            contentDescription = if (isSelected) "已選取" else "未選取",
                            tint = when {
                                isSelected && eInkMode -> Color.Black
                                isSelected -> MaterialTheme.colorScheme.primary
                                else -> Color.Gray
                            },
                            modifier = Modifier.size(22.dp)
                        )
                    }
                } else {
                    IconButton(
                        onClick = onMoreClick,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .size(28.dp)
                    ) {
                        Icon(
                            Icons.Default.MoreVert,
                            contentDescription = "管理",
                            tint = if (eInkMode && book.coverPath == null) Color.Black else Color.White,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = book.title,
            style = titleStyle,
            fontWeight = FontWeight.Medium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            color = if (eInkMode) Color.Black else MaterialTheme.colorScheme.onBackground
        )
        Text(
            text = book.author.ifBlank { "未知作者" },
            style = authorStyle,
            color = if (eInkMode) Color.DarkGray else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BookListRow(
    book: BookItem,
    eInkMode: Boolean,
    isSelectionMode: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onMoreClick: () -> Unit
) {
    val containerColor = when {
        isSelected && eInkMode -> Color(0xFFEEEEEE)
        isSelected -> MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f)
        eInkMode -> Color.White
        else -> MaterialTheme.colorScheme.surface
    }
    val borderColor = when {
        isSelected && eInkMode -> Color.Black
        isSelected -> MaterialTheme.colorScheme.primary
        eInkMode -> Color.Black
        else -> MaterialTheme.colorScheme.outlineVariant
    }

    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            ),
        colors = CardDefaults.outlinedCardColors(containerColor = containerColor),
        border = BorderStroke(if (isSelected) 2.dp else 1.dp, borderColor)
    ) {
        Row(
            modifier = Modifier.padding(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (isSelectionMode) {
                Icon(
                    imageVector = if (isSelected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                    contentDescription = if (isSelected) "已選取" else "未選取",
                    tint = when {
                        isSelected && eInkMode -> Color.Black
                        isSelected -> MaterialTheme.colorScheme.primary
                        else -> Color.Gray
                    },
                    modifier = Modifier
                        .padding(end = 10.dp)
                        .size(24.dp)
                )
            }
            Box(
                modifier = Modifier
                    .width(48.dp)
                    .height(66.dp)
                    .clip(RoundedCornerShape(4.dp))
            ) {
                BookCoverVisual(book = book, eInkMode = eInkMode)
                if (book.isMarkedOrFinishedRead) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .clip(RoundedCornerShape(topStart = 4.dp))
                            .background(if (eInkMode) Color.Black else Color(0xE615803D))
                            .padding(2.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.CheckCircle,
                            contentDescription = "已讀",
                            tint = Color.White,
                            modifier = Modifier.size(12.dp)
                        )
                    }
                } else if (book.isInProgress) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .clip(RoundedCornerShape(topStart = 4.dp))
                            .background(if (eInkMode) Color.Black else Color.Black.copy(alpha = 0.78f))
                            .padding(horizontal = 3.dp, vertical = 1.dp)
                    ) {
                        Text(
                            text = "${book.displayProgressPercent}%",
                            color = Color.White,
                            style = MaterialTheme.typography.labelSmall
                        )
                    }
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = book.title,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = if (eInkMode) Color.Black else MaterialTheme.colorScheme.onSurface
                )
                Spacer(Modifier.height(2.dp))
                val tagsSuffix = if (book.tags.isNotEmpty()) " · " + book.tags.joinToString(" ") { "#$it" } else ""
                Text(
                    text = "${book.author.ifBlank { "未知作者" }} · ${book.format.label}$tagsSuffix",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (eInkMode) Color.DarkGray else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (book.isMarkedOrFinishedRead) {
                Surface(
                    color = if (eInkMode) Color.Black else Color(0xFFDCFCE7),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.padding(end = 4.dp)
                ) {
                    Text(
                        text = "已讀",
                        color = if (eInkMode) Color.White else Color(0xFF166534),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                    )
                }
            } else if (book.isInProgress) {
                Surface(
                    color = if (eInkMode) Color(0xFFEEEEEE) else MaterialTheme.colorScheme.secondaryContainer,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.padding(end = 4.dp)
                ) {
                    Text(
                        text = "${book.displayProgressPercent}%",
                        color = if (eInkMode) Color.Black else MaterialTheme.colorScheme.onSecondaryContainer,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                    )
                }
            }
            if (!isSelectionMode) {
                IconButton(onClick = onMoreClick) {
                    Icon(Icons.Default.MoreVert, contentDescription = "管理")
                }
            }
        }
    }
}

@Composable
private fun BookCoverVisual(book: BookItem, eInkMode: Boolean) {
    val coverBitmap = remember(book.coverPath) {
        book.coverPath?.takeIf { File(it).exists() }?.let { path ->
            runCatching { BitmapFactory.decodeFile(path)?.asImageBitmap() }.getOrNull()
        }
    }

    if (coverBitmap != null) {
        Image(
            bitmap = coverBitmap,
            contentDescription = book.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize()
        )
    } else {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(if (eInkMode) Color.White else Color(0xFF334155))
                .padding(8.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = book.title,
                color = if (eInkMode) Color.Black else Color(0xFFF8FAFC),
                style = MaterialTheme.typography.labelMedium,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}
