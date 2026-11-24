import CoreImage
import QuartzCore
import SwiftUI
import UIKit

struct VisualSpreadImages: Equatable {
    var firstPageIndex: Int
    var secondPageIndex: Int?
    var firstImage: UIImage?
    var secondImage: UIImage?
    var totalPages: Int

    static func == (lhs: VisualSpreadImages, rhs: VisualSpreadImages) -> Bool {
        lhs.firstPageIndex == rhs.firstPageIndex &&
        lhs.secondPageIndex == rhs.secondPageIndex &&
        lhs.firstImage === rhs.firstImage &&
        lhs.secondImage === rhs.secondImage &&
        lhs.totalPages == rhs.totalPages
    }
}

final class VisualPageCanvasUIView: UIView, UIGestureRecognizerDelegate {
    var onRequestNextSpread: (() -> Bool)?
    var onRequestPrevSpread: (() -> Bool)?
    var onToggleMenu: (() -> Void)?
    var onBoundaryReached: ((Bool) -> Void)?
    var onViewportReady: ((CGFloat, CGFloat, Bool) -> Void)?

    private var settings = ReaderSettings()
    private var isRtlFlow = true
    private var invertColors = false
    private var isDualPage = false

    private var currentSpread: VisualSpreadImages?
    private var nextSpread: VisualSpreadImages?
    private var prevSpread: VisualSpreadImages?

    private var currentBuffer: UIImage?
    private var targetBuffer: UIImage?
    private var lastRenderedKey: Int?

    private enum TurnDirection { case none, next, prev }
    private var turnDirection: TurnDirection = .none
    private var isDragging = false
    private var isAnimating = false
    private var boundaryHitDir: TurnDirection = .none

    // Zoom & pan state
    private var zoomScale: CGFloat = 1.0
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0
    private var isPinching = false
    private var lastPanPoint: CGPoint = .zero

    private let touchSlop: CGFloat = 10
    private var downPoint: CGPoint = .zero
    private var touchX: CGFloat = 0
    private var touchY: CGFloat = 0
    private var cornerY: CGFloat = 0
    private var lastTouchPoint: CGPoint = .zero
    private var lastTouchTime: CFTimeInterval = 0
    private var velocityX: CGFloat = 0

    // CADisplayLink animation
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
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isMultipleTouchEnabled = true
        contentMode = .redraw

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let leftAction = isRtlFlow ? #selector(handleKeyNext) : #selector(handleKeyPrev)
        let rightAction = isRtlFlow ? #selector(handleKeyPrev) : #selector(handleKeyNext)
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

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isAnimating else { return }
        switch gesture.state {
        case .began:
            isPinching = true
            isDragging = false
            turnDirection = .none
        case .changed:
            let oldScale = zoomScale
            let newScale = min(4.0, max(1.0, zoomScale * gesture.scale))
            gesture.scale = 1.0
            let focus = gesture.location(in: self)
            let center = CGPoint(x: bounds.width / 2.0, y: bounds.height / 2.0)
            let ratio = newScale / max(0.01, oldScale)
            panX = (focus.x - center.x) - ((focus.x - center.x) - panX) * ratio
            panY = (focus.y - center.y) - ((focus.y - center.y) - panY) * ratio
            zoomScale = newScale
            clampPan()
            setNeedsDisplay()
        default:
            isPinching = false
            if zoomScale < 1.05 {
                resetZoom()
                setNeedsDisplay()
            }
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isAnimating else { return }
        if zoomScale > 1.15 {
            resetZoom()
        } else {
            let pt = gesture.location(in: self)
            zoomScale = 2.2
            panX = (bounds.width / 2.0 - pt.x) * (zoomScale - 1.0)
            panY = (bounds.height / 2.0 - pt.y) * (zoomScale - 1.0)
            clampPan()
        }
        setNeedsDisplay()
    }

    func resetZoom() {
        zoomScale = 1.0
        panX = 0
        panY = 0
    }

    private func clampPan() {
        if zoomScale <= 1.01 {
            panX = 0
            panY = 0
            return
        }
        let maxPanX = bounds.width * (zoomScale - 1.0) / 2.0 + bounds.width * 0.08
        let maxPanY = bounds.height * (zoomScale - 1.0) / 2.0 + bounds.height * 0.08
        panX = min(maxPanX, max(-maxPanX, panX))
        panY = min(maxPanY, max(-maxPanY, panY))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sz = bounds.size
        guard sz.width > 10 && sz.height > 10 else { return }
        let newDual = ReaderLayoutMetrics.computeDualPage(widthPt: sz.width, heightPt: sz.height, mode: settings.dualPageMode)
        if sz != lastReportedSize || newDual != isDualPage {
            lastReportedSize = sz
            isDualPage = newDual
            cornerY = sz.height
            lastRenderedKey = nil
            onViewportReady?(sz.width, sz.height, isDualPage)
            currentBuffer = renderSpreadToImage(currentSpread)
            setNeedsDisplay()
        }
    }

