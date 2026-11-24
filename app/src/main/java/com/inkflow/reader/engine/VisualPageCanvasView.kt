package com.inkflow.reader.engine

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.*
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.PathInterpolator
import com.inkflow.reader.model.*
import kotlin.math.*

data class VisualSpreadBitmaps(
    val firstPageIndex: Int,
    val secondPageIndex: Int?,
    val firstBitmap: Bitmap?,
    val secondBitmap: Bitmap?,
    val totalPages: Int
)

class VisualPageCanvasView(context: Context) : View(context) {

    interface Listener {
        fun onRequestNextSpread(): Boolean
        fun onRequestPrevSpread(): Boolean
        fun onToggleMenu()
        fun onBoundaryReached(isEnd: Boolean)
        fun onViewportReady(widthPx: Int, heightPx: Int, isDualPage: Boolean)
    }

    var listener: Listener? = null

    private var settings: ReaderSettings = ReaderSettings()
    private var isRtlFlow: Boolean = true
    private var invertColors: Boolean = false
    private var isDualPage: Boolean = false

    private var currentSpread: VisualSpreadBitmaps? = null
    private var nextSpread: VisualSpreadBitmaps? = null
    private var prevSpread: VisualSpreadBitmaps? = null

    private var currentBuffer: Bitmap? = null
    private var targetBuffer: Bitmap? = null

    private enum class TurnDirection { NONE, NEXT, PREV }
    private var turnDirection = TurnDirection.NONE
    private var isDragging = false
    private var isAnimating = false
    private var activeAnimator: ValueAnimator? = null
    private var boundaryHitDir = TurnDirection.NONE

    private var zoomScale = 1f
    private var panX = 0f
    private var panY = 0f
    private var isScaling = false
    private var lastPanX = 0f
    private var lastPanY = 0f

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var velocityTracker: VelocityTracker? = null
    private var downX = 0f
    private var downY = 0f
    private var touchX = 0f
    private var touchY = 0f
    private var cornerY = 0f

    private val path0 = Path()
    private val path1 = Path()
    private val reflectMatrix = Matrix()
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val backFillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val backTintPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val imagePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val footerPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    private val invertFilter = ColorMatrixColorFilter(
        floatArrayOf(
            -1f, 0f, 0f, 0f, 255f,
            0f, -1f, 0f, 0f, 255f,
            0f, 0f, -1f, 0f, 255f,
            0f, 0f, 0f, 1f, 0f
        )
    )

