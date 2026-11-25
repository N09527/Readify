import QuartzCore
import SwiftUI
import UIKit

struct SpreadSnapshot: Equatable {
    var chapterIndex: Int
    var chapterTitle: String
    var firstPage: PageContent?
    var secondPage: PageContent?
    var totalPagesInChapter: Int
}

final class ReaderTurnController: ObservableObject {
    var triggerNext: (() -> Void)?
    var triggerPrev: (() -> Void)?
}

final class ReaderCanvasUIView: UIView {
    var onRequestNextSpread: (() -> Bool)?
    var onRequestPrevSpread: (() -> Bool)?
    var onToggleMenu: (() -> Void)?
    var onBoundaryReached: ((Bool) -> Void)?
    var onViewportReady: ((CGFloat, CGFloat) -> Void)?

    private var settings = ReaderSettings()
    private var bookTitle: String = ""
    private var totalChapters: Int = 1

    private var currentSpread: SpreadSnapshot?
    private var nextSpread: SpreadSnapshot?
    private var prevSpread: SpreadSnapshot?

    private var currentImage: UIImage?
    private var targetImage: UIImage?
    private var lastRenderedStateHash: Int?

    private enum TurnDirection { case none, next, prev }
    private var turnDirection: TurnDirection = .none
    private var isDragging = false
    private var isAnimating = false
    private var boundaryHitDir: TurnDirection = .none

    private let touchSlop: CGFloat = 10
    private var downPoint: CGPoint = .zero
    private var touchX: CGFloat = 0
    private var touchY: CGFloat = 0
    private var cornerY: CGFloat = 0
    private var lastTouchPoint: CGPoint = .zero
    private var lastTouchTime: CFTimeInterval = 0
    private var velocityX: CGFloat = 0

    // CADisplayLink animation state
    private var displayLink: CADisplayLink?
    private var animStartTime: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0.4
    private var animStartX: CGFloat = 0
    private var animStartY: CGFloat = 0
    private var animEndX: CGFloat = 0
    private var animEndY: CGFloat = 0
    private var animArcLift: CGFloat = 0
    private var animCommit: Bool = false
    private var animDir: TurnDirection = .none

