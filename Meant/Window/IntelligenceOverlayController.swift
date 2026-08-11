import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class IntelligenceOverlayController {
    private let panel: IntelligencePanel
    private let viewModel: MeantViewModel
    private let inputMonitor: OverlayInputMonitor
    private var fallbackPoint = NSEvent.mouseLocation
    private var pendingAnchor: SelectionAnchor?
    private var placementSession: PlacementSession?
    private var cancellables = Set<AnyCancellable>()
    private var inputCaptureWorkItem: DispatchWorkItem?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(viewModel: MeantViewModel) {
        self.viewModel = viewModel
        panel = IntelligencePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        inputMonitor = OverlayInputMonitor(
            keyHandler: { [weak viewModel] code, flags in
                viewModel?.handleKey(code: code, flags: flags) ?? false
            },
            outsideClickHandler: { [weak panel, weak viewModel] in
                guard let panel, panel.isVisible,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                viewModel?.handleOutsideClick()
            }
        )

        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = makeHostingView()
        applyPanelMask()

        viewModel.onDismiss = { [weak self] in self?.hide() }

        viewModel.$selectionGeometry
            .sink { [weak self] geometry in self?.captureSelectionAnchor(geometry) }
            .store(in: &cancellables)

        viewModel.$overlayState
            .removeDuplicates()
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)

    }

    func invoke() {
        if viewModel.handleRepeatedRefineShortcut() { return }
        if viewModel.isVisible {
            viewModel.cancelInteraction()
            return
        }
        fallbackPoint = NSEvent.mouseLocation
        pendingAnchor = nil
        placementSession = nil
        viewModel.beginInvocation()
    }

    func cancel() {
        viewModel.cancelInteraction()
    }

    private func render(_ state: MeantViewModel.OverlayState) {
        guard state != .hidden else {
            hide()
            return
        }

        let wasVisible = panel.isVisible
        let size = preferredSize(for: state)
        panel.ignoresMouseEvents = !stateAcceptsPointer(state)
        if placementSession == nil {
            placementSession = makePlacementSession(anchor: pendingAnchor)
        }
        applyFrame(size: size, animated: wasVisible)
        if !wasVisible {
            panel.contentView = makeHostingView()
            applyPanelMask()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        if case .waitingForContext = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, case .waitingForContext = self.viewModel.overlayState else { return }
                self.panel.orderFrontRegardless()
            }
        }
        if stateKeepsOriginalFocus(state) {
            inputCaptureWorkItem?.cancel()
            inputCaptureWorkItem = nil
            if case .waitingForContext = state {
                inputMonitor.startPassiveContextCapture()
            } else {
                inputMonitor.startPassiveCancellationCapture()
            }
        } else {
            beginInputCaptureAfterShortcut()
        }
    }

    private func makeHostingView() -> NSView {
        let hostingView = TransparentHostingView(
            rootView: IntelligenceOverlayView(viewModel: viewModel)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 18
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        return hostingView
    }

    private func applyPanelMask() {
        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = 18
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true

        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.cornerRadius = 18
        panel.contentView?.superview?.layer?.cornerCurve = .continuous
        panel.contentView?.superview?.layer?.masksToBounds = true
    }

    private func hide() {
        inputCaptureWorkItem?.cancel()
        inputCaptureWorkItem = nil
        inputMonitor.stop()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            DispatchQueue.main.async {
                panel?.orderOut(nil)
                panel?.alphaValue = 1
            }
        }
    }

    private struct SelectionAnchor {
        let bounds: NSRect
        let finalLineBounds: NSRect
        let screen: NSScreen
    }

    private struct PlacementSession {
        let side: PlacementSide
        let safeFrame: NSRect
        let maximumSize: NSSize
        let fixedX: CGFloat
        let fixedY: CGFloat
    }

    private enum PlacementSide {
        case below
        case above
        case right
        case left
        case fallback
    }

    private func captureSelectionAnchor(_ geometry: SelectionController.SelectionGeometry?) {
        guard placementSession == nil, let geometry else { return }
        let primaryTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY
            ?? 0
        let bounds = convertAccessibilityRect(geometry.bounds, primaryTop: primaryTop)
        let tail = convertAccessibilityRect(geometry.finalLineBounds, primaryTop: primaryTop)
        guard let screen = screen(containingMostOf: bounds) else { return }
        let normalizedBounds = normalize(bounds, scale: screen.backingScaleFactor)
        let normalizedTail = normalize(tail, scale: screen.backingScaleFactor)
        guard normalizedBounds.width > 0, normalizedBounds.height > 0 else { return }
        pendingAnchor = SelectionAnchor(
            bounds: normalizedBounds,
            finalLineBounds: normalizedTail,
            screen: screen
        )
    }

    private func convertAccessibilityRect(_ rect: CGRect, primaryTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private func normalize(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let unit = max(1, scale)
        func snapped(_ value: CGFloat) -> CGFloat { (value * unit).rounded() / unit }
        return NSRect(
            x: snapped(rect.minX),
            y: snapped(rect.minY),
            width: max(1 / unit, snapped(rect.width)),
            height: max(1 / unit, snapped(rect.height))
        )
    }

    private func screen(containingMostOf rect: NSRect) -> NSScreen? {
        guard let screen = NSScreen.screens.max(by: { first, second in
            intersectionArea(first.frame, rect) < intersectionArea(second.frame, rect)
        }), intersectionArea(screen.frame, rect) > 0 else { return nil }
        return screen
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func makePlacementSession(anchor: SelectionAnchor?) -> PlacementSession? {
        guard let screen = anchor?.screen ?? fallbackScreen(), !screen.visibleFrame.isEmpty else { return nil }
        let safe = screen.visibleFrame.insetBy(dx: Metrics.screenMargin, dy: Metrics.screenMargin)
        let reference = NSSize(
            width: min(Metrics.maximumWidth, safe.width),
            height: min(Metrics.minimumStableHeight, safe.height)
        )

        guard let anchor else {
            let x = safe.midX - reference.width / 2
            let top = safe.maxY - Metrics.fallbackTopInset
            return PlacementSession(
                side: .fallback,
                safeFrame: safe,
                maximumSize: NSSize(width: safe.width, height: top - safe.minY),
                fixedX: x,
                fixedY: top
            )
        }

        let gap = Metrics.anchorGap
        let belowSpace = anchor.bounds.minY - safe.minY - gap
        let aboveSpace = safe.maxY - anchor.bounds.maxY - gap
        let rightSpace = safe.maxX - anchor.bounds.maxX - gap
        let leftSpace = anchor.bounds.minX - safe.minX - gap
        let side: PlacementSide
        if belowSpace >= reference.height {
            side = .below
        } else if aboveSpace >= reference.height {
            side = .above
        } else if rightSpace >= reference.width {
            side = .right
        } else if leftSpace >= reference.width {
            side = .left
        } else {
            side = belowSpace >= aboveSpace ? .below : .above
        }

        let selectionEndX = anchor.finalLineBounds.maxX
        let stableX = clamp(
            selectionEndX - Metrics.anchorInset,
            minimum: safe.minX,
            maximum: safe.maxX - reference.width
        )
        let stableY = clamp(
            anchor.finalLineBounds.midY - min(Metrics.maximumHeight, safe.height) / 2,
            minimum: safe.minY,
            maximum: safe.maxY - min(Metrics.maximumHeight, safe.height)
        )

        switch side {
        case .below:
            let top = min(anchor.bounds.minY - gap, safe.maxY)
            return PlacementSession(
                side: side,
                safeFrame: safe,
                maximumSize: NSSize(width: safe.width, height: max(Metrics.singleLineHeight, top - safe.minY)),
                fixedX: stableX,
                fixedY: top
            )
        case .above:
            let bottom = max(anchor.bounds.maxY + gap, safe.minY)
            return PlacementSession(
                side: side,
                safeFrame: safe,
                maximumSize: NSSize(width: safe.width, height: max(Metrics.singleLineHeight, safe.maxY - bottom)),
                fixedX: stableX,
                fixedY: bottom
            )
        case .right:
            let left = clamp(
                anchor.bounds.maxX + gap,
                minimum: safe.minX,
                maximum: safe.maxX - reference.width
            )
            return PlacementSession(
                side: side,
                safeFrame: safe,
                maximumSize: NSSize(width: max(Metrics.singleLineHeight, safe.maxX - left), height: safe.height),
                fixedX: left,
                fixedY: stableY
            )
        case .left:
            let right = clamp(
                anchor.bounds.minX - gap,
                minimum: safe.minX + reference.width,
                maximum: safe.maxX
            )
            return PlacementSession(
                side: side,
                safeFrame: safe,
                maximumSize: NSSize(width: max(Metrics.singleLineHeight, right - safe.minX), height: safe.height),
                fixedX: right,
                fixedY: stableY
            )
        case .fallback:
            return nil
        }
    }

    private func fallbackScreen() -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(fallbackPoint, $0.frame, false) }) ?? NSScreen.main
    }

    private func applyFrame(size: NSSize, animated: Bool) {
        guard let placementSession else { return }
        let safe = placementSession.safeFrame
        let fittedSize = NSSize(
            width: min(size.width, placementSession.maximumSize.width),
            height: min(size.height, placementSession.maximumSize.height)
        )
        var origin: NSPoint
        switch placementSession.side {
        case .below, .fallback:
            origin = NSPoint(x: placementSession.fixedX, y: placementSession.fixedY - fittedSize.height)
        case .above, .right:
            origin = NSPoint(x: placementSession.fixedX, y: placementSession.fixedY)
        case .left:
            origin = NSPoint(x: placementSession.fixedX - fittedSize.width, y: placementSession.fixedY)
        }
        origin.x = clamp(origin.x, minimum: safe.minX, maximum: safe.maxX - fittedSize.width)
        origin.y = clamp(origin.y, minimum: safe.minY, maximum: safe.maxY - fittedSize.height)
        let frame = NSRect(origin: origin, size: fittedSize)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.3
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.23, 1, 0.32, 1
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), max(minimum, maximum))
    }

    private func preferredSize(for state: MeantViewModel.OverlayState) -> NSSize {
        switch state {
        case .hidden: NSSize(width: 1, height: 1)
        case .acknowledging: NSSize(width: 300, height: Metrics.singleLineHeight)
        case .choosingContext: NSSize(width: 430, height: Metrics.choiceHeight)
        case .waitingForContext: NSSize(width: 440, height: Metrics.twoLineHeight)
        case .contextCaptured: NSSize(width: 270, height: Metrics.singleLineHeight)
        case .transforming: NSSize(width: 300, height: Metrics.singleLineHeight)
        case .preview:
            NSSize(width: 440, height: previewHeight)
        case .noSelection: NSSize(width: 280, height: Metrics.singleLineHeight)
        case .failed: NSSize(width: 360, height: Metrics.twoLineHeight)
        }
    }

    private enum Metrics {
        static let singleLineHeight: CGFloat = 46
        static let choiceHeight: CGFloat = 52
        static let twoLineHeight: CGFloat = 64
        static let maximumWidth: CGFloat = 440
        static let maximumHeight: CGFloat = 460
        static let minimumStableHeight: CGFloat = 220
        static let screenMargin: CGFloat = 12
        static let anchorGap: CGFloat = 10
        static let anchorInset: CGFloat = 24
        static let fallbackTopInset: CGFloat = 36
    }

    private var previewHeight: CGFloat {
        let approximateLines = max(4, viewModel.resultText.count / 58 + viewModel.resultText.filter { $0 == "\n" }.count)
        return min(460, max(220, CGFloat(approximateLines) * 18 + 92))
    }

    private func stateAcceptsPointer(_ state: MeantViewModel.OverlayState) -> Bool {
        switch state {
        case .preview, .failed: true
        default: false
        }
    }

    private func stateKeepsOriginalFocus(_ state: MeantViewModel.OverlayState) -> Bool {
        switch state {
        case .waitingForContext, .contextCaptured, .acknowledging, .transforming:
            true
        default:
            false
        }
    }

    private func beginInputCaptureAfterShortcut() {
        if inputMonitor.isStarted {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard inputCaptureWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inputCaptureWorkItem = nil
            guard self.viewModel.isVisible else { return }
            self.inputMonitor.start()
            self.panel.makeKeyAndOrderFront(nil)
        }
        inputCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }
}