    private val smoothTurnInterpolator = PathInterpolator(0.22f, 0.12f, 0.25f, 1.0f)

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                isScaling = true
                isDragging = false
                turnDirection = TurnDirection.NONE
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val oldScale = zoomScale
                val newScale = (zoomScale * detector.scaleFactor).coerceIn(1f, 4f)
                val ratio = newScale / oldScale
                panX = detector.focusX - (detector.focusX - panX) * ratio
                panY = detector.focusY - (detector.focusY - panY) * ratio
                zoomScale = newScale
                clampPan()
                invalidate()
                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                isScaling = false
                if (zoomScale < 1.05f) resetZoom()
            }
        }
    )

    private val doubleTapDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (isAnimating) return true
                if (zoomScale > 1.15f) {
                    resetZoom()
                } else {
                    zoomScale = 2.2f
                    panX = (width / 2f - e.x) * (zoomScale - 1f)
                    panY = (height / 2f - e.y) * (zoomScale - 1f)
                    clampPan()
                }
                invalidate()
                return true
            }
        }
    )

    fun resetZoom() {
        zoomScale = 1f
        panX = 0f
        panY = 0f
    }

    private fun clampPan() {
        if (zoomScale <= 1f) {
            panX = 0f
            panY = 0f
            return
        }
        val maxPanX = width * (zoomScale - 1f) / 2f + width * 0.1f
        val maxPanY = height * (zoomScale - 1f) / 2f + height * 0.1f
        panX = panX.coerceIn(-maxPanX, maxPanX)
        panY = panY.coerceIn(-maxPanY, maxPanY)
    }

    fun updateState(
        newSettings: ReaderSettings,
        rtlFlow: Boolean,
        invertPdfColors: Boolean,
        current: VisualSpreadBitmaps?,
        next: VisualSpreadBitmaps?,
        prev: VisualSpreadBitmaps?
    ) {
        val pageChanged = current?.firstPageIndex != currentSpread?.firstPageIndex
        this.settings = newSettings
        this.isRtlFlow = rtlFlow
        this.invertColors = invertPdfColors && !newSettings.eInkMode
        this.currentSpread = current
        this.nextSpread = next
        this.prevSpread = prev

        if (pageChanged) resetZoom()

        if (width > 0 && height > 0) {
            val newDual = ReaderLayoutMetrics.computeDualPage(
                width, height, resources.displayMetrics.density, newSettings.dualPageMode
            )
            if (newDual != isDualPage) {
                isDualPage = newDual
                listener?.onViewportReady(width, height, isDualPage)
            }
            if (!isDragging && !isAnimating) {
                renderSpreadToBuffer(currentBuffer, currentSpread)
                invalidate()
            }
        }
    }

    fun triggerTurnNextAnimated() {
        if (isAnimating) return
        resetZoom()
        val target = nextSpread
        if (target == null) {
            listener?.onBoundaryReached(isEnd = true)
            return
        }
        if (settings.effectiveAnimation == PageTurnAnimation.NONE) {
            listener?.onRequestNextSpread()
            return
        }
        startAnimatedTapTurn(TurnDirection.NEXT, target)
    }

    fun triggerTurnPrevAnimated() {
        if (isAnimating) return
        resetZoom()
        val target = prevSpread
        if (target == null) {
            listener?.onBoundaryReached(isEnd = false)
            return
        }
        if (settings.effectiveAnimation == PageTurnAnimation.NONE) {
            listener?.onRequestPrevSpread()
            return
        }
        startAnimatedTapTurn(TurnDirection.PREV, target)
    }

    private fun startAnimatedTapTurn(dir: TurnDirection, target: VisualSpreadBitmaps) {
        turnDirection = dir
        renderSpreadToBuffer(currentBuffer, currentSpread)
        renderSpreadToBuffer(targetBuffer, target)

        val w = width.toFloat()
        val h = height.toFloat()
        val fromLeft = isCurlFromLeftEdge(dir)
        cornerY = h

        if (settings.effectiveAnimation == PageTurnAnimation.SLIDE) {
            val startX = if (fromLeft) w * 0.04f else w * 0.96f
            val endX = if (fromLeft) w else 0f
            touchX = startX
            touchY = h * 0.72f
            animateTurnXY(startX, touchY, endX, touchY, arcLift = 0f, commit = true, durationMs = 440L)
        } else {
            val startX = if (fromLeft) w * 0.05f else w * 0.95f
            val endX = if (fromLeft) w * 2.15f else -w * 1.15f
            val startY = h * 0.94f
            val endY = h - 22f
            touchX = startX
            touchY = startY
            animateTurnXY(startX, startY, endX, endY, arcLift = h * 0.22f, commit = true, durationMs = 520L)
        }
    }

    private fun isCurlFromLeftEdge(dir: TurnDirection): Boolean {
        return if (isRtlFlow) dir == TurnDirection.NEXT else dir == TurnDirection.PREV
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        currentBuffer?.recycle()
        targetBuffer?.recycle()
        currentBuffer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        targetBuffer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        cornerY = h.toFloat()

        isDualPage = ReaderLayoutMetrics.computeDualPage(
            w, h, resources.displayMetrics.density, settings.dualPageMode
        )
        listener?.onViewportReady(w, h, isDualPage)
        renderSpreadToBuffer(currentBuffer, currentSpread)
    }

    private fun renderSpreadToBuffer(buffer: Bitmap?, spread: VisualSpreadBitmaps?) {
        val bmp = buffer ?: return
        val canvas = Canvas(bmp)
        val density = resources.displayMetrics.density

        val bgColor = when {
            settings.eInkMode -> Color.WHITE
            invertColors -> Color.parseColor("#121212")
            else -> Color.parseColor("#1A1D21")
        }
        canvas.drawColor(bgColor)
        imagePaint.colorFilter = if (invertColors) invertFilter else null

        if (spread == null || (spread.firstBitmap == null && spread.secondBitmap == null)) {
            footerPaint.apply {
                color = if (settings.eInkMode) Color.BLACK else Color.LTGRAY
                textSize = 15f * resources.displayMetrics.scaledDensity
                textAlign = Paint.Align.CENTER
            }
            canvas.drawText("正在載入頁面…", width / 2f, height / 2f, footerPaint)
            return
        }

        val footerReserve = 18f * density
        val drawHeight = (height - footerReserve).coerceAtLeast(100f)

        if (!isDualPage) {
            val dest = RectF(0f, 0f, width.toFloat(), drawHeight)
            spread.firstBitmap?.let { drawBitmapFitCenter(canvas, it, dest, alignRight = false, alignLeft = false) }
        } else {
            val centerX = width / 2f
            val leftRect = RectF(0f, 0f, centerX, drawHeight)
            val rightRect = RectF(centerX, 0f, width.toFloat(), drawHeight)

            if (isRtlFlow) {
                spread.firstBitmap?.let { drawBitmapFitCenter(canvas, it, rightRect, alignRight = false, alignLeft = true) }
                spread.secondBitmap?.let { drawBitmapFitCenter(canvas, it, leftRect, alignRight = true, alignLeft = false) }
            } else {
                spread.firstBitmap?.let { drawBitmapFitCenter(canvas, it, leftRect, alignRight = true, alignLeft = false) }
                spread.secondBitmap?.let { drawBitmapFitCenter(canvas, it, rightRect, alignRight = false, alignLeft = true) }
            }

            if (settings.effectiveSpineShadow) {
                drawCenterSpineShadow(canvas, centerX, drawHeight, density)
            } else if (settings.eInkMode) {
                val div = Paint().apply {
                    color = Color.parseColor("#CCCCCC")
                    strokeWidth = 1f * density
                }
                canvas.drawLine(centerX, 0f, centerX, drawHeight, div)
            }
        }

        footerPaint.apply {
            color = if (settings.eInkMode) Color.DKGRAY else Color.parseColor("#9AA4B2")
            textSize = 11f * resources.displayMetrics.scaledDensity
            textAlign = Paint.Align.RIGHT
        }
        val pageLabel = if (isDualPage && spread.secondPageIndex != null) {
            "${spread.firstPageIndex + 1}-${spread.secondPageIndex + 1} / ${spread.totalPages}"
        } else {
            "${spread.firstPageIndex + 1} / ${spread.totalPages}"
        }
        canvas.drawText(pageLabel, width - 12f * density, height - 5f * density, footerPaint)
    }

    private fun drawBitmapFitCenter(
        canvas: Canvas,
        bmp: Bitmap,
        bounds: RectF,
        alignRight: Boolean,
        alignLeft: Boolean
    ) {
        if (bmp.isRecycled || bmp.width <= 0 || bmp.height <= 0) return
        val scale = min(bounds.width() / bmp.width.toFloat(), bounds.height() / bmp.height.toFloat())
        val dw = bmp.width * scale
        val dh = bmp.height * scale
        val left = when {
            alignRight -> bounds.right - dw
            alignLeft -> bounds.left
            else -> bounds.left + (bounds.width() - dw) / 2f
        }
        val top = bounds.top + (bounds.height() - dh) / 2f
        val dst = RectF(left, top, left + dw, top + dh)
        canvas.drawBitmap(bmp, null, dst, imagePaint)
    }

    private fun drawCenterSpineShadow(canvas: Canvas, centerX: Float, h: Float, density: Float) {
        val leftW = 24f * density
        val rightW = 18f * density
        shadowPaint.shader = LinearGradient(
            centerX - leftW, 0f, centerX, 0f,
            intArrayOf(Color.TRANSPARENT, Color.argb(30, 0, 0, 0), Color.argb(85, 0, 0, 0)),
            floatArrayOf(0f, 0.7f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(centerX - leftW, 0f, centerX, h, shadowPaint)

        shadowPaint.shader = LinearGradient(
            centerX, 0f, centerX + rightW, 0f,
            intArrayOf(Color.argb(72, 0, 0, 0), Color.argb(26, 0, 0, 0), Color.TRANSPARENT),
            floatArrayOf(0f, 0.35f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(centerX, 0f, centerX + rightW, h, shadowPaint)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (isAnimating) return true

        scaleDetector.onTouchEvent(event)
        doubleTapDetector.onTouchEvent(event)
        if (isScaling || event.pointerCount > 1) {
            isDragging = false
            turnDirection = TurnDirection.NONE
            return true
        }

        if (zoomScale > 1.05f) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    lastPanX = event.x
                    lastPanY = event.y
                    downX = event.x
                    downY = event.y
                    isDragging = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.x - lastPanX
                    val dy = event.y - lastPanY
                    if (hypot((event.x - downX).toDouble(), (event.y - downY).toDouble()) > touchSlop) {
                        isDragging = true
                    }
                    panX += dx
                    panY += dy
                    clampPan()
                    lastPanX = event.x
                    lastPanY = event.y
                    invalidate()
                }
                MotionEvent.ACTION_UP -> {
                    if (!isDragging) {
                        val col = ((event.x / width.coerceAtLeast(1)) * 3f).toInt().coerceIn(0, 2)
                        val row = ((event.y / height.coerceAtLeast(1)) * 3f).toInt().coerceIn(0, 2)
                        if (settings.tapZones.getOrElse(row * 3 + col) { TapAction.TOGGLE_MENU } == TapAction.TOGGLE_MENU) {
                            listener?.onToggleMenu()
                        }
                    }
                    isDragging = false
                }
            }
            return true
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                velocityTracker?.recycle()
                velocityTracker = VelocityTracker.obtain().apply { addMovement(event) }

                downX = event.x
                downY = event.y
                touchX = event.x
                touchY = event.y
                cornerY = if (event.y < height * 0.32f) 0f else height.toFloat()
                isDragging = false
                turnDirection = TurnDirection.NONE
                boundaryHitDir = TurnDirection.NONE
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                velocityTracker?.addMovement(event)

                val dx = event.x - downX
                val dy = event.y - downY

                if (!isDragging && abs(dx) > touchSlop && abs(dx) > abs(dy) * 0.6f) {
                    val swipingRight = dx > 0
                    val candidateDir = if (isRtlFlow) {
                        if (swipingRight) TurnDirection.NEXT else TurnDirection.PREV
                    } else {
                        if (swipingRight) TurnDirection.PREV else TurnDirection.NEXT
                    }

                    val target = when (candidateDir) {
                        TurnDirection.NEXT -> nextSpread
                        TurnDirection.PREV -> prevSpread
                        TurnDirection.NONE -> null
                    }

                    if (target == null) {
                        boundaryHitDir = candidateDir
                    } else {
                        isDragging = true
                        turnDirection = candidateDir
                        boundaryHitDir = TurnDirection.NONE
                        renderSpreadToBuffer(currentBuffer, currentSpread)
                        renderSpreadToBuffer(targetBuffer, target)
                    }
                }

                if (isDragging && turnDirection != TurnDirection.NONE) {
                    touchX = event.x.coerceIn(0f, width.toFloat())
                    touchY = event.y.coerceIn(1f, height - 1f)
                    if (settings.effectiveAnimation != PageTurnAnimation.NONE) invalidate()
                }
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                velocityTracker?.addMovement(event)
                velocityTracker?.computeCurrentVelocity(1000)
                val vx = velocityTracker?.xVelocity ?: 0f
                velocityTracker?.recycle()
                velocityTracker = null

                if (!isDragging) {
                    if (boundaryHitDir != TurnDirection.NONE) {
                        val hitEnd = boundaryHitDir == TurnDirection.NEXT
                        boundaryHitDir = TurnDirection.NONE
                        listener?.onBoundaryReached(isEnd = hitEnd)
                    } else if (event.actionMasked == MotionEvent.ACTION_UP) {
                        handleTapZone(event.x, event.y)
                    }
                } else if (turnDirection != TurnDirection.NONE) {
                    val dx = event.x - downX
                    val w = width.toFloat()
                    val curlFromLeft = isCurlFromLeftEdge(turnDirection)
                    val movedEnough = if (curlFromLeft) dx > w * 0.12f else -dx > w * 0.12f
                    val flickedEnough = if (curlFromLeft) vx > 380f else vx < -380f
                    val shouldCommit = (event.actionMasked == MotionEvent.ACTION_UP) && (movedEnough || flickedEnough)

                    if (settings.effectiveAnimation == PageTurnAnimation.NONE) {
                        val dir = turnDirection
                        resetTurnState()
                        if (shouldCommit) {
                            if (dir == TurnDirection.NEXT) listener?.onRequestNextSpread()
                            else listener?.onRequestPrevSpread()
                        }
                        invalidate()
                    } else if (settings.effectiveAnimation == PageTurnAnimation.SLIDE) {
                        val endX = if (shouldCommit) {
                            if (curlFromLeft) w else 0f
                        } else {
                            if (curlFromLeft) 0f else w
                        }
                        val remainRatio = (abs(endX - touchX) / w.coerceAtLeast(1f)).coerceIn(0.35f, 1f)
                        animateTurnXY(
                            startX = touchX, startY = touchY,
                            endX = endX, endY = touchY,
                            arcLift = 0f,
                            commit = shouldCommit,
                            durationMs = (420L * remainRatio).toLong().coerceAtLeast(200L)
                        )
                    } else {
                        val fx = if (curlFromLeft) 0f else w
                        val endX = if (shouldCommit) {
                            if (curlFromLeft) w * 2.15f else -w * 1.15f
                        } else fx
                        val endY = if (cornerY > 0f) height - 22f else 22f
                        val totalTravel = (w * 2.15f).coerceAtLeast(1f)
                        val remainRatio = (abs(endX - touchX) / totalTravel).coerceIn(0.45f, 1f)
                        val dur = if (shouldCommit) (460L * remainRatio).toLong().coerceIn(260L, 480L) else 280L
                        animateTurnXY(
                            startX = touchX, startY = touchY,
                            endX = endX, endY = endY,
                            arcLift = 0f,
                            commit = shouldCommit,
                            durationMs = dur
                        )
                    }
                }
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun handleTapZone(x: Float, y: Float) {
        if (width <= 0 || height <= 0) return
        val col = ((x / width) * 3f).toInt().coerceIn(0, 2)
        val row = ((y / height) * 3f).toInt().coerceIn(0, 2)
        val idx = row * 3 + col
        val action = settings.tapZones.getOrElse(idx) { TapAction.TOGGLE_MENU }
        when (action) {
            TapAction.PREV_PAGE -> triggerTurnPrevAnimated()
            TapAction.NEXT_PAGE -> triggerTurnNextAnimated()
            TapAction.TOGGLE_MENU -> listener?.onToggleMenu()
        }
    }

    private fun animateTurnXY(
        startX: Float, startY: Float, endX: Float, endY: Float,
        arcLift: Float, commit: Boolean, durationMs: Long
    ) {
        activeAnimator?.cancel()
        isAnimating = true
        val dir = turnDirection
        val liftSign = if (cornerY > 0f) -1f else 1f

        activeAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = durationMs
            interpolator = smoothTurnInterpolator
            addUpdateListener { anim ->
                val p = anim.animatedValue as Float
                touchX = startX + (endX - startX) * p
                val linearY = startY + (endY - startY) * p
                touchY = linearY + liftSign * arcLift * sin(PI * p).toFloat()
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (commit) {
                        val tmp = currentBuffer
                        currentBuffer = targetBuffer
                        targetBuffer = tmp
                    }
                    resetTurnState()
                    if (commit) {
                        if (dir == TurnDirection.NEXT) listener?.onRequestNextSpread()
                        else if (dir == TurnDirection.PREV) listener?.onRequestPrevSpread()
                    }
                    invalidate()
                }
            })
            start()
        }
    }

    private fun resetTurnState() {
        isDragging = false
        isAnimating = false
        turnDirection = TurnDirection.NONE
        boundaryHitDir = TurnDirection.NONE
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val curBmp = currentBuffer ?: return

        if (zoomScale > 1.01f) {
            canvas.drawColor(if (settings.eInkMode) Color.WHITE else Color.parseColor("#121212"))
            canvas.save()
            canvas.translate(width / 2f + panX, height / 2f + panY)
            canvas.scale(zoomScale, zoomScale)
            canvas.translate(-width / 2f, -height / 2f)
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            canvas.restore()
            return
        }

        if (turnDirection == TurnDirection.NONE || settings.effectiveAnimation == PageTurnAnimation.NONE) {
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            return
        }

        val tgtBmp = targetBuffer ?: run {
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            return
        }

        when (settings.effectiveAnimation) {
            PageTurnAnimation.SLIDE -> drawSlideTransition(canvas, curBmp, tgtBmp)
            PageTurnAnimation.SIMULATION -> drawRealisticBezierCurl(canvas, curBmp, tgtBmp)
            PageTurnAnimation.NONE -> canvas.drawBitmap(curBmp, 0f, 0f, null)
        }
    }

    private fun drawSlideTransition(canvas: Canvas, curBmp: Bitmap, tgtBmp: Bitmap) {
        val fromLeft = isCurlFromLeftEdge(turnDirection)
        val w = width.toFloat()
        val h = height.toFloat()

        canvas.drawBitmap(tgtBmp, 0f, 0f, null)
        val offsetX = if (fromLeft) touchX.coerceIn(0f, w) else (touchX - w).coerceIn(-w, 0f)
        canvas.save()
        canvas.translate(offsetX, 0f)
        canvas.drawBitmap(curBmp, 0f, 0f, null)
        canvas.restore()

        val shadowEdgeX = if (fromLeft) offsetX else offsetX + w
        val shadowW = 24f * resources.displayMetrics.density
        shadowPaint.shader = if (fromLeft) {
            LinearGradient(shadowEdgeX - shadowW, 0f, shadowEdgeX, 0f, Color.TRANSPARENT, Color.argb(95, 0, 0, 0), Shader.TileMode.CLAMP)
        } else {
            LinearGradient(shadowEdgeX, 0f, shadowEdgeX + shadowW, 0f, Color.argb(95, 0, 0, 0), Color.TRANSPARENT, Shader.TileMode.CLAMP)
        }
        if (fromLeft) canvas.drawRect(shadowEdgeX - shadowW, 0f, shadowEdgeX, h, shadowPaint)
        else canvas.drawRect(shadowEdgeX, 0f, shadowEdgeX + shadowW, h, shadowPaint)
    }

    private fun drawRealisticBezierCurl(canvas: Canvas, curBmp: Bitmap, tgtBmp: Bitmap) {
        val w = width.toFloat()
        val h = height.toFloat()
        val density = resources.displayMetrics.density
        val fromLeft = isCurlFromLeftEdge(turnDirection)

        val fx = if (fromLeft) 0f else w
        val fy = if (cornerY > 0f) h else 0f

        val distX = abs(fx - touchX)
        if (distX < 1.5f) {
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            return
        }

        val rawDy = abs(fy - touchY)
        val minDy = max(12f, min(h * 0.035f, distX * 0.12f))
        val maxDy = max(minDy + 1f, min(h * 0.42f, distX * 0.52f + 16f))
        val clampedDy = rawDy.coerceIn(minDy, maxDy)
        val effAy = if (fy > 0f) fy - clampedDy else fy + clampedDy
        val effAx = touchX

        val gx = (effAx + fx) / 2f
        val gy = (effAy + fy) / 2f
        val denomX = fx - gx
        val denomY = fy - gy
        if (abs(denomX) < 0.5f || abs(denomY) < 0.5f) {
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            return
        }

        val ex = gx - (denomY * denomY) / denomX
        val ey = fy
        val hx = fx
        val hy = gy - (denomX * denomX) / denomY

        val cx = ex - (fx - ex) / 2f
        val cy = fy
        val jx = fx
        val jy = hy - (fy - hy) / 2f

        val bPt = lineIntersect(effAx, effAy, ex, ey, cx, cy, jx, jy)
        val kPt = lineIntersect(effAx, effAy, hx, hy, cx, cy, jx, jy)
        val bx = bPt.x
        val by = bPt.y
        val kx = kPt.x
        val ky = kPt.y

        val dx = (cx + 2f * ex + bx) / 4f
        val dy = (cy + 2f * ey + by) / 4f
        val ix = (jx + 2f * hx + kx) / 4f
        val iy = (jy + 2f * hy + ky) / 4f

        val mebX = (ex + bx) / 2f
        val mebY = (ey + by) / 2f
        val mhkX = (hx + kx) / 2f
        val mhkY = (hy + ky) / 2f

        val ux = ix - dx
        val uy = iy - dy
        val uLen = hypot(ux.toDouble(), uy.toDouble()).toFloat()
        if (uLen < 1f) {
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            return
        }
        var nx = -uy / uLen
        var ny = ux / uLen
        if (nx * (fx - dx) + ny * (fy - dy) < 0f) {
            nx = -nx
            ny = -ny
        }

        val flapDepth = abs(nx * (effAx - dx) + ny * (effAy - dy)).coerceAtLeast(10f)

        path0.reset()
        path0.moveTo(jx, jy)
        path0.quadTo(hx, hy, kx, ky)
        path0.lineTo(effAx, effAy)
        path0.lineTo(bx, by)
        path0.quadTo(ex, ey, cx, cy)
        path0.lineTo(fx, fy)
        path0.close()

        path1.reset()
        path1.moveTo(ix, iy)
        path1.lineTo(dx, dy)
        path1.quadTo(mebX, mebY, bx, by)
        path1.lineTo(effAx, effAy)
        path1.lineTo(kx, ky)
        path1.quadTo(mhkX, mhkY, ix, iy)
        path1.close()

        canvas.drawBitmap(curBmp, 0f, 0f, null)

        val frontShadowW = (flapDepth * 0.22f).coerceIn(10f * density, 26f * density)
        canvas.save()
        canvas.clipOutPath(path0)
        shadowPaint.shader = LinearGradient(
            cx, cy, cx - nx * frontShadowW, cy - ny * frontShadowW,
            intArrayOf(Color.argb(72, 0, 0, 0), Color.argb(26, 0, 0, 0), Color.TRANSPARENT),
            floatArrayOf(0f, 0.45f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(0f, 0f, w, h, shadowPaint)
        canvas.restore()

        val castW = (flapDepth * 0.55f).coerceIn(20f * density, 86f * density)
        val underOverlap = 3f * density
        canvas.save()
        canvas.clipPath(path0)
        canvas.drawBitmap(tgtBmp, 0f, 0f, null)
        shadowPaint.shader = LinearGradient(
            dx - nx * underOverlap, dy - ny * underOverlap,
            dx + nx * castW, dy + ny * castW,
            intArrayOf(Color.argb(165, 0, 0, 0), Color.argb(95, 0, 0, 0), Color.argb(30, 0, 0, 0), Color.TRANSPARENT),
            floatArrayOf(0f, 0.22f, 0.58f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(0f, 0f, w, h, shadowPaint)
        canvas.restore()

        canvas.save()
        canvas.clipPath(path1)
        backFillPaint.color = if (settings.eInkMode) Color.WHITE else Color.parseColor("#E8E6E1")
        canvas.drawRect(0f, 0f, w, h, backFillPaint)

        val angleDeg = Math.toDegrees(atan2((hy - ey).toDouble(), (hx - ex).toDouble())).toFloat()
        reflectMatrix.reset()
        reflectMatrix.postTranslate(-ex, -ey)
        reflectMatrix.postRotate(-angleDeg)
        reflectMatrix.postScale(1f, -1f)
        reflectMatrix.postRotate(angleDeg)
        reflectMatrix.postTranslate(ex, ey)

        backTintPaint.alpha = 50
        canvas.drawBitmap(curBmp, reflectMatrix, backTintPaint)

        shadowPaint.shader = LinearGradient(
            dx, dy, dx - nx * flapDepth, dy - ny * flapDepth,
            intArrayOf(Color.argb(96, 0, 0, 0), Color.argb(46, 255, 255, 255), Color.TRANSPARENT, Color.argb(56, 0, 0, 0)),
            floatArrayOf(0f, 0.20f, 0.65f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(0f, 0f, w, h, shadowPaint)
        canvas.restore()
    }

    private fun lineIntersect(
        x1: Float, y1: Float, x2: Float, y2: Float,
        x3: Float, y3: Float, x4: Float, y4: Float
    ): PointF {
        val denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if (abs(denom) < 1e-4f) return PointF((x1 + x2) / 2f, (y1 + y2) / 2f)
        val px = ((x1 * y2 - y1 * x2) * (x3 - x4) - (x1 - x2) * (x3 * y4 - y3 * x4)) / denom
        val py = ((x1 * y2 - y1 * x2) * (y3 - y4) - (y1 - y2) * (x3 * y4 - y3 * x4)) / denom
        return PointF(px, py)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        activeAnimator?.cancel()
        velocityTracker?.recycle()
        velocityTracker = null
        currentBuffer?.recycle()
        targetBuffer?.recycle()
        currentBuffer = null
        targetBuffer = null
    }
}
