package com.inkflow.reader.parser

import com.inkflow.reader.model.BookContentType
import com.inkflow.reader.model.BookFormat
import com.inkflow.reader.model.Chapter
import com.inkflow.reader.model.ParsedBook
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.jsoup.parser.Parser
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

data class EpubComicInfo(
    val isComic: Boolean,
    val imagePaths: List<String>,
    val isRtl: Boolean,
    val title: String,
    val author: String,
    val coverBytes: ByteArray?
)

object BookParser {

    private val CHAPTER_REGEX = Regex(
        pattern = "^[\\s　]*((第[零〇一二三四五六七八九十百千萬两兩0-9]{1,7}[章回節节卷部集篇幕].*)|((Chapter|CHAPTER|Part|PART)\\s+[0-9IVXLC]+.*)|(序章|楔子|前言|後記|后记|尾聲|尾声|番外).*)$"
    )

    private val SELF_CLOSING_RAW_TAG_REGEX = Regex(
        pattern = "<(script|style|title|textarea)(\\b[^>]*?)/>",
        option = RegexOption.IGNORE_CASE
    )

    private val SKIP_TAGS = setOf("script", "style", "noscript", "head", "title", "rp", "rt")

    private val BLOCK_TAGS = setOf(
        "p", "div", "section", "article", "main", "aside", "header", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "ul", "ol", "dl", "dt", "dd",
        "blockquote", "pre", "figure", "figcaption",
        "table", "tr", "hr", "address"
    )

    fun parseMetadataAndCover(file: File, format: BookFormat, fallbackTitle: String): ParsedBook {
        return when (format) {
            BookFormat.TXT -> ParsedBook(
                title = fallbackTitle,
                author = "本機 TXT",
                chapters = emptyList(),
                coverBytes = null,
                contentType = BookContentType.TEXT
            )
            BookFormat.EPUB -> {
                val comicInfo = inspectEpubComic(file, fallbackTitle)
                ParsedBook(
                    title = comicInfo.title,
                    author = comicInfo.author,
                    chapters = emptyList(),
                    coverBytes = comicInfo.coverBytes,
                    contentType = if (comicInfo.isComic) BookContentType.COMIC else BookContentType.TEXT
                )
            }
            BookFormat.PDF -> PdfTextReflowParser.parseMetadataAndCover(file, fallbackTitle)
            BookFormat.CBZ, BookFormat.ZIP -> {
                val cover = VisualBookSourceFactory.extractZipComicCover(file)
                ParsedBook(
                    title = fallbackTitle,
                    author = "${format.label} 漫畫",
                    chapters = emptyList(),
                    coverBytes = cover,
                    contentType = BookContentType.COMIC
                )
            }
            BookFormat.CBR -> {
                val cover = VisualBookSourceFactory.extractRarComicCover(file)
                ParsedBook(
                    title = fallbackTitle,
                    author = "CBR 漫畫",
                    chapters = emptyList(),
                    coverBytes = cover,
                    contentType = BookContentType.COMIC
                )
            }
            BookFormat.MOBI, BookFormat.AZW3 -> MobiAzw3Parser.parseMetadataAndCover(file, fallbackTitle)
        }
    }

    fun parseFullBook(file: File, format: BookFormat, fallbackTitle: String): ParsedBook {
        return when (format) {
            BookFormat.TXT -> parseTxt(file, fallbackTitle)
            BookFormat.EPUB -> parseEpub(file, fallbackTitle)
            BookFormat.PDF -> PdfTextReflowParser.extractReflowChapters(file, fallbackTitle)
            BookFormat.MOBI, BookFormat.AZW3 -> MobiAzw3Parser.parseFullBook(file, fallbackTitle)
            BookFormat.CBZ, BookFormat.CBR, BookFormat.ZIP -> ParsedBook(
                title = fallbackTitle,
                author = "漫畫壓縮檔",
                chapters = emptyList(),
                contentType = BookContentType.COMIC
            )
        }
    }

