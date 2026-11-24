package com.inkflow.reader.parser

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.inkflow.reader.model.BookFormat
import com.inkflow.reader.model.BookItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import net.sf.sevenzipjbinding.ISequentialOutStream
import net.sf.sevenzipjbinding.SevenZip
import net.sf.sevenzipjbinding.impl.RandomAccessFileInStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.zip.ZipFile

interface VisualBookSource {
    val pageCount: Int
    val defaultRtl: Boolean
    val isPdf: Boolean
    suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap?
    fun close()
}

object VisualBookSourceFactory {

    suspend fun open(context: Context, book: BookItem): VisualBookSource = withContext(Dispatchers.IO) {
        val file = File(book.localPath)
        when (book.format) {
            BookFormat.PDF -> PdfVisualSource(file)
            BookFormat.EPUB -> {
                val info = BookParser.inspectEpubComic(file, book.title)
                EpubComicSource(file, info.imagePaths, info.isRtl)
            }
            BookFormat.CBZ, BookFormat.ZIP -> ZipComicSource(file)
            BookFormat.CBR -> {
                runCatching {
                    val cacheDir = File(context.cacheDir, "cbr_cache/${book.id}")
                    RarComicSource(file, cacheDir)
                }.getOrElse {
                    ZipComicSource(file)
                }
            }
            BookFormat.MOBI, BookFormat.AZW3 -> {
                val idx = MobiAzw3Parser.getImageIndex(file)
                MobiComicSource(file, idx.imageRecordIndices)
            }
            BookFormat.TXT -> EmptyVisualSource
        }
    }

    fun extractZipComicCover(file: File): ByteArray? {
        return runCatching {
            ZipFile(file).use { zip ->
                val first = zip.entries().asSequence()
                    .filter { !it.isDirectory && NaturalSort.isSupportedImageName(it.name) }
                    .map { it.name }
                    .sortedWith(NaturalSort.COMPARATOR)
                    .firstOrNull() ?: return@use null
                val entry = zip.getEntry(first) ?: return@use null
                zip.getInputStream(entry).use { it.readBytes() }
            }
        }.getOrNull()
    }

    fun extractRarComicCover(file: File): ByteArray? {
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                SevenZip.openInArchive(null, RandomAccessFileInStream(raf)).use { inArchive ->
                    val simple = inArchive.simpleInterface
                    val items = simple.archiveItems
                        .filter { !it.isFolder && NaturalSort.isSupportedImageName(it.path.orEmpty()) }
                        .sortedWith(compareBy(NaturalSort.COMPARATOR) { it.path.orEmpty() })
                    val first = items.firstOrNull() ?: return@use null
                    val out = ByteArrayOutputStream()
                    first.extractSlow(object : ISequentialOutStream {
                        override fun write(data: ByteArray): Int {
                            out.write(data)
                            return data.size
                        }
                    })
                    out.toByteArray()
                }
            }
        }.getOrElse {
            extractZipComicCover(file)
        }
    }

    internal fun decodeSampledBitmap(bytes: ByteArray, targetMaxDim: Int): Bitmap? {
        if (bytes.isEmpty()) return null
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null

        var sample = 1
        val maxSide = maxOf(opts.outWidth, opts.outHeight)
        while (maxSide / (sample * 2) >= targetMaxDim.coerceAtLeast(600)) {
            sample *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOpts)
    }

    internal fun decodeSampledBitmap(file: File, targetMaxDim: Int): Bitmap? {
        if (!file.exists()) return null
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null

        var sample = 1
        val maxSide = maxOf(opts.outWidth, opts.outHeight)
        while (maxSide / (sample * 2) >= targetMaxDim.coerceAtLeast(600)) {
            sample *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(file.absolutePath, decodeOpts)
    }
}

private object EmptyVisualSource : VisualBookSource {
    override val pageCount: Int = 0
    override val defaultRtl: Boolean = true
    override val isPdf: Boolean = false
    override suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap? = null
    override fun close() {}
}