private final class IntelligencePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverlayInputMonitor {
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var passiveEventTap: CFMachPort?
    private var passiveRunLoopSource: CFRunLoopSource?
    private var passiveCapturesReturn = false
    private let keyHandler: (CGKeyCode, CGEventFlags) -> Bool
    private let outsideClickHandler: () -> Void

    var isStarted: Bool { localKeyMonitor != nil }

    init(
        keyHandler: @escaping (CGKeyCode, CGEventFlags) -> Bool,
        outsideClickHandler: @escaping () -> Void
    ) {
        self.keyHandler = keyHandler
        self.outsideClickHandler = outsideClickHandler
    }

    func start() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        globalKeyMonitor = nil
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let consumed = self.keyHandler(CGKeyCode(event.keyCode), event.cgEvent?.flags ?? [])
                guard !consumed else { return nil }

                return event
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.outsideClickHandler()
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.outsideClickHandler()
            }
        }
    }

    func startPassiveContextCapture() {
        startPassiveCapture(capturesReturn: true)
    }

    func startPassiveCancellationCapture() {
        startPassiveCapture(capturesReturn: false)
    }

    private func startPassiveCapture(capturesReturn: Bool) {
        stop()
        passiveCapturesReturn = capturesReturn
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard type == .keyDown, let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<OverlayInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let isReturn = code == CGKeyCode(kVK_Return)
                    || code == CGKeyCode(kVK_ANSI_KeypadEnter)
                guard code == CGKeyCode(kVK_Escape) || (monitor.passiveCapturesReturn && isReturn) else {
                    return Unmanaged.passUnretained(event)
                }
                let flags = event.flags
                DispatchQueue.main.async {
                    _ = monitor.keyHandler(code, flags)
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            passiveEventTap = tap
            passiveRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isReturn = event.keyCode == UInt16(kVK_Return)
                || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
            guard event.keyCode == UInt16(kVK_Escape) || (capturesReturn && isReturn) else { return }
            _ = self?.keyHandler(CGKeyCode(event.keyCode), event.cgEvent?.flags ?? [])
        }
    }

    func stop() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let passiveRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), passiveRunLoopSource, .commonModes)
        }
        if let passiveEventTap { CFMachPortInvalidate(passiveEventTap) }
        localKeyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        globalKeyMonitor = nil
        passiveRunLoopSource = nil
        passiveEventTap = nil
    }

}