    private fun parseTxt(file: File, fallbackTitle: String): ParsedBook {
        val rawBytes = file.readBytes()
        val text = decodeBytesSmart(rawBytes)
            .replace("\r\n", "\n")
            .replace("\r", "\n")
        val chapters = splitPlainTextIntoChapters(text, fallbackTitle)
        return ParsedBook(
            title = fallbackTitle,
            author = "本機 TXT",
            chapters = chapters,
            contentType = BookContentType.TEXT
        )
    }

    internal fun splitPlainTextIntoChapters(text: String, fallbackTitle: String): List<Chapter> {
        val lines = text.split("\n")
        val chapters = mutableListOf<Chapter>()
        var currentTitle = "開始閱讀"
        val buffer = StringBuilder()

        fun flushChapter() {
            val content = buffer.toString().trim()
            if (content.isNotEmpty()) {
                chapters.add(Chapter(index = chapters.size, title = currentTitle, content = content))
            }
            buffer.clear()
        }

        for (line in lines) {
            val trimmed = line.trim()
            if (trimmed.length in 2..45 && CHAPTER_REGEX.matches(trimmed)) {
                if (buffer.isNotBlank()) flushChapter()
                currentTitle = trimmed
            } else if (trimmed.isNotEmpty()) {
                buffer.append(trimmed).append("\n")
            }
        }
        flushChapter()

        if (chapters.size <= 1) {
            val fullText = chapters.firstOrNull()?.content ?: text.trim()
            if (fullText.length > 12000) {
                chapters.clear()
                val chunkSize = 8000
                var start = 0
                var partIdx = 1
                while (start < fullText.length) {
                    var end = (start + chunkSize).coerceAtMost(fullText.length)
                    if (end < fullText.length) {
                        val nl = fullText.indexOf('\n', end)
                        if (nl in end..(end + 400)) end = nl + 1
                    }
                    chapters.add(Chapter(index = chapters.size, title = "第 $partIdx 節", content = fullText.substring(start, end).trim()))
                    start = end
                    partIdx++
                }
            } else if (chapters.isEmpty()) {
                chapters.add(Chapter(0, fallbackTitle, fullText.ifBlank { "（空白檔案）" }))
            }
        }
        return chapters
    }

