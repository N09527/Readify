package com.inkflow.reader.parser

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.inkflow.reader.model.BookContentType
import com.inkflow.reader.model.Chapter
import com.inkflow.reader.model.ParsedBook
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.ByteArrayOutputStream
import java.io.File

object PdfTextReflowParser {

    fun parseMetadataAndCover(file: File, fallbackTitle: String): ParsedBook {
        val coverBytes = renderFirstPageCover(file)
        return ParsedBook(
            title = fallbackTitle,
            author = "PDF 文件",
            chapters = emptyList(),
            coverBytes = coverBytes,
            contentType = BookContentType.PDF
        )
    }

    fun extractReflowChapters(file: File, fallbackTitle: String): ParsedBook {
        return runCatching {
            PDDocument.load(file).use { doc ->
                val totalPages = doc.numberOfPages
                if (totalPages <= 0) {
                    return ParsedBook(fallbackTitle, "PDF 文件", listOf(Chapter(0, fallbackTitle, "（此 PDF 沒有頁面）")), contentType = BookContentType.PDF)
                }

                val stripper = PDFTextStripper().apply {
                    sortByPosition = true
                    lineSeparator = "\n"
                }

                val chapters = mutableListOf<Chapter>()
                val pagesPerChunk = 10
                var startP = 1
                while (startP <= totalPages) {
                    val endP = (startP + pagesPerChunk - 1).coerceAtMost(totalPages)
                    stripper.startPage = startP
                    stripper.endPage = endP
                    val raw = runCatching { stripper.getText(doc) }.getOrDefault("")
                    val cleaned = cleanReflowText(raw)
                    if (cleaned.isNotBlank()) {
                        val title = if (startP == endP) "第 $startP 頁" else "第 $startP – $endP 頁"
                        chapters.add(
                            Chapter(
                                index = chapters.size,
                                title = title,
                                content = cleaned
                            )
                        )
                    }
                    startP = endP + 1
                }

                if (chapters.isEmpty()) {
                    chapters.add(
                        Chapter(
                            0,
                            fallbackTitle,
                            "此 PDF 偵測不到內嵌文字（可能為純圖片掃描版 PDF）。請切回「原版面」並搭配「自動裁邊」模式閱讀。"
                        )
                    )
                }

                ParsedBook(
                    title = doc.documentInformation?.title?.takeIf { it.isNotBlank() } ?: fallbackTitle,
                    author = doc.documentInformation?.author?.takeIf { it.isNotBlank() } ?: "PDF 文件",
                    chapters = chapters,
                    contentType = BookContentType.PDF
                )
            }
        }.getOrElse { err ->
            ParsedBook(
                title = fallbackTitle,
                author = "PDF 文件",
                chapters = listOf(Chapter(0, fallbackTitle, "PDF 文字重排擷取失敗：${err.message}\n請切回原版面閱讀。")),
                contentType = BookContentType.PDF
            )
        }
    }

    private fun cleanReflowText(raw: String): String {
        val lines = raw.replace("\r\n", "\n").replace("\r", "\n")
            .split("\n")
            .map { it.trim() }
            .filter { it.isNotEmpty() }

        if (lines.isEmpty()) return ""
        val paragraphs = mutableListOf<String>()
        val sb = StringBuilder()
        val sentenceEnders = setOf('。', '！', '？', '」', '』', '”', '）', '.', '!', '?', ':', '：')

        for (line in lines) {
            if (sb.isEmpty()) {
                sb.append(line)
                continue
            }
            val prevLast = sb[sb.length - 1]
            val startsNewIndent = line.startsWith("　") || (line.startsWith("第") && line.length < 28)
            if (prevLast in sentenceEnders || startsNewIndent) {
                paragraphs.add(sb.toString())
                sb.clear()
                sb.append(line)
            } else {
                val needSpace = prevLast.code < 128 && line[0].code < 128
                if (needSpace) sb.append(' ')
                sb.append(line)
            }
        }
        if (sb.isNotEmpty()) paragraphs.add(sb.toString())
        return paragraphs.joinToString("\n")
    }

    private fun renderFirstPageCover(file: File): ByteArray? {
        return runCatching {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
                PdfRenderer(pfd).use { renderer ->
                    if (renderer.pageCount <= 0) return@use null
                    renderer.openPage(0).use { page ->
                        val scale = 360f / page.width.coerceAtLeast(1)
                        val w = (page.width * scale).toInt().coerceIn(120, 480)
                        val h = (page.height * scale).toInt().coerceIn(160, 720)
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        bmp.eraseColor(Color.WHITE)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.JPEG, 82, out)
                        bmp.recycle()
                        out.toByteArray()
                    }
                }
            }
        }.getOrNull()
    }
}