    func updateState(
        newSettings: ReaderSettings,
        rtlFlow: Bool,
        invertPdfColors: Bool,
        current: VisualSpreadImages?,
        next: VisualSpreadImages?,
        prev: VisualSpreadImages?
    ) {
        let pageChanged = current?.firstPageIndex != currentSpread?.firstPageIndex
        self.settings = newSettings
        self.isRtlFlow = rtlFlow
        self.invertColors = invertPdfColors && !newSettings.eInkMode
        self.currentSpread = current
        self.nextSpread = next
        self.prevSpread = prev

        if pageChanged { resetZoom() }

        guard bounds.width > 10 && bounds.height > 10 else { return }
        let newDual = ReaderLayoutMetrics.computeDualPage(
            widthPt: bounds.width,
            heightPt: bounds.height,
            mode: newSettings.dualPageMode
        )
        if newDual != isDualPage {
            isDualPage = newDual
            onViewportReady?(bounds.width, bounds.height, isDualPage)
        }

        guard !isDragging && !isAnimating else { return }

        var hasher = Hasher()
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        hasher.combine(isDualPage)
        hasher.combine(isRtlFlow)
        hasher.combine(invertColors)
        hasher.combine(newSettings.eInkMode)
        hasher.combine(newSettings.showSpineShadow)
        hasher.combine(current?.firstPageIndex)
        hasher.combine(current?.secondPageIndex)
        hasher.combine(current?.firstImage.map { ObjectIdentifier($0) })
        hasher.combine(current?.secondImage.map { ObjectIdentifier($0) })
        hasher.combine(current?.totalPages)
        let key = hasher.finalize()

        if key != lastRenderedKey || currentBuffer == nil {
            lastRenderedKey = key
            currentBuffer = renderSpreadToImage(currentSpread)
            setNeedsDisplay()
        }
    }

    func triggerTurnNextAnimated() {
        guard !isAnimating else { return }
        resetZoom()
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
        resetZoom()
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

    private func startAnimatedTapTurn(dir: TurnDirection, target: VisualSpreadImages) {
        turnDirection = dir
        if currentBuffer == nil {
            currentBuffer = renderSpreadToImage(currentSpread)
        }
        targetBuffer = renderSpreadToImage(target)

        let w = bounds.width
        let h = bounds.height
        let fromLeft = isCurlFromLeftEdge(dir)
        cornerY = h

        if settings.effectiveAnimation == .SLIDE {
            let startX = fromLeft ? (w * 0.04) : (w * 0.96)
            let endX = fromLeft ? w : 0
            touchX = startX
            touchY = h * 0.72
            animateTurnXY(startX: startX, startY: touchY, endX: endX, endY: touchY, arcLift: 0, commit: true, duration: 0.42)
        } else {
            let startX = fromLeft ? (w * 0.05) : (w * 0.95)
            let endX = fromLeft ? (w * 2.15) : (-w * 1.15)
            let startY = h * 0.94
            let endY = h - 22
            touchX = startX
            touchY = startY
            animateTurnXY(startX: startX, startY: startY, endX: endX, endY: endY, arcLift: h * 0.22, commit: true, duration: 0.50)
        }
    }

    private func isCurlFromLeftEdge(_ dir: TurnDirection) -> Bool {
        isRtlFlow ? (dir == .next) : (dir == .prev)
    }

    // MARK: - Spread Buffer Rendering

    private func renderSpreadToImage(_ spread: VisualSpreadImages?) -> UIImage? {
        guard bounds.width > 10 && bounds.height > 10 else { return nil }
        let size = bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1.0, traitCollection.displayScale)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            let bgColor: UIColor = {
                if settings.eInkMode { return .white }
                if invertColors { return UIColor(hex: 0x121212) }
                return UIColor(hex: 0x1A1D21)
            }()
            ctx.setFillColor(bgColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))

