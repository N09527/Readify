package com.inkflow.reader.engine

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.*
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.PathInterpolator
import com.inkflow.reader.data.FontManager
import com.inkflow.reader.model.*
import kotlin.math.*

data class SpreadSnapshot(
    val chapterIndex: Int,
    val chapterTitle: String,
    val firstPage: PageContent?,
    val secondPage: PageContent?,
    val totalPagesInChapter: Int
)

class ReaderCanvasView(context: Context) : View(context) {

    interface Listener {
        fun onRequestNextSpread(): Boolean
        fun onRequestPrevSpread(): Boolean
        fun onToggleMenu()
        fun onBoundaryReached(isEnd: Boolean)
        fun onViewportReady(widthPx: Int, heightPx: Int, density: Float)
    }

    var listener: Listener? = null

    private var settings: ReaderSettings = ReaderSettings()
    private var bookTitle: String = ""
    private var totalChapters: Int = 1

    private var currentSpread: SpreadSnapshot? = null
    private var nextSpread: SpreadSnapshot? = null
    private var prevSpread: SpreadSnapshot? = null

    private var customTypeface: Typeface? = null
    private var cachedFontPath: String? = null

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    private var currentBitmap: Bitmap? = null
    private var targetBitmap: Bitmap? = null

    private enum class TurnDirection { NONE, NEXT, PREV }
    private var turnDirection = TurnDirection.NONE
    private var isDragging = false
    private var isAnimating = false
    private var activeAnimator: ValueAnimator? = null
    private var boundaryHitDir = TurnDirection.NONE

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var velocityTracker: VelocityTracker? = null
    private var downX = 0f
    private var downY = 0f
    private var touchX = 0f
    private var touchY = 0f
    private var cornerY = 0f

    // Reusable paths & paints for zero-allocation 60/120fps Bezier curl rendering
    private val path0 = Path()
    private val path1 = Path()
    private val reflectMatrix = Matrix()
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val backFillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val backTintPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    private val smoothTurnInterpolator = PathInterpolator(0.22f, 0.12f, 0.25f, 1.0f)

    fun updateState(
        newSettings: ReaderSettings,
        bookTitle: String,
        totalChapters: Int,
        currentSpread: SpreadSnapshot?,
        nextSpread: SpreadSnapshot?,
        prevSpread: SpreadSnapshot?
    ) {
        this.settings = newSettings
        this.bookTitle = bookTitle
        this.totalChapters = totalChapters.coerceAtLeast(1)
        this.currentSpread = currentSpread
        this.nextSpread = nextSpread
        this.prevSpread = prevSpread

        configurePaints()

        if (width > 0 && height > 0 && !isDragging && !isAnimating) {
            renderSpreadToBitmap(currentBitmap, currentSpread)
            invalidate()
        }
    }