private class ZipComicSource(file: File) : VisualBookSource {
    private val zip = ZipFile(file)
    private val mutex = Mutex()
    private val imageNames: List<String> = zip.entries().asSequence()
        .filter { !it.isDirectory && NaturalSort.isSupportedImageName(it.name) }
        .map { it.name }
        .sortedWith(NaturalSort.COMPARATOR)
        .toList()

    override val pageCount: Int get() = imageNames.size
    override val defaultRtl: Boolean = true
    override val isPdf: Boolean = false

    override suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap? {
        if (pageIndex !in imageNames.indices) return null
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                val entry = zip.getEntry(imageNames[pageIndex]) ?: return@withLock null
                val bytes = zip.getInputStream(entry).use { it.readBytes() }
                VisualBookSourceFactory.decodeSampledBitmap(bytes, targetMaxDim)
            }
        }
    }

    override fun close() {
        runCatching { zip.close() }
    }
}

private class EpubComicSource(
    file: File,
    private val imagePaths: List<String>,
    override val defaultRtl: Boolean
) : VisualBookSource {
    private val zip = ZipFile(file)
    private val mutex = Mutex()

    override val pageCount: Int get() = imagePaths.size
    override val isPdf: Boolean = false

    override suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap? {
        if (pageIndex !in imagePaths.indices) return null
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                val entry = zip.getEntry(imagePaths[pageIndex]) ?: return@withLock null
                val bytes = zip.getInputStream(entry).use { it.readBytes() }
                VisualBookSourceFactory.decodeSampledBitmap(bytes, targetMaxDim)
            }
        }
    }

    override fun close() {
        runCatching { zip.close() }
    }
}

private class RarComicSource(file: File, cacheDir: File) : VisualBookSource {
    private val extractedFiles: List<File>

    init {
        cacheDir.mkdirs()
        val marker = File(cacheDir, ".extracted_ok")
        if (!marker.exists()) {
            cacheDir.listFiles()?.forEach { it.delete() }
            RandomAccessFile(file, "r").use { raf ->
                SevenZip.openInArchive(null, RandomAccessFileInStream(raf)).use { inArchive ->
                    val simple = inArchive.simpleInterface
                    val items = simple.archiveItems
                        .filter { !it.isFolder && NaturalSort.isSupportedImageName(it.path.orEmpty()) }
                        .sortedWith(compareBy(NaturalSort.COMPARATOR) { it.path.orEmpty() })

                    items.forEachIndexed { idx, item ->
                        val ext = item.path.orEmpty().substringAfterLast('.', "jpg").lowercase()
                        val outFile = File(cacheDir, "page_%05d.%s".format(idx, ext))
                        FileOutputStream(outFile).use { fos ->
                            item.extractSlow(object : ISequentialOutStream {
                                override fun write(data: ByteArray): Int {
                                    fos.write(data)
                                    return data.size
                                }
                            })
                        }
                    }
                }
            }
            marker.writeText("ok")
        }

        extractedFiles = cacheDir.listFiles()
            ?.filter { it.isFile && !it.name.startsWith(".") && NaturalSort.isSupportedImageName(it.name) }
            ?.sortedWith(compareBy(NaturalSort.COMPARATOR) { it.name })
            ?: emptyList()
    }

    override val pageCount: Int get() = extractedFiles.size
    override val defaultRtl: Boolean = true
    override val isPdf: Boolean = false

    override suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap? {
        if (pageIndex !in extractedFiles.indices) return null
        return withContext(Dispatchers.IO) {
            VisualBookSourceFactory.decodeSampledBitmap(extractedFiles[pageIndex], targetMaxDim)
        }
    }

    override fun close() {}
}

private class MobiComicSource(
    private val file: File,
    private val imageRecordIndices: List<Int>
) : VisualBookSource {

    override val pageCount: Int get() = imageRecordIndices.size
    override val defaultRtl: Boolean = true
    override val isPdf: Boolean = false

    override suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap? {
        if (pageIndex !in imageRecordIndices.indices) return null
        return withContext(Dispatchers.IO) {
            val bytes = MobiAzw3Parser.readImageRecordBytes(file, imageRecordIndices[pageIndex])
                ?: return@withContext null
            VisualBookSourceFactory.decodeSampledBitmap(bytes, targetMaxDim)
        }
    }

    override fun close() {}
}