    private var lastReportedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isMultipleTouchEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let rightNext = isSwipeRightNext()
        let leftAction = rightNext ? #selector(handleKeyPrev) : #selector(handleKeyNext)
        let rightAction = rightNext ? #selector(handleKeyNext) : #selector(handleKeyPrev)
        return [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: leftAction),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: rightAction),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleKeyNext)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleKeyPrev)),
            UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(handleKeyNext)),
            UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(handleKeyPrev)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleKeyNext))
        ]
    }

    @objc private func handleKeyNext() { triggerTurnNextAnimated() }
    @objc private func handleKeyPrev() { triggerTurnPrevAnimated() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
        } else {
            stopDisplayLink()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sz = bounds.size
        guard sz.width > 10 && sz.height > 10 else { return }
        if sz != lastReportedSize {
            lastReportedSize = sz
            cornerY = sz.height
            lastRenderedStateHash = nil
            onViewportReady?(sz.width, sz.height)
            currentImage = renderSpread(currentSpread)
            setNeedsDisplay()
        }
    }

    func updateState(
        newSettings: ReaderSettings,
        bookTitle: String,
        totalChapters: Int,
        currentSpread: SpreadSnapshot?,
        nextSpread: SpreadSnapshot?,
        prevSpread: SpreadSnapshot?
    ) {
        self.settings = newSettings
        self.bookTitle = bookTitle
        self.totalChapters = max(1, totalChapters)
        self.currentSpread = currentSpread
        self.nextSpread = nextSpread
        self.prevSpread = prevSpread

        guard bounds.width > 10 && bounds.height > 10 && !isDragging && !isAnimating else { return }

        var hasher = Hasher()
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        hasher.combine(bookTitle)
        hasher.combine(totalChapters)
        hasher.combine(currentSpread?.chapterIndex)
        hasher.combine(currentSpread?.chapterTitle)
        hasher.combine(currentSpread?.firstPage?.pageIndex)
        hasher.combine(currentSpread?.firstPage?.startOffset)
        hasher.combine(currentSpread?.secondPage?.pageIndex)
        hasher.combine(currentSpread?.totalPagesInChapter)
        hasher.combine(newSettings.writingMode)
        hasher.combine(newSettings.dualPageMode)
        hasher.combine(newSettings.showSpineShadow)
        hasher.combine(newSettings.eInkMode)
        hasher.combine(newSettings.theme)
        hasher.combine(newSettings.fontSizeSp)
        hasher.combine(newSettings.fontBold)
        hasher.combine(newSettings.letterSpacingEm)
        hasher.combine(newSettings.lineSpacingMultiplier)
        hasher.combine(newSettings.paragraphSpacingEm)
        hasher.combine(newSettings.paragraphIndentChars)
        hasher.combine(newSettings.marginHorizontalDp)
        hasher.combine(newSettings.marginVerticalDp)
        hasher.combine(newSettings.customFontPath)
        hasher.combine(newSettings.chineseConvertMode)
        let stateHash = hasher.finalize()

        if stateHash != lastRenderedStateHash || currentImage == nil {
            lastRenderedStateHash = stateHash
            currentImage = renderSpread(currentSpread)
            setNeedsDisplay()
        }
    }

    func triggerTurnNextAnimated() {
        guard !isAnimating else { return }
        guard let target = nextSpread else {
            onBoundaryReached?(true)
            return
        }
        if settings.effectiveAnimation == .NONE {
            _ = onRequestNextSpread?()
            return
        }
        startAnimatedTapTurn(dir: .next, target: target)
    }

    func triggerTurnPrevAnimated() {
        guard !isAnimating else { return }
        guard let target = prevSpread else {
            onBoundaryReached?(false)
            return
        }
        if settings.effectiveAnimation == .NONE {
            _ = onRequestPrevSpread?()
            return
        }
        startAnimatedTapTurn(dir: .prev, target: target)
    }

    private func startAnimatedTapTurn(dir: TurnDirection, target: SpreadSnapshot) {
        turnDirection = dir
        if currentImage == nil {
            currentImage = renderSpread(currentSpread)
        }
        targetImage = renderSpread(target)

        let w = bounds.width
        let h = bounds.height
        let fromLeft = isCurlFromLeftEdge(dir)
        cornerY = h

        if settings.effectiveAnimation == .SLIDE {
            let startX = fromLeft ? (w * 0.04) : (w * 0.96)
            let endX = fromLeft ? w : 0
            touchX = startX
            touchY = h * 0.72
            animateTurnXY(startX: startX, startY: touchY, endX: endX, endY: touchY, arcLift: 0, commit: true, duration: 0.44)
        } else {
            let startX = fromLeft ? (w * 0.05) : (w * 0.95)
            let endX = fromLeft ? (w * 2.15) : (-w * 1.15)
            let startY = h * 0.94
            let endY = h - 22
            touchX = startX
            touchY = startY
            animateTurnXY(startX: startX, startY: startY, endX: endX, endY: endY, arcLift: h * 0.22, commit: true, duration: 0.52)
        }
    }

    private func isSwipeRightNext() -> Bool {
        settings.writingMode == .VERTICAL && settings.verticalNaturalSwipe
    }

    private func isCurlFromLeftEdge(_ dir: TurnDirection) -> Bool {
        if isSwipeRightNext() {
            return dir == .next
        } else {
            return dir == .prev
        }
    }

    private func renderSpread(_ spread: SpreadSnapshot?) -> UIImage? {
        guard bounds.width > 10 && bounds.height > 10 else { return nil }
        let (font, needsSyntheticBold) = FontManager.resolveReaderFont(
            size: CGFloat(settings.fontSizeSp),
            bold: settings.fontBold,
            customFontPath: settings.customFontPath
        )
        return SpreadRenderer.renderSpreadImage(
            size: bounds.size,
            scale: traitCollection.displayScale,
            settings: settings,
            bookTitle: bookTitle,
            chapterTitle: spread?.chapterTitle ?? "",
            firstPage: spread?.firstPage,
            secondPage: spread?.secondPage,
            totalPagesInChapter: max(1, spread?.totalPagesInChapter ?? 1),
            chapterIndex: spread?.chapterIndex ?? 0,
            totalChapters: totalChapters,
            font: font,
            needsSyntheticBold: needsSyntheticBold
        )
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isAnimating, let t = touches.first else { return }
        let pt = t.location(in: self)
        downPoint = pt
        touchX = pt.x
        touchY = pt.y
        lastTouchPoint = pt
        lastTouchTime = CACurrentMediaTime()
        velocityX = 0
        cornerY = (pt.y < bounds.height * 0.32) ? 0 : bounds.height
        isDragging = false
        turnDirection = .none
        boundaryHitDir = .none
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isAnimating, let t = touches.first else { return }
        let pt = t.location(in: self)
        let now = CACurrentMediaTime()
        let dt = now - lastTouchTime
        if dt > 0.001 {
            let instVx = (pt.x - lastTouchPoint.x) / CGFloat(dt)
            velocityX = velocityX * 0.35 + instVx * 0.65
            lastTouchPoint = pt
            lastTouchTime = now
        }

        let dx = pt.x - downPoint.x
        let dy = pt.y - downPoint.y

        if !isDragging && abs(dx) > touchSlop && abs(dx) > abs(dy) * 0.6 {
            let swipingRight = dx > 0
            let candidateDir: TurnDirection
            if isSwipeRightNext() {
                candidateDir = swipingRight ? .next : .prev
            } else {
                candidateDir = swipingRight ? .prev : .next
            }

            let target: SpreadSnapshot? = {
                switch candidateDir {
                case .next: return nextSpread
                case .prev: return prevSpread
                case .none: return nil
                }
            }()

            if let target {
                isDragging = true
                turnDirection = candidateDir
                boundaryHitDir = .none
                if currentImage == nil {
                    currentImage = renderSpread(currentSpread)
                }
                targetImage = renderSpread(target)
            } else {
                boundaryHitDir = candidateDir
            }
        }

        if isDragging && turnDirection != .none {
            touchX = min(bounds.width, max(0, pt.x))
            touchY = min(bounds.height - 1, max(1, pt.y))
            if settings.effectiveAnimation != .NONE {
                setNeedsDisplay()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isAnimating, let t = touches.first else { return }
        finishTouch(at: t.location(in: self), cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isAnimating else { return }
        let pt = touches.first?.location(in: self) ?? lastTouchPoint
        finishTouch(at: pt, cancelled: true)
    }

    private func finishTouch(at pt: CGPoint, cancelled: Bool) {
        if !isDragging {
            if boundaryHitDir != .none {
                let hitEnd = boundaryHitDir == .next
                boundaryHitDir = .none
                onBoundaryReached?(hitEnd)
            } else if !cancelled {
                handleTapZone(x: pt.x, y: pt.y)
            }
            return
        }

        guard turnDirection != .none else { return }
        let dx = pt.x - downPoint.x
        let w = max(1, bounds.width)
        let curlFromLeft = isCurlFromLeftEdge(turnDirection)
        let movedEnough = curlFromLeft ? (dx > w * 0.12) : (-dx > w * 0.12)
        let flickedEnough = curlFromLeft ? (velocityX > 380) : (velocityX < -380)
        let shouldCommit = !cancelled && (movedEnough || flickedEnough)

        switch settings.effectiveAnimation {
        case .NONE:
            let dir = turnDirection
            resetTurnState()
            if shouldCommit {
                if dir == .next { _ = onRequestNextSpread?() }
                else { _ = onRequestPrevSpread?() }
            }
            setNeedsDisplay()

        case .SLIDE:
            let endX: CGFloat = shouldCommit
                ? (curlFromLeft ? w : 0)
                : (curlFromLeft ? 0 : w)
            let remainRatio = min(1.0, max(0.35, abs(endX - touchX) / w))
            animateTurnXY(
                startX: touchX, startY: touchY,
                endX: endX, endY: touchY,
                arcLift: 0,
                commit: shouldCommit,
                duration: max(0.20, 0.40 * Double(remainRatio))
            )

        case .SIMULATION:
            let fx: CGFloat = curlFromLeft ? 0 : w
            let endX: CGFloat = shouldCommit
                ? (curlFromLeft ? w * 2.15 : -w * 1.15)
                : fx
            let endY: CGFloat = cornerY > 0 ? (bounds.height - 22) : 22
            let totalTravel = max(1, w * 2.15)
            let remainRatio = min(1.0, max(0.45, abs(endX - touchX) / totalTravel))
            let dur = shouldCommit ? min(0.46, max(0.24, 0.44 * Double(remainRatio))) : 0.26
            animateTurnXY(
                startX: touchX, startY: touchY,
                endX: endX, endY: endY,
                arcLift: 0,
                commit: shouldCommit,
                duration: dur
            )
        }
    }

    private func handleTapZone(x: CGFloat, y: CGFloat) {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        _ = becomeFirstResponder()
        let col = min(2, max(0, Int((x / bounds.width) * 3.0)))
        let row = min(2, max(0, Int((y / bounds.height) * 3.0)))
        let idx = row * 3 + col
        let action = (idx < settings.tapZones.count) ? settings.tapZones[idx] : .TOGGLE_MENU

        switch action {
        case .PREV_PAGE:
            triggerTurnPrevAnimated()
        case .NEXT_PAGE:
            triggerTurnNextAnimated()
        case .TOGGLE_MENU:
            onToggleMenu?()
        }
    }

    // MARK: - ProMotion CADisplayLink Animator

    private func animateTurnXY(
        startX: CGFloat, startY: CGFloat,
        endX: CGFloat, endY: CGFloat,
        arcLift: CGFloat,
        commit: Bool,
        duration: CFTimeInterval
    ) {
        stopDisplayLink()
        isAnimating = true
        animStartTime = CACurrentMediaTime()
        animDuration = max(0.1, duration)
        animStartX = startX
        animStartY = startY
        animEndX = endX
        animEndY = endY
        animArcLift = arcLift
        animCommit = commit
        animDir = turnDirection

        let link = CADisplayLink(target: self, selector: #selector(onDisplayLinkTick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLinkTick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - animStartTime
        let rawProgress = CGFloat(min(1.0, max(0.0, elapsed / animDuration)))
        let p = PageCurlRenderer.smoothTurnInterpolate(rawProgress)
        let liftSign: CGFloat = cornerY > 0 ? -1 : 1

        touchX = animStartX + (animEndX - animStartX) * p
        let linearY = animStartY + (animEndY - animStartY) * p
        touchY = linearY + liftSign * animArcLift * sin(.pi * p)
        setNeedsDisplay()

        if rawProgress >= 1.0 {
            stopDisplayLink()
            let dir = animDir
            let commit = animCommit
            if commit, let tgt = targetImage {
                currentImage = tgt
            }
            resetTurnState()
            if commit {
                if dir == .next { _ = onRequestNextSpread?() }
                else if dir == .prev { _ = onRequestPrevSpread?() }
            }
            setNeedsDisplay()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func resetTurnState() {
        isDragging = false
        isAnimating = false
        turnDirection = .none
        boundaryHitDir = .none
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let curImg = currentImage else {
            ctx.setFillColor(settings.effectiveTheme.bgUIColor.cgColor)
            ctx.fill(bounds)
            return
        }

        if turnDirection == .none || settings.effectiveAnimation == .NONE {
            curImg.draw(in: bounds)
            return
        }

        guard let tgtImg = targetImage else {
            curImg.draw(in: bounds)
            return
        }

        let fromLeft = isCurlFromLeftEdge(turnDirection)
        switch settings.effectiveAnimation {
        case .SLIDE:
            PageCurlRenderer.drawSlideTransition(
                ctx: ctx,
                bounds: bounds,
                curImage: curImg,
                tgtImage: tgtImg,
                touchX: touchX,
                fromLeft: fromLeft
            )
        case .SIMULATION:
            PageCurlRenderer.drawRealisticBezierCurl(
                ctx: ctx,
                bounds: bounds,
                curImage: curImg,
                tgtImage: tgtImg,
                touchX: touchX,
                touchY: touchY,
                cornerY: cornerY,
                fromLeft: fromLeft,
                isDark: settings.effectiveTheme.isDark,
                pageBackColor: settings.effectiveTheme.pageBackUIColor
            )
        case .NONE:
            curImg.draw(in: bounds)
        }
    }
}

struct ReaderCanvasRepresentable: UIViewRepresentable {
    var settings: ReaderSettings
    var bookTitle: String
    var totalChapters: Int
    var currentSpread: SpreadSnapshot?
    var nextSpread: SpreadSnapshot?
    var prevSpread: SpreadSnapshot?
    var turnController: ReaderTurnController
    var onRequestNextSpread: () -> Bool
    var onRequestPrevSpread: () -> Bool
    var onToggleMenu: () -> Void
    var onBoundaryReached: (Bool) -> Void
    var onViewportReady: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderCanvasUIView {
        let view = ReaderCanvasUIView()
        bindCallbacks(view)
        return view
    }

    func updateUIView(_ uiView: ReaderCanvasUIView, context: Context) {
        bindCallbacks(uiView)
        uiView.updateState(
            newSettings: settings,
            bookTitle: bookTitle,
            totalChapters: totalChapters,
            currentSpread: currentSpread,
            nextSpread: nextSpread,
            prevSpread: prevSpread
        )
    }

    private func bindCallbacks(_ view: ReaderCanvasUIView) {
        view.onRequestNextSpread = onRequestNextSpread
        view.onRequestPrevSpread = onRequestPrevSpread
        view.onToggleMenu = onToggleMenu
        view.onBoundaryReached = onBoundaryReached
        view.onViewportReady = onViewportReady
        turnController.triggerNext = { [weak view] in view?.triggerTurnNextAnimated() }
        turnController.triggerPrev = { [weak view] in view?.triggerTurnPrevAnimated() }
    }
}