    private fun decodeBytesSmart(bytes: ByteArray): String {
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
            return String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
        }
        if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) {
            return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
        }
        if (bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()) {
            return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
        }

        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        try {
            return decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            val candidates = listOf("Big5", "GB18030", "GBK")
            for (name in candidates) {
                if (Charset.isSupported(name)) {
                    val cs = Charset.forName(name)
                    val strict = cs.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                    try {
                        return strict.decode(ByteBuffer.wrap(bytes)).toString()
                    } catch (_: CharacterCodingException) {
                        // Try next charset
                    }
                }
            }
            return String(bytes, Charsets.UTF_8)
        }
    }

    fun inspectEpubComic(file: File, fallbackTitle: String): EpubComicInfo {
        return runCatching {
            ZipFile(file).use { zip ->
                val entryIndex = buildZipEntryIndex(zip)
                val containerEntry = findZipEntry(zip, entryIndex, "META-INF/container.xml")
                    ?: return EpubComicInfo(false, emptyList(), true, fallbackTitle, "未知作者", null)

                val containerDoc = Jsoup.parse(readEntryText(zip, containerEntry), "", Parser.xmlParser())
                val opfPathRaw = containerDoc.selectFirst("rootfile, *|rootfile")?.attr("full-path")
                    ?: return EpubComicInfo(false, emptyList(), true, fallbackTitle, "未知作者", null)

                val opfPath = normalizeZipPath(opfPathRaw)
                val opfDir = opfPath.substringBeforeLast('/', "")
                val opfEntry = findZipEntry(zip, entryIndex, opfPath)
                    ?: return EpubComicInfo(false, emptyList(), true, fallbackTitle, "未知作者", null)

                val opfDoc = Jsoup.parse(readEntryText(zip, opfEntry), "", Parser.xmlParser())
                val title = opfDoc.selectFirst("dc|title, *|title, title")?.text()?.trim().orEmpty().ifBlank { fallbackTitle }
                val author = opfDoc.selectFirst("dc|creator, *|creator, creator")?.text()?.trim().orEmpty().ifBlank { "未知作者" }

                val manifestHref = mutableMapOf<String, String>()
                val manifestProperties = mutableMapOf<String, String>()
                val manifestMediaType = mutableMapOf<String, String>()
                for (item in opfDoc.select("manifest > item, *|manifest > *|item, item[id][href]")) {
                    val id = item.attr("id")
                    val href = item.attr("href")
                    if (id.isNotBlank() && href.isNotBlank()) {
                        manifestHref.putIfAbsent(id, href)
                        manifestProperties.putIfAbsent(id, item.attr("properties"))
                        manifestMediaType.putIfAbsent(id, item.attr("media-type"))
                    }
                }

                val spineEl = opfDoc.selectFirst("spine, *|spine")
                val pageProgression = spineEl?.attr("page-progression-direction").orEmpty().lowercase()
                val isRtl = pageProgression != "ltr"

                val isPrePaginated = opfDoc.select("meta, *|meta").any { meta ->
                    meta.attr("property").equals("rendition:layout", ignoreCase = true) &&
                        meta.text().trim().equals("pre-paginated", ignoreCase = true)
                } || opfDoc.select("meta[name=fixed-layout], *|meta[name=fixed-layout]").any {
                    it.attr("content").equals("true", ignoreCase = true)
                }

                val spineItems = opfDoc.select("spine > itemref, *|spine > *|itemref, itemref[idref]")
                val orderedImages = LinkedHashSet<String>()
                var imageOnlySpineCount = 0
                var totalTextChars = 0

                for (itemRef in spineItems) {
                    val idRef = itemRef.attr("idref")
                    val rawHref = manifestHref[idRef] ?: continue
                    val cleanHref = rawHref.substringBefore('#')
                    val fullPath = resolveZipPath(opfDir, cleanHref)
                    val mediaType = manifestMediaType[idRef].orEmpty().lowercase()

                    if (mediaType.startsWith("image/") || NaturalSort.isSupportedImageName(fullPath)) {
                        findZipEntry(zip, entryIndex, fullPath)?.let {
                            orderedImages.add(it.name)
                            imageOnlySpineCount++
                        }
                        continue
                    }

                    val entry = findZipEntry(zip, entryIndex, fullPath) ?: continue
                    val doc = parseXhtmlSafely(readEntryText(zip, entry))
                    val xhtmlDir = fullPath.substringBeforeLast('/', "")

                    val pageImgs = extractImageRefsFromXhtml(doc, xhtmlDir, zip, entryIndex)
                    val textLen = extractReadableText(doc).length
                    totalTextChars += textLen

                    if (pageImgs.isNotEmpty()) {
                        orderedImages.addAll(pageImgs)
                        if (textLen < 45) {
                            imageOnlySpineCount++
                        }
                    }
                }

                if (orderedImages.isEmpty() && (isPrePaginated || totalTextChars < 120)) {
                    val allZipImgs = entryIndex.values.distinctBy { it.name }
                        .map { it.name }
                        .filter { NaturalSort.isSupportedImageName(it) }
                        .sortedWith(NaturalSort.COMPARATOR)
                    orderedImages.addAll(allZipImgs)
                }

                val imgList = orderedImages.toList()
                val spineCount = spineItems.size.coerceAtLeast(1)
                val isComic = imgList.size >= 2 && (
                    isPrePaginated ||
                        totalTextChars < 300 ||
                        (imageOnlySpineCount.toFloat() / spineCount.toFloat() >= 0.55f && imgList.size >= 4)
                    )

                var coverBytes = extractCoverBytes(zip, entryIndex, opfDoc, opfDir, manifestHref, manifestProperties, manifestMediaType)
                if (coverBytes == null && imgList.isNotEmpty()) {
                    coverBytes = zip.getEntry(imgList.first())?.let { e ->
                        runCatching { zip.getInputStream(e).use { it.readBytes() } }.getOrNull()
                    }
                }

                EpubComicInfo(
                    isComic = isComic,
                    imagePaths = imgList,
                    isRtl = isRtl,
                    title = title,
                    author = author,
                    coverBytes = coverBytes
                )
            }
        }.getOrElse {
            EpubComicInfo(false, emptyList(), true, fallbackTitle, "未知作者", null)
        }
    }

    private fun extractImageRefsFromXhtml(
        doc: org.jsoup.nodes.Document,
        xhtmlDir: String,
        zip: ZipFile,
        entryIndex: Map<String, ZipEntry>
    ): List<String> {
        val found = mutableListOf<String>()
        for (img in doc.select("img[src]")) {
            val src = img.attr("src").substringBefore('#').trim()
            if (src.isBlank() || src.startsWith("data:") || src.startsWith("http")) continue
            val resolved = resolveZipPath(xhtmlDir, src)
            findZipEntry(zip, entryIndex, resolved)?.let { found.add(it.name) }
        }
        for (svgImg in doc.select("image, *|image")) {
            val href = svgImg.attr("xlink:href")
                .ifBlank { svgImg.attr("href") }
                .ifBlank { svgImg.attr("l:href") }
                .substringBefore('#')
                .trim()
            if (href.isBlank() || href.startsWith("data:") || href.startsWith("http")) continue
            val resolved = resolveZipPath(xhtmlDir, href)
            findZipEntry(zip, entryIndex, resolved)?.let { found.add(it.name) }
        }
        return found
    }

    private fun parseEpub(file: File, fallbackTitle: String): ParsedBook {
        ZipFile(file).use { zip ->
            val entryIndex = buildZipEntryIndex(zip)

            val containerEntry = findZipEntry(zip, entryIndex, "META-INF/container.xml")
                ?: return ParsedBook(fallbackTitle, "未知作者", listOf(Chapter(0, fallbackTitle, "無法解析 EPUB：缺少 META-INF/container.xml")))

            val containerDoc = Jsoup.parse(readEntryText(zip, containerEntry), "", Parser.xmlParser())
            val opfPathRaw = containerDoc.selectFirst("rootfile, *|rootfile")?.attr("full-path")
                ?: return ParsedBook(fallbackTitle, "未知作者", listOf(Chapter(0, fallbackTitle, "無法解析 EPUB：找不到 OPF 路徑")))

            val opfPath = normalizeZipPath(opfPathRaw)
            val opfDir = opfPath.substringBeforeLast('/', "")
            val opfEntry = findZipEntry(zip, entryIndex, opfPath)
                ?: return ParsedBook(fallbackTitle, "未知作者", listOf(Chapter(0, fallbackTitle, "無法解析 EPUB：OPF 檔案不存在 ($opfPath)")))

            val opfDoc = Jsoup.parse(readEntryText(zip, opfEntry), "", Parser.xmlParser())
            val title = opfDoc.selectFirst("dc|title, *|title, title")?.text()?.trim().orEmpty().ifBlank { fallbackTitle }
            val author = opfDoc.selectFirst("dc|creator, *|creator, creator")?.text()?.trim().orEmpty().ifBlank { "未知作者" }

            val manifestHref = mutableMapOf<String, String>()
            val manifestProperties = mutableMapOf<String, String>()
            val manifestMediaType = mutableMapOf<String, String>()
            for (item in opfDoc.select("manifest > item, *|manifest > *|item, item[id][href]")) {
                val id = item.attr("id")
                val href = item.attr("href")
                if (id.isNotBlank() && href.isNotBlank()) {
                    manifestHref.putIfAbsent(id, href)
                    manifestProperties.putIfAbsent(id, item.attr("properties"))
                    manifestMediaType.putIfAbsent(id, item.attr("media-type"))
                }
            }

            val coverBytes = extractCoverBytes(zip, entryIndex, opfDoc, opfDir, manifestHref, manifestProperties, manifestMediaType)
            val drmEncryptedPaths = detectDrmEncryptedPaths(zip, entryIndex)
            val tocTitleMap = extractTocTitles(zip, entryIndex, opfDoc, opfDir, manifestHref, manifestProperties)

            val chapters = mutableListOf<Chapter>()
            val spineItems = opfDoc.select("spine > itemref, *|spine > *|itemref, itemref[idref]")
            var skippedDrmCount = 0

            for (itemRef in spineItems) {
                val idRef = itemRef.attr("idref")
                val rawHref = manifestHref[idRef] ?: continue
                val cleanHref = rawHref.substringBefore('#')
                val fullPath = resolveZipPath(opfDir, cleanHref)

                if (fullPath.lowercase() in drmEncryptedPaths) {
                    skippedDrmCount++
                    continue
                }

                val entry = findZipEntry(zip, entryIndex, fullPath) ?: continue
                val doc = parseXhtmlSafely(readEntryText(zip, entry))

                val headingInDoc = doc.selectFirst("h1, h2, h3, title")?.text()?.trim().orEmpty()
                val chapterTitle = tocTitleMap[cleanHref]
                    ?: tocTitleMap[decodePercentPath(cleanHref)]
                    ?: tocTitleMap[cleanHref.substringAfterLast('/')]
                    ?: tocTitleMap[decodePercentPath(cleanHref).substringAfterLast('/')]
                    ?: headingInDoc.takeIf { it.isNotBlank() && it.length <= 60 }
                    ?: "第 ${chapters.size + 1} 章"

                val extractedBody = extractReadableText(doc)
                if (extractedBody.isBlank()) continue

                val cleanedContent = removeLeadingDuplicateTitle(extractedBody, chapterTitle)
                chapters.add(Chapter(index = chapters.size, title = chapterTitle, content = cleanedContent.ifBlank { extractedBody }))
            }

            if (chapters.isEmpty()) {
                val fallbackMsg = if (skippedDrmCount > 0) {
                    "此 EPUB 檔案受 DRM 加密保護，無法直接讀取內文。請匯入無 DRM 的 EPUB 檔案。"
                } else {
                    "此 EPUB 未偵測到可讀取的文字章節。若為漫畫 EPUB，可於書架點擊該書右上角選單切換為「漫畫模式」。"
                }
                chapters.add(Chapter(0, title, fallbackMsg))
            }

            return ParsedBook(title = title, author = author, chapters = chapters, coverBytes = coverBytes, contentType = BookContentType.TEXT)
        }
    }

    private fun parseXhtmlSafely(rawHtml: String): org.jsoup.nodes.Document {
        val sanitized = SELF_CLOSING_RAW_TAG_REGEX.replace(rawHtml) { m ->
            "<${m.groupValues[1]}${m.groupValues[2]}></${m.groupValues[1]}>"
        }
        val htmlDoc = Jsoup.parse(sanitized)
        val bodyText = htmlDoc.body()?.text()?.trim().orEmpty()
        if (bodyText.isNotEmpty() || htmlDoc.select("img, image, *|image").isNotEmpty()) {
            return htmlDoc
        }
        return Jsoup.parse(rawHtml, "", Parser.xmlParser())
    }

    internal fun extractReadableText(doc: org.jsoup.nodes.Document): String {
        val root: Element = doc.body() ?: doc.selectFirst("body, *|body") ?: doc
        val sb = StringBuilder()
        walkNode(root, sb, inPre = false)
        return sb.toString()
            .split("\n")
            .map { line -> line.trim { it.isWhitespace() || it == '\u3000' } }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
    }

    private fun walkNode(node: Node, sb: StringBuilder, inPre: Boolean) {
        when (node) {
            is TextNode -> {
                val text = if (inPre) node.wholeText else node.text()
                if (text.isEmpty()) return
                if (inPre) {
                    sb.append(text)
                } else if (text.isBlank()) {
                    if (sb.isNotEmpty()) {
                        val last = sb[sb.length - 1]
                        if (last != '\n' && last != ' ' && last != '\u3000') sb.append(' ')
                    }
                } else {
                    sb.append(text)
                }
            }
            is Element -> {
                val tag = node.tagName().substringAfterLast(':').lowercase()
                if (tag in SKIP_TAGS) return
                if (tag == "br") {
                    sb.append('\n')
                    return
                }
                val isBlock = tag in BLOCK_TAGS
                val nextInPre = inPre || tag == "pre"
                if (isBlock) ensureNewline(sb)
                for (child in node.childNodes()) walkNode(child, sb, nextInPre)
                if (isBlock) ensureNewline(sb)
            }
        }
    }

    private fun ensureNewline(sb: StringBuilder) {
        if (sb.isNotEmpty() && sb[sb.length - 1] != '\n') sb.append('\n')
    }

    private fun removeLeadingDuplicateTitle(body: String, chapterTitle: String): String {
        val lines = body.split("\n")
        if (lines.size <= 1) return body
        val firstNorm = lines.first().replace(Regex("[\\s　]+"), "")
        val titleNorm = chapterTitle.replace(Regex("[\\s　]+"), "")
        return if (firstNorm.isNotEmpty() && firstNorm == titleNorm) lines.drop(1).joinToString("\n") else body
    }

    private fun detectDrmEncryptedPaths(zip: ZipFile, entryIndex: Map<String, ZipEntry>): Set<String> {
        val encEntry = findZipEntry(zip, entryIndex, "META-INF/encryption.xml") ?: return emptySet()
        val xml = runCatching { readEntryText(zip, encEntry) }.getOrNull() ?: return emptySet()
        val doc = Jsoup.parse(xml, "", Parser.xmlParser())
        val result = mutableSetOf<String>()
        for (encData in doc.select("EncryptedData, *|EncryptedData")) {
            val algo = encData.selectFirst("EncryptionMethod, *|EncryptionMethod")?.attr("Algorithm").orEmpty()
            if (algo.contains("embedding", ignoreCase = true) || algo.contains("adobe.com/pdf/enc", ignoreCase = true)) continue
            val uri = encData.selectFirst("CipherReference, *|CipherReference")?.attr("URI").orEmpty()
            if (uri.isNotBlank()) result.add(normalizeZipPath(uri).lowercase())
        }
        return result
    }

    private fun extractCoverBytes(
        zip: ZipFile,
        entryIndex: Map<String, ZipEntry>,
        opfDoc: org.jsoup.nodes.Document,
        opfDir: String,
        manifestHref: Map<String, String>,
        manifestProperties: Map<String, String>,
        manifestMediaType: Map<String, String>
    ): ByteArray? {
        var coverId = manifestProperties.entries.firstOrNull { it.value.contains("cover-image") }?.key
        if (coverId == null) coverId = opfDoc.selectFirst("meta[name=cover], *|meta[name=cover]")?.attr("content")
        if (coverId == null) {
            coverId = manifestHref.entries.firstOrNull { (id, href) ->
                (id.contains("cover", ignoreCase = true) || href.contains("cover", ignoreCase = true)) &&
                    manifestMediaType[id]?.startsWith("image/") == true
            }?.key
        }
        val href = coverId?.let { manifestHref[it] } ?: return null
        val entry = findZipEntry(zip, entryIndex, resolveZipPath(opfDir, href)) ?: return null
        return runCatching { zip.getInputStream(entry).use { it.readBytes() } }.getOrNull()
    }

    private fun extractTocTitles(
        zip: ZipFile,
        entryIndex: Map<String, ZipEntry>,
        opfDoc: org.jsoup.nodes.Document,
        opfDir: String,
        manifestHref: Map<String, String>,
        manifestProperties: Map<String, String>
    ): Map<String, String> {
        val map = mutableMapOf<String, String>()
        val navId = manifestProperties.entries.firstOrNull { it.value.contains("nav") }?.key
        if (navId != null) {
            manifestHref[navId]?.let { navHref ->
                findZipEntry(zip, entryIndex, resolveZipPath(opfDir, navHref))?.let { entry ->
                    val navDoc = parseXhtmlSafely(readEntryText(zip, entry))
                    for (a in navDoc.select("nav a[href]")) {
                        val href = a.attr("href").substringBefore('#')
                        val label = a.text().trim()
                        if (href.isNotBlank() && label.isNotBlank()) {
                            map.putIfAbsent(href, label)
                            map.putIfAbsent(decodePercentPath(href), label)
                            map.putIfAbsent(href.substringAfterLast('/'), label)
                            map.putIfAbsent(decodePercentPath(href).substringAfterLast('/'), label)
                        }
                    }
                }
            }
        }
        val tocId = opfDoc.selectFirst("spine, *|spine")?.attr("toc")
        val ncxHref = tocId?.let { manifestHref[it] } ?: manifestHref.values.firstOrNull { it.endsWith(".ncx", ignoreCase = true) }
        if (ncxHref != null) {
            findZipEntry(zip, entryIndex, resolveZipPath(opfDir, ncxHref))?.let { entry ->
                val ncxDoc = Jsoup.parse(readEntryText(zip, entry), "", Parser.xmlParser())
                for (navPoint in ncxDoc.select("navPoint, *|navPoint")) {
                    val label = navPoint.selectFirst("navLabel > text, *|navLabel > *|text")?.text()?.trim().orEmpty()
                    val src = navPoint.selectFirst("content, *|content")?.attr("src")?.substringBefore('#').orEmpty()
                    if (label.isNotBlank() && src.isNotBlank()) {
                        map.putIfAbsent(src, label)
                        map.putIfAbsent(decodePercentPath(src), label)
                        map.putIfAbsent(src.substringAfterLast('/'), label)
                        map.putIfAbsent(decodePercentPath(src).substringAfterLast('/'), label)
                    }
                }
            }
        }
        return map
    }

    private fun buildZipEntryIndex(zip: ZipFile): Map<String, ZipEntry> {
        val index = mutableMapOf<String, ZipEntry>()
        val entries = zip.entries()
        while (entries.hasMoreElements()) {
            val entry = entries.nextElement()
            val norm = normalizeZipPath(entry.name)
            index[norm] = entry
            index.putIfAbsent(norm.lowercase(), entry)
        }
        return index
    }

    private fun findZipEntry(zip: ZipFile, index: Map<String, ZipEntry>, path: String): ZipEntry? {
        val norm = normalizeZipPath(path)
        return zip.getEntry(norm) ?: index[norm] ?: index[norm.lowercase()] ?: index[decodePercentPath(norm).lowercase()]
    }

    private fun readEntryText(zip: ZipFile, entry: ZipEntry): String = decodeBytesSmart(zip.getInputStream(entry).use { it.readBytes() })

    private fun normalizeZipPath(path: String): String = path.replace('\\', '/').removePrefix("./").removePrefix("/")

    private fun decodePercentPath(raw: String): String {
        val out = ByteArrayOutputStream(raw.length)
        var i = 0
        while (i < raw.length) {
            val c = raw[i]
            if (c == '%' && i + 2 < raw.length) {
                val byteVal = raw.substring(i + 1, i + 3).toIntOrNull(16)
                if (byteVal != null) {
                    out.write(byteVal)
                    i += 3
                    continue
                }
            }
            out.write(c.toString().toByteArray(Charsets.UTF_8))
            i++
        }
        return out.toString("UTF-8")
    }

    private fun resolveZipPath(baseDir: String, relativeHref: String): String {
        val decoded = decodePercentPath(relativeHref).replace('\\', '/')
        if (baseDir.isBlank()) return normalizeZipPath(decoded)
        val parts = (baseDir.split("/") + decoded.split("/")).filter { it.isNotEmpty() }
        val normalized = ArrayDeque<String>()
        for (p in parts) {
            when (p) {
                "." -> {}
                ".." -> if (normalized.isNotEmpty()) normalized.removeLast()
                else -> normalized.addLast(p)
            }
        }
        return normalized.joinToString("/")
    }
}
