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
    private var visibilityGeneration: UInt = 0
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
            },
            selectionFinishedHandler: { [weak panel, weak viewModel] in
                guard let panel, panel.isVisible,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                viewModel?.detectContextSelection()
            }
        )

        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .popUpMenu
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
            .sink { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.viewModel.overlayState == state else { return }
                    self.render(state)
                }
            }
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
        visibilityGeneration &+= 1
        let size = preferredSize(for: state)
        panel.ignoresMouseEvents = !stateAcceptsPointer(state)
        if placementSession == nil {
            placementSession = makePlacementSession(anchor: pendingAnchor)
        }
        applyFrame(size: size, animated: wasVisible)
        if !wasVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
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
            if case .choosingContext = state {
                inputMonitor.startPassiveChoiceCapture()
            } else if case .waitingForContext = state {
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
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      self.visibilityGeneration == generation,
                      self.viewModel.overlayState == .hidden else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    private struct SelectionAnchor {
        let bounds: NSRect
        let finalLineBounds: NSRect
        let screen: NSScreen
    }

    private struct PlacementSession {
        let edge: PlacementEdge
        let safeFrame: NSRect
        let maximumHeight: CGFloat
        let fixedX: CGFloat
        let fixedY: CGFloat
    }

    private enum PlacementEdge {
        case below
        case above
        case fallback
    }

    private func captureSelectionAnchor(_ geometry: SelectionController.SelectionGeometry?) {
        guard placementSession == nil, let geometry else { return }
        let primaryTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY
            ?? 0
        let bounds = convertAccessibilityRect(geometry.bounds, primaryTop: primaryTop)
        let tail = convertAccessibilityRect(geometry.finalLineBounds, primaryTop: primaryTop)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(tail.center) })
            ?? screen(containingMostOf: bounds) else { return }
        guard bounds.width > 0, bounds.height > 0,
              tail.height > 0,
              bounds.insetBy(dx: -Metrics.geometryTolerance, dy: -Metrics.geometryTolerance)
                .intersects(tail) else { return }
        pendingAnchor = SelectionAnchor(
            bounds: bounds,
            finalLineBounds: tail,
            screen: screen
        )
    }

    private func convertAccessibilityRect(_ rect: CGRect, primaryTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
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
        let maximumWidth = min(Metrics.maximumWidth, safe.width)

        guard let anchor else {
            return makeFallbackPlacementSession(
                point: fallbackPoint,
                safeFrame: safe,
                maximumWidth: maximumWidth
            )
        }

        let gap = Metrics.anchorGap
        let belowSpace = anchor.finalLineBounds.minY - safe.minY - gap
        let aboveSpace = safe.maxY - anchor.finalLineBounds.maxY - gap
        guard max(belowSpace, aboveSpace) >= Metrics.singleLineHeight else {
            return makeFallbackPlacementSession(
                point: anchor.finalLineBounds.center,
                safeFrame: safe,
                maximumWidth: maximumWidth
            )
        }

        let stableX = clamp(
            anchor.finalLineBounds.maxX - Metrics.anchorInset,
            minimum: safe.minX,
            maximum: safe.maxX - maximumWidth
        )

        let useBelow = belowSpace >= Metrics.minimumExpandedHeight
            || (aboveSpace < Metrics.minimumExpandedHeight && belowSpace >= aboveSpace)
        if useBelow {
            return PlacementSession(
                edge: .below,
                safeFrame: safe,
                maximumHeight: belowSpace,
                fixedX: stableX,
                fixedY: anchor.finalLineBounds.minY - gap
            )
        }
        return PlacementSession(
            edge: .above,
            safeFrame: safe,
            maximumHeight: aboveSpace,
            fixedX: stableX,
            fixedY: anchor.finalLineBounds.maxY + gap
        )
    }

    private func makeFallbackPlacementSession(
        point: NSPoint,
        safeFrame: NSRect,
        maximumWidth: CGFloat
    ) -> PlacementSession {
        let point = NSPoint(
            x: clamp(point.x, minimum: safeFrame.minX, maximum: safeFrame.maxX),
            y: clamp(point.y, minimum: safeFrame.minY, maximum: safeFrame.maxY)
        )
        let belowSpace = point.y - safeFrame.minY - Metrics.anchorGap
        let aboveSpace = safeFrame.maxY - point.y - Metrics.anchorGap
        let x = clamp(
            point.x - Metrics.anchorInset,
            minimum: safeFrame.minX,
            maximum: safeFrame.maxX - maximumWidth
        )
        let useBelow = belowSpace >= Metrics.minimumExpandedHeight
            || (aboveSpace < Metrics.minimumExpandedHeight && belowSpace >= aboveSpace)
        if useBelow {
            return PlacementSession(
                edge: .fallback,
                safeFrame: safeFrame,
                maximumHeight: max(Metrics.singleLineHeight, belowSpace),
                fixedX: x,
                fixedY: point.y - Metrics.anchorGap
            )
        }
        return PlacementSession(
            edge: .above,
            safeFrame: safeFrame,
            maximumHeight: max(Metrics.singleLineHeight, aboveSpace),
            fixedX: x,
            fixedY: point.y + Metrics.anchorGap
        )
    }

    private func fallbackScreen() -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(fallbackPoint, $0.frame, false) }) ?? NSScreen.main
    }

    private func applyFrame(size: NSSize, animated: Bool) {
        guard let placementSession else { return }
        let safe = placementSession.safeFrame
        let fittedSize = NSSize(
            width: min(size.width, safe.width),
            height: min(size.height, placementSession.maximumHeight)
        )
        var origin: NSPoint
        switch placementSession.edge {
        case .below, .fallback:
            origin = NSPoint(x: placementSession.fixedX, y: placementSession.fixedY - fittedSize.height)
        case .above:
            origin = NSPoint(x: placementSession.fixedX, y: placementSession.fixedY)
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
        static let minimumExpandedHeight: CGFloat = 220
        static let screenMargin: CGFloat = 12
        static let anchorGap: CGFloat = 10
        static let anchorInset: CGFloat = 24
        static let geometryTolerance: CGFloat = 12
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
        case .choosingContext, .waitingForContext, .contextCaptured, .acknowledging, .transforming:
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

        inputMonitor.start()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inputCaptureWorkItem = nil
            guard self.viewModel.isVisible else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
        inputCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
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
    private var selectionObservationTimer: Timer?
    private var leftButtonWasDown = false
    private var passiveCapturesReturn = false
    private var passiveObservesSelectionChanges = false
    private let keyHandler: (CGKeyCode, CGEventFlags) -> Bool
    private let outsideClickHandler: () -> Void
    private let selectionFinishedHandler: () -> Void

    var isStarted: Bool { localKeyMonitor != nil }

    init(
        keyHandler: @escaping (CGKeyCode, CGEventFlags) -> Bool,
        outsideClickHandler: @escaping () -> Void,
        selectionFinishedHandler: @escaping () -> Void
    ) {
        self.keyHandler = keyHandler
        self.outsideClickHandler = outsideClickHandler
        self.selectionFinishedHandler = selectionFinishedHandler
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
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return }
                if event.type == .leftMouseUp {
                    self.selectionFinishedHandler()
                } else {
                    self.outsideClickHandler()
                }
            }
        }
        startSelectionObservation()
    }

    private func startSelectionObservation() {
        guard selectionObservationTimer == nil else { return }
        leftButtonWasDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        selectionObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            if self.leftButtonWasDown && !isDown {
                self.selectionFinishedHandler()
            }
            self.leftButtonWasDown = isDown
        }
    }

    func startPassiveChoiceCapture() {
        startPassiveCapture(capturesReturn: true, observesSelectionChanges: true)
    }

    func startPassiveContextCapture() {
        startPassiveCapture(capturesReturn: true, observesSelectionChanges: false)
    }

    func startPassiveCancellationCapture() {
        startPassiveCapture(capturesReturn: false, observesSelectionChanges: false)
    }

    private func startPassiveCapture(capturesReturn: Bool, observesSelectionChanges: Bool) {
        stop()
        passiveCapturesReturn = capturesReturn
        passiveObservesSelectionChanges = observesSelectionChanges
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<OverlayInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .leftMouseUp {
                    if monitor.passiveObservesSelectionChanges {
                        DispatchQueue.main.async {
                            monitor.selectionFinishedHandler()
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                let isReturn = code == CGKeyCode(kVK_Return)
                    || code == CGKeyCode(kVK_ANSI_KeypadEnter)
                let isCommandA = code == CGKeyCode(kVK_ANSI_A) && flags.contains(.maskCommand)
                let isShiftSelection = flags.contains(.maskShift) && [
                    CGKeyCode(kVK_LeftArrow),
                    CGKeyCode(kVK_RightArrow),
                    CGKeyCode(kVK_UpArrow),
                    CGKeyCode(kVK_DownArrow),
                    CGKeyCode(kVK_Home),
                    CGKeyCode(kVK_End),
                    CGKeyCode(kVK_PageUp),
                    CGKeyCode(kVK_PageDown)
                ].contains(code)
                if monitor.passiveObservesSelectionChanges && (isCommandA || isShiftSelection) {
                    DispatchQueue.main.async {
                        monitor.selectionFinishedHandler()
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard code == CGKeyCode(kVK_Escape) || (monitor.passiveCapturesReturn && isReturn) else {
                    return Unmanaged.passUnretained(event)
                }
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
            if observesSelectionChanges { startSelectionObservation() }
            return
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let flags = event.cgEvent?.flags ?? []
            let code = CGKeyCode(event.keyCode)
            let isCommandA = code == CGKeyCode(kVK_ANSI_A) && flags.contains(.maskCommand)
            let isShiftSelection = flags.contains(.maskShift) && [
                CGKeyCode(kVK_LeftArrow),
                CGKeyCode(kVK_RightArrow),
                CGKeyCode(kVK_UpArrow),
                CGKeyCode(kVK_DownArrow)
            ].contains(code)
            if observesSelectionChanges && (isCommandA || isShiftSelection) {
                self.selectionFinishedHandler()
                return
            }
            let isReturn = event.keyCode == UInt16(kVK_Return)
                || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
            guard event.keyCode == UInt16(kVK_Escape) || (capturesReturn && isReturn) else { return }
            _ = self.keyHandler(code, flags)
        }
        if observesSelectionChanges { startSelectionObservation() }
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
        selectionObservationTimer?.invalidate()
        localKeyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        globalKeyMonitor = nil
        passiveRunLoopSource = nil
        passiveEventTap = nil
        passiveObservesSelectionChanges = false
        selectionObservationTimer = nil
        leftButtonWasDown = false
    }

}