private class PdfVisualSource(file: File) : VisualBookSource {
    private val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = PdfRenderer(pfd)
    private val mutex = Mutex()

    override val pageCount: Int get() = renderer.pageCount
    override val defaultRtl: Boolean = false
    override val isPdf: Boolean = true

    override suspend fun renderPage(pageIndex: Int, targetMaxDim: Int, autoCrop: Boolean): Bitmap? {
        if (pageIndex !in 0 until renderer.pageCount) return null
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                renderer.openPage(pageIndex).use { page ->
                    val pw = page.width.coerceAtLeast(1)
                    val ph = page.height.coerceAtLeast(1)

                    if (!autoCrop) {
                        val scale = targetMaxDim.toFloat() / maxOf(pw, ph).toFloat()
                        val bmpW = (pw * scale).toInt().coerceIn(200, 2400)
                        val bmpH = (ph * scale).toInt().coerceIn(200, 2400)
                        val bmp = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
                        bmp.eraseColor(Color.WHITE)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        return@withLock bmp
                    }

                    val probeScale = 360f / maxOf(pw, ph).toFloat()
                    val probeW = (pw * probeScale).toInt().coerceIn(80, 400)
                    val probeH = (ph * probeScale).toInt().coerceIn(80, 400)
                    val probeBmp = Bitmap.createBitmap(probeW, probeH, Bitmap.Config.ARGB_8888)
                    probeBmp.eraseColor(Color.WHITE)
                    page.render(probeBmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

                    val cropRatios = detectContentBounds(probeBmp)
                    probeBmp.recycle()

                    val cropLeftRatio = cropRatios[0]
                    val cropTopRatio = cropRatios[1]
                    val cropRightRatio = cropRatios[2]
                    val cropBottomRatio = cropRatios[3]

                    val croppedPdfW = pw * (cropRightRatio - cropLeftRatio)
                    val croppedPdfH = ph * (cropBottomRatio - cropTopRatio)

                    val renderScale = targetMaxDim.toFloat() / maxOf(croppedPdfW, croppedPdfH).coerceAtLeast(1f)
                    val outW = (croppedPdfW * renderScale).toInt().coerceIn(200, 2400)
                    val outH = (croppedPdfH * renderScale).toInt().coerceIn(200, 2400)

                    val outBmp = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
                    outBmp.eraseColor(Color.WHITE)

                    val matrix = Matrix().apply {
                        postTranslate(-pw * cropLeftRatio, -ph * cropTopRatio)
                        postScale(renderScale, renderScale)
                    }
                    page.render(outBmp, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    outBmp
                }
            }
        }
    }

    private fun detectContentBounds(bmp: Bitmap): FloatArray {
        val w = bmp.width
        val h = bmp.height
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)

        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1

        val borderX = (w * 0.01f).toInt()
        val borderY = (h * 0.01f).toInt()

        for (y in borderY until (h - borderY)) {
            val rowOff = y * w
            for (x in borderX until (w - borderX)) {
                val p = pixels[rowOff + x]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                if (r < 242 || g < 242 || b < 242) {
                    if (x < minX) minX = x
                    if (x > maxX) maxX = x
                    if (y < minY) minY = y
                    if (y > maxY) maxY = y
                }
            }
        }

        if (maxX <= minX || maxY <= minY) return floatArrayOf(0f, 0f, 1f, 1f)

        val padX = (w * 0.025f).toInt()
        val padY = (h * 0.025f).toInt()
        val left = ((minX - padX).coerceAtLeast(0)).toFloat() / w
        val top = ((minY - padY).coerceAtLeast(0)).toFloat() / h
        val right = ((maxX + padX).coerceAtMost(w)).toFloat() / w
        val bottom = ((maxY + padY).coerceAtMost(h)).toFloat() / h

        if ((right - left) < 0.15f || (bottom - top) < 0.15f) return floatArrayOf(0f, 0f, 1f, 1f)
        return floatArrayOf(left, top, right, bottom)
    }

    override fun close() {
        runCatching { renderer.close() }
        runCatching { pfd.close() }
    }
}