            guard let spread, (spread.firstImage != nil || spread.secondImage != nil) else {
                let msg = "正在載入頁面…" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 15),
                    .foregroundColor: settings.eInkMode ? UIColor.black : UIColor.lightGray
                ]
                let mSz = msg.size(withAttributes: attrs)
                msg.draw(at: CGPoint(x: (size.width - mSz.width) / 2.0, y: (size.height - mSz.height) / 2.0), withAttributes: attrs)
                return
            }

            let footerReserve: CGFloat = 18
            let drawHeight = max(100, size.height - footerReserve)

            let img1 = spread.firstImage.map { invertColors ? invertImage($0) : $0 }
            let img2 = spread.secondImage.map { invertColors ? invertImage($0) : $0 }

            if !isDualPage {
                let dest = CGRect(x: 0, y: 0, width: size.width, height: drawHeight)
                if let img1 {
                    drawImageFit(img1, in: dest, alignRight: false, alignLeft: false)
                }
            } else {
                let centerX = size.width / 2.0
                let leftRect = CGRect(x: 0, y: 0, width: centerX, height: drawHeight)
                let rightRect = CGRect(x: centerX, y: 0, width: centerX, height: drawHeight)

                if isRtlFlow {
                    if let img1 { drawImageFit(img1, in: rightRect, alignRight: false, alignLeft: true) }
                    if let img2 { drawImageFit(img2, in: leftRect, alignRight: true, alignLeft: false) }
                } else {
                    if let img1 { drawImageFit(img1, in: leftRect, alignRight: true, alignLeft: false) }
                    if let img2 { drawImageFit(img2, in: rightRect, alignRight: false, alignLeft: true) }
                }

                if settings.effectiveSpineShadow {
                    SpreadRenderer.drawCenterSpineShadow(ctx: ctx, centerX: centerX, height: drawHeight, isDark: true)
                } else if settings.eInkMode {
                    ctx.saveGState()
                    ctx.setStrokeColor(UIColor(hex: 0xCCCCCC).cgColor)
                    ctx.setLineWidth(1.0)
                    ctx.move(to: CGPoint(x: centerX, y: 0))
                    ctx.addLine(to: CGPoint(x: centerX, y: drawHeight))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }

            let pageLabel: String
            if isDualPage, let secondIdx = spread.secondPageIndex {
                pageLabel = "\(spread.firstPageIndex + 1)-\(secondIdx + 1) / \(spread.totalPages)"
            } else {
                pageLabel = "\(spread.firstPageIndex + 1) / \(spread.totalPages)"
            }

            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: settings.eInkMode ? UIColor.darkGray : UIColor(hex: 0x9AA4B2)
            ]
            let nsLabel = pageLabel as NSString
            let lSz = nsLabel.size(withAttributes: footerAttrs)
            nsLabel.draw(
                at: CGPoint(x: size.width - 12 - lSz.width, y: size.height - lSz.height - 3),
                withAttributes: footerAttrs
            )
        }
    }

    private func drawImageFit(_ img: UIImage, in bounds: CGRect, alignRight: Bool, alignLeft: Bool) {
        let iw = img.size.width
        let ih = img.size.height
        guard iw > 0 && ih > 0 else { return }
        let scale = min(bounds.width / iw, bounds.height / ih)
        let dw = iw * scale
        let dh = ih * scale
        let left: CGFloat
        if alignRight {
            left = bounds.maxX - dw
        } else if alignLeft {
            left = bounds.minX
        } else {
            left = bounds.minX + (bounds.width - dw) / 2.0
        }
        let top = bounds.minY + (bounds.height - dh) / 2.0
        img.draw(in: CGRect(x: left, y: top, width: dw, height: dh))
    }

    private func invertImage(_ img: UIImage) -> UIImage {
        guard let cgImg = img.cgImage else { return img }
        let ciImg = CIImage(cgImage: cgImg)
        guard let filter = CIFilter(name: "CIColorInvert") else { return img }
        filter.setValue(ciImg, forKey: kCIInputImageKey)
        guard let outCI = filter.outputImage,
              let outCG = ciContext.createCGImage(outCI, from: ciImg.extent) else {
            return img
        }
        return UIImage(cgImage: outCG, scale: img.scale, orientation: img.imageOrientation)
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isAnimating, !isPinching, let t = touches.first else { return }
        let count = event?.allTouches?.count ?? touches.count
        if count > 1 { return }

        let pt = t.location(in: self)
        downPoint = pt
        lastPanPoint = pt
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
        guard !isAnimating, !isPinching, let t = touches.first else { return }
        if (event?.allTouches?.count ?? 1) > 1 {
            isDragging = false
            turnDirection = .none
            return
        }

        let pt = t.location(in: self)
        if zoomScale > 1.05 {
            if hypot(pt.x - downPoint.x, pt.y - downPoint.y) > touchSlop {
                isDragging = true
            }
            panX += pt.x - lastPanPoint.x
            panY += pt.y - lastPanPoint.y
            clampPan()
            lastPanPoint = pt
            setNeedsDisplay()
            return
        }

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
            let candidateDir: TurnDirection = isRtlFlow
                ? (swipingRight ? .next : .prev)
                : (swipingRight ? .prev : .next)

            let target: VisualSpreadImages? = {
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
                if currentBuffer == nil {
                    currentBuffer = renderSpreadToImage(currentSpread)
                }
                targetBuffer = renderSpreadToImage(target)
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
        guard !isAnimating, !isPinching, let t = touches.first else { return }
        let pt = t.location(in: self)
        if zoomScale > 1.05 {
            if !isDragging {
                let col = min(2, max(0, Int((pt.x / max(1, bounds.width)) * 3.0)))
                let row = min(2, max(0, Int((pt.y / max(1, bounds.height)) * 3.0)))
                let idx = row * 3 + col
                let act = (idx < settings.tapZones.count) ? settings.tapZones[idx] : .TOGGLE_MENU
                if act == .TOGGLE_MENU {
                    onToggleMenu?()
                }
            }
            isDragging = false
            return
        }
        finishPageTurnTouch(at: pt, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isAnimating else { return }
        if zoomScale > 1.05 {
            isDragging = false
            return
        }
        let pt = touches.first?.location(in: self) ?? lastTouchPoint
        finishPageTurnTouch(at: pt, cancelled: true)
    }

    private func finishPageTurnTouch(at pt: CGPoint, cancelled: Bool) {
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
            let endX: CGFloat = shouldCommit ? (curlFromLeft ? w : 0) : (curlFromLeft ? 0 : w)
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
            let endX: CGFloat = shouldCommit ? (curlFromLeft ? w * 2.15 : -w * 1.15) : fx
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
            if commit, let tgt = targetBuffer {
                currentBuffer = tgt
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
        guard let curBmp = currentBuffer else {
            ctx.setFillColor((settings.eInkMode ? UIColor.white : UIColor(hex: 0x1A1D21)).cgColor)
            ctx.fill(bounds)
            return
        }

        if zoomScale > 1.01 {
            ctx.setFillColor((settings.eInkMode ? UIColor.white : UIColor(hex: 0x121212)).cgColor)
            ctx.fill(bounds)
            ctx.saveGState()
            ctx.translateBy(x: bounds.width / 2.0 + panX, y: bounds.height / 2.0 + panY)
            ctx.scaleBy(x: zoomScale, y: zoomScale)
            ctx.translateBy(x: -bounds.width / 2.0, y: -bounds.height / 2.0)
            curBmp.draw(in: bounds)
            ctx.restoreGState()
            return
        }

        if turnDirection == .none || settings.effectiveAnimation == .NONE {
            curBmp.draw(in: bounds)
            return
        }

        guard let tgtBmp = targetBuffer else {
            curBmp.draw(in: bounds)
            return
        }

        let fromLeft = isCurlFromLeftEdge(turnDirection)
        switch settings.effectiveAnimation {
        case .SLIDE:
            PageCurlRenderer.drawSlideTransition(
                ctx: ctx,
                bounds: bounds,
                curImage: curBmp,
                tgtImage: tgtBmp,
                touchX: touchX,
                fromLeft: fromLeft
            )
        case .SIMULATION:
            PageCurlRenderer.drawRealisticBezierCurl(
                ctx: ctx,
                bounds: bounds,
                curImage: curBmp,
                tgtImage: tgtBmp,
                touchX: touchX,
                touchY: touchY,
                cornerY: cornerY,
                fromLeft: fromLeft,
                isDark: !settings.eInkMode,
                pageBackColor: settings.eInkMode ? .white : UIColor(hex: 0xE8E6E1)
            )
        case .NONE:
            curBmp.draw(in: bounds)
        }
    }
}

struct VisualPageCanvasRepresentable: UIViewRepresentable {
    var settings: ReaderSettings
    var rtlFlow: Bool
    var invertPdfColors: Bool
    var currentSpread: VisualSpreadImages?
    var nextSpread: VisualSpreadImages?
    var prevSpread: VisualSpreadImages?
    var turnController: ReaderTurnController
    var onRequestNextSpread: () -> Bool
    var onRequestPrevSpread: () -> Bool
    var onToggleMenu: () -> Void
    var onBoundaryReached: (Bool) -> Void
    var onViewportReady: (CGFloat, CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> VisualPageCanvasUIView {
        let view = VisualPageCanvasUIView()
        bindCallbacks(view)
        return view
    }

    func updateUIView(_ uiView: VisualPageCanvasUIView, context: Context) {
        bindCallbacks(uiView)
        uiView.updateState(
            newSettings: settings,
            rtlFlow: rtlFlow,
            invertPdfColors: invertPdfColors,
            current: currentSpread,
            next: nextSpread,
            prev: prevSpread
        )
    }

    private func bindCallbacks(_ view: VisualPageCanvasUIView) {
        view.onRequestNextSpread = onRequestNextSpread
        view.onRequestPrevSpread = onRequestPrevSpread
        view.onToggleMenu = onToggleMenu
        view.onBoundaryReached = onBoundaryReached
        view.onViewportReady = onViewportReady
        turnController.triggerNext = { [weak view] in view?.triggerTurnNextAnimated() }
        turnController.triggerPrev = { [weak view] in view?.triggerTurnPrevAnimated() }
    }
}