    fun triggerTurnNextAnimated() {
        if (isAnimating) return
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

    private fun startAnimatedTapTurn(dir: TurnDirection, target: SpreadSnapshot) {
        turnDirection = dir
        renderSpreadToBitmap(currentBitmap, currentSpread)
        renderSpreadToBitmap(targetBitmap, target)

        val w = width.toFloat()
        val h = height.toFloat()
        val fromLeft = isCurlFromLeftEdge(dir)
        cornerY = h

        if (settings.effectiveAnimation == PageTurnAnimation.SLIDE) {
            val startX = if (fromLeft) w * 0.04f else w * 0.96f
            val endX = if (fromLeft) w else 0f
            touchX = startX
            touchY = h * 0.72f
            animateTurnXY(startX, touchY, endX, touchY, arcLift = 0f, commit = true, durationMs = 460L)
        } else {
            val startX = if (fromLeft) w * 0.05f else w * 0.95f
            val endX = if (fromLeft) w * 2.15f else -w * 1.15f
            val startY = h * 0.94f
            val endY = h - 22f
            touchX = startX
            touchY = startY
            animateTurnXY(startX, startY, endX, endY, arcLift = h * 0.22f, commit = true, durationMs = 540L)
        }
    }

    private fun isSwipeRightNext(): Boolean {
        return settings.writingMode == WritingMode.VERTICAL && settings.verticalNaturalSwipe
    }

    private fun isCurlFromLeftEdge(dir: TurnDirection): Boolean {
        return if (isSwipeRightNext()) {
            dir == TurnDirection.NEXT
        } else {
            dir == TurnDirection.PREV
        }
    }

    private fun configurePaints() {
        val dm = resources.displayMetrics
        val theme = settings.effectiveTheme

        if (cachedFontPath != settings.customFontPath) {
            cachedFontPath = settings.customFontPath
            customTypeface = FontManager.loadTypeface(context, settings.customFontPath)
        }

        textPaint.apply {
            color = theme.textColor
            textSize = settings.fontSizeSp * dm.scaledDensity
            letterSpacing = if (settings.writingMode == WritingMode.HORIZONTAL) settings.letterSpacingEm else 0f
            typeface = if (customTypeface != null) {
                customTypeface
            } else {
                Typeface.create(Typeface.SERIF, if (settings.fontBold) Typeface.BOLD else Typeface.NORMAL)
            }
            isFakeBoldText = settings.fontBold
            isSubpixelText = !settings.eInkMode
            isAntiAlias = true
        }

        headerPaint.apply {
            color = theme.subTextColor
            textSize = 11.5f * dm.scaledDensity
            typeface = Typeface.SANS_SERIF
            isAntiAlias = true
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        currentBitmap?.recycle()
        targetBitmap?.recycle()
        currentBitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        targetBitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        cornerY = h.toFloat()

        configurePaints()
        listener?.onViewportReady(w, h, resources.displayMetrics.density)
        renderSpreadToBitmap(currentBitmap, currentSpread)
    }

    fun getTextPaintForPagination(forSettings: ReaderSettings): Paint {
        val dm = resources.displayMetrics
        val tf = if (forSettings.customFontPath == cachedFontPath) {
            customTypeface
        } else {
            FontManager.loadTypeface(context, forSettings.customFontPath)
        }
        return Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = forSettings.fontSizeSp * dm.scaledDensity
            letterSpacing = if (forSettings.writingMode == WritingMode.HORIZONTAL) forSettings.letterSpacingEm else 0f
            typeface = if (tf != null) {
                tf
            } else {
                Typeface.create(Typeface.SERIF, if (forSettings.fontBold) Typeface.BOLD else Typeface.NORMAL)
            }
            isFakeBoldText = forSettings.fontBold
        }
    }

    private fun renderSpreadToBitmap(bitmap: Bitmap?, spread: SpreadSnapshot?) {
        val bmp = bitmap ?: return
        val c = Canvas(bmp)
        SpreadRenderer.drawSpread(
            canvas = c,
            width = width,
            height = height,
            density = resources.displayMetrics.density,
            settings = settings,
            bookTitle = bookTitle,
            chapterTitle = spread?.chapterTitle ?: "",
            firstPage = spread?.firstPage,
            secondPage = spread?.secondPage,
            totalPagesInChapter = (spread?.totalPagesInChapter ?: 1).coerceAtLeast(1),
            chapterIndex = spread?.chapterIndex ?: 0,
            totalChapters = totalChapters,
            textPaint = textPaint,
            headerPaint = headerPaint
        )
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (isAnimating) return true

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
                    val candidateDir = if (isSwipeRightNext()) {
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
                        renderSpreadToBitmap(currentBitmap, currentSpread)
                        renderSpreadToBitmap(targetBitmap, target)
                    }
                }

                if (isDragging && turnDirection != TurnDirection.NONE) {
                    touchX = event.x.coerceIn(0f, width.toFloat())
                    touchY = event.y.coerceIn(1f, height - 1f)
                    if (settings.effectiveAnimation != PageTurnAnimation.NONE) {
                        invalidate()
                    }
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
                        } else {
                            fx
                        }
                        val endY = if (cornerY > 0f) height - 22f else 22f
                        val totalTravel = (w * 2.15f).coerceAtLeast(1f)
                        val remainRatio = (abs(endX - touchX) / totalTravel).coerceIn(0.45f, 1f)
                        val dur = if (shouldCommit) {
                            (460L * remainRatio).toLong().coerceIn(260L, 480L)
                        } else {
                            280L
                        }
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
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        arcLift: Float,
        commit: Boolean,
        durationMs: Long
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
                        val tmp = currentBitmap
                        currentBitmap = targetBitmap
                        targetBitmap = tmp
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
        val curBmp = currentBitmap ?: return

        if (turnDirection == TurnDirection.NONE || settings.effectiveAnimation == PageTurnAnimation.NONE) {
            canvas.drawBitmap(curBmp, 0f, 0f, null)
            return
        }

        val tgtBmp = targetBitmap ?: run {
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

        val offsetX = if (fromLeft) {
            touchX.coerceIn(0f, w)
        } else {
            (touchX - w).coerceIn(-w, 0f)
        }

        canvas.save()
        canvas.translate(offsetX, 0f)
        canvas.drawBitmap(curBmp, 0f, 0f, null)
        canvas.restore()

        val shadowEdgeX = if (fromLeft) offsetX else offsetX + w
        val shadowW = 24f * resources.displayMetrics.density
        shadowPaint.shader = if (fromLeft) {
            LinearGradient(
                shadowEdgeX - shadowW, 0f, shadowEdgeX, 0f,
                Color.TRANSPARENT, Color.argb(95, 0, 0, 0),
                Shader.TileMode.CLAMP
            )
        } else {
            LinearGradient(
                shadowEdgeX, 0f, shadowEdgeX + shadowW, 0f,
                Color.argb(95, 0, 0, 0), Color.TRANSPARENT,
                Shader.TileMode.CLAMP
            )
        }
        if (fromLeft) {
            canvas.drawRect(shadowEdgeX - shadowW, 0f, shadowEdgeX, h, shadowPaint)
        } else {
            canvas.drawRect(shadowEdgeX, 0f, shadowEdgeX + shadowW, h, shadowPaint)
        }
    }

    /**
     * Exact De Casteljau Bezier paper-curl engine.
     *
     * Guarantees ZERO gap between curled paper and shadows:
     *  - Path0 bounds the entire lifted region (revealed next page + curled flap).
     *  - Path1 uses exact De Casteljau half-Bezier control points (M_eb, M_hk) to match Path0 seamlessly.
     *  - Cast shadow on next page starts slightly underneath Path1 along the exact ridge D->I and fades
     *    outward perpendicular to D->I toward corner F, then Path1 renders on top of it.
     */
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

        // Smoothly bound vertical lift relative to horizontal pull so middle drags peel naturally
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

        // Intersections B = AE ∩ CJ and K = AH ∩ CJ
        val bPt = lineIntersect(effAx, effAy, ex, ey, cx, cy, jx, jy)
        val kPt = lineIntersect(effAx, effAy, hx, hy, cx, cy, jx, jy)
        val bx = bPt.x
        val by = bPt.y
        val kx = kPt.x
        val ky = kPt.y

        // Exact Bezier midpoints D (for C-E-B) and I (for J-H-K)
        val dx = (cx + 2f * ex + bx) / 4f
        val dy = (cy + 2f * ey + by) / 4f
        val ix = (jx + 2f * hx + kx) / 4f
        val iy = (jy + 2f * hy + ky) / 4f

        // Exact De Casteljau control points for sub-curves D->B and K->I
        val mebX = (ex + bx) / 2f
        val mebY = (ey + by) / 2f
        val mhkX = (hx + kx) / 2f
        val mhkY = (hy + ky) / 2f

        // Unit normal to ridge line D -> I pointing strictly toward corner F (revealed next page side)
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
        val isDark = Color.luminance(settings.effectiveTheme.bgColor) < 0.25f

        // Build Path0: entire lifted region (curled flap + revealed next page)
        path0.reset()
        path0.moveTo(jx, jy)
        path0.quadTo(hx, hy, kx, ky)
        path0.lineTo(effAx, effAy)
        path0.lineTo(bx, by)
        path0.quadTo(ex, ey, cx, cy)
        path0.lineTo(fx, fy)
        path0.close()

        // Build Path1: curled backside paper flap ONLY (exact shared sub-curves with Path0!)
        path1.reset()
        path1.moveTo(ix, iy)
        path1.lineTo(dx, dy)
        path1.quadTo(mebX, mebY, bx, by)
        path1.lineTo(effAx, effAy)
        path1.lineTo(kx, ky)
        path1.quadTo(mhkX, mhkY, ix, iy)
        path1.close()

        // 1. Base: flat current page
        canvas.drawBitmap(curBmp, 0f, 0f, null)

        // 2. Subtle pre-fold curve shadow on the flat current page right up to the lift curve
        val frontShadowW = (flapDepth * 0.22f).coerceIn(10f * density, 26f * density)
        canvas.save()
        canvas.clipOutPath(path0)
        shadowPaint.shader = LinearGradient(
            cx, cy,
            cx - nx * frontShadowW, cy - ny * frontShadowW,
            intArrayOf(
                Color.argb(if (isDark) 95 else 52, 0, 0, 0),
                Color.argb(if (isDark) 35 else 18, 0, 0, 0),
                Color.TRANSPARENT
            ),
            floatArrayOf(0f, 0.45f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(0f, 0f, w, h, shadowPaint)
        canvas.restore()

        // 3. Revealed next page + seamless cast shadow strictly along ridge D -> I
        val castW = (flapDepth * 0.55f).coerceIn(20f * density, 86f * density)
        canvas.save()
        canvas.clipPath(path0)
        canvas.drawBitmap(tgtBmp, 0f, 0f, null)

        // Start shadow 3px underneath Path1 so anti-aliased seams NEVER show a bright gap!
        val underOverlap = 3f * density
        shadowPaint.shader = LinearGradient(
            dx - nx * underOverlap, dy - ny * underOverlap,
            dx + nx * castW, dy + ny * castW,
            intArrayOf(
                Color.argb(if (isDark) 190 else 135, 0, 0, 0),
                Color.argb(if (isDark) 115 else 72, 0, 0, 0),
                Color.argb(if (isDark) 42 else 22, 0, 0, 0),
                Color.TRANSPARENT
            ),
            floatArrayOf(0f, 0.22f, 0.58f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRect(0f, 0f, w, h, shadowPaint)
        canvas.restore()

        // 4. Curled paper backside (Path1): base paper tint + exact reflected page content + cylindrical shading
        canvas.save()
        canvas.clipPath(path1)

        backFillPaint.color = settings.effectiveTheme.pageBackColor
        canvas.drawRect(0f, 0f, w, h, backFillPaint)

        // Exact geometric reflection across fold line E -> H
        val angleDeg = Math.toDegrees(atan2((hy - ey).toDouble(), (hx - ex).toDouble())).toFloat()
        reflectMatrix.reset()
        reflectMatrix.postTranslate(-ex, -ey)
        reflectMatrix.postRotate(-angleDeg)
        reflectMatrix.postScale(1f, -1f)
        reflectMatrix.postRotate(angleDeg)
        reflectMatrix.postTranslate(ex, ey)

        backTintPaint.alpha = if (isDark) 36 else 48
        canvas.drawBitmap(curBmp, reflectMatrix, backTintPaint)

        // Cylindrical curl shading across the flap from ridge D->I inward toward tip A
        val highlightAlpha = if (isDark) 20 else 56
        shadowPaint.shader = LinearGradient(
            dx, dy,
            dx - nx * flapDepth, dy - ny * flapDepth,
            intArrayOf(
                Color.argb(if (isDark) 130 else 88, 0, 0, 0),
                Color.argb(highlightAlpha, 255, 255, 255),
                Color.argb(0, 0, 0, 0),
                Color.argb(if (isDark) 85 else 46, 0, 0, 0)
            ),
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
        if (abs(denom) < 1e-4f) {
            return PointF((x1 + x2) / 2f, (y1 + y2) / 2f)
        }
        val px = ((x1 * y2 - y1 * x2) * (x3 - x4) - (x1 - x2) * (x3 * y4 - y3 * x4)) / denom
        val py = ((x1 * y2 - y1 * x2) * (y3 - y4) - (y1 - y2) * (x3 * y4 - y3 * x4)) / denom
        return PointF(px, py)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        activeAnimator?.cancel()
        velocityTracker?.recycle()
        velocityTracker = null
        currentBitmap?.recycle()
        targetBitmap?.recycle()
        currentBitmap = null
        targetBitmap = null
    }
}
