import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class IntelligenceOverlayController {
    private let panel: IntelligencePanel
    private let viewModel: MeantViewModel
    private let inputMonitor: OverlayInputMonitor
    private var anchorPoint = NSEvent.mouseLocation
    private var selectionRect: NSRect?
    private var placementSide: PlacementSide?
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
                viewModel?.cancelInteraction()
            }
        )

        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: IntelligenceOverlayView(viewModel: viewModel))

        viewModel.onDismiss = { [weak self] in self?.hide() }
        viewModel.onYieldFocus = { [weak self] in self?.yieldFocus() }

        viewModel.$selectionBounds
            .sink { [weak self] bounds in self?.updateSelectionAnchor(bounds) }
            .store(in: &cancellables)

        viewModel.$overlayState
            .removeDuplicates()
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
    }

    func invoke() {
        if viewModel.isVisible {
            viewModel.cancelInteraction()
            return
        }
        anchorPoint = NSEvent.mouseLocation
        selectionRect = nil
        placementSide = nil
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

        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewModel.overlayState == state else { return }
            self.panel.contentView = NSHostingView(
                rootView: IntelligenceOverlayView(viewModel: self.viewModel)
            )
        }
        let size = preferredSize(for: state)
        panel.ignoresMouseEvents = !stateAcceptsPointer(state)
        position(size: size, animated: panel.isVisible)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        beginInputCaptureAfterShortcut()
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

    private func yieldFocus() {
        inputCaptureWorkItem?.cancel()
        inputCaptureWorkItem = nil
        inputMonitor.stop()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func updateSelectionAnchor(_ bounds: CGRect?) {
        guard let bounds else { return }
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let converted = NSRect(
            x: bounds.minX,
            y: mainTop - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
        selectionRect = NSScreen.screens.contains(where: { $0.frame.intersects(converted) }) ? converted : nil
        placementSide = nil
        if viewModel.isVisible {
            position(size: preferredSize(for: viewModel.overlayState), animated: true)
        }
    }

    private func position(size: NSSize, animated: Bool) {
        let screen = targetScreen() ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let anchor = selectionRect ?? NSRect(x: anchorPoint.x, y: anchorPoint.y, width: 1, height: 1)
        if placementSide == nil {
            placementSide = bestPlacement(for: NSSize(width: 440, height: 460), anchor: anchor, visible: visible)
        }
        var origin = origin(for: placementSide ?? .below, size: size, anchor: anchor)

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        let frame = NSRect(origin: origin, size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private enum PlacementSide: CaseIterable {
        case below
        case above
        case right
        case left
    }

    private func bestPlacement(for size: NSSize, anchor: NSRect, visible: NSRect) -> PlacementSide {
        let safe = visible.insetBy(dx: 10, dy: 10)
        return PlacementSide.allCases.min { left, right in
            placementCost(left, size: size, anchor: anchor, safe: safe)
                < placementCost(right, size: size, anchor: anchor, safe: safe)
        } ?? .below
    }

    private func placementCost(_ side: PlacementSide, size: NSSize, anchor: NSRect, safe: NSRect) -> CGFloat {
        let proposed = origin(for: side, size: size, anchor: anchor)
        let clamped = NSPoint(
            x: min(max(proposed.x, safe.minX), safe.maxX - size.width),
            y: min(max(proposed.y, safe.minY), safe.maxY - size.height)
        )
        let displacement = hypot(clamped.x - proposed.x, clamped.y - proposed.y)
        let frame = NSRect(origin: clamped, size: size)
        let overlap = frame.intersection(anchor)
        let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
        let preference: CGFloat = side == .below ? 0 : side == .above ? 2 : 5
        return displacement * 8 + overlapArea * 20 + preference
    }

    private func origin(for side: PlacementSide, size: NSSize, anchor: NSRect) -> NSPoint {
        let gap: CGFloat = 12
        switch side {
        case .below:
            return NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - gap)
        case .above:
            return NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .right:
            return NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .left:
            return NSPoint(x: anchor.minX - size.width - gap, y: anchor.midY - size.height / 2)
        }
    }

    private func targetScreen() -> NSScreen? {
        if let selectionRect,
           let match = NSScreen.screens.first(where: { $0.frame.intersects(selectionRect) }) {
            return match
        }
        return NSScreen.screens.first(where: { NSMouseInRect(anchorPoint, $0.frame, false) }) ?? NSScreen.main
    }

    private func preferredSize(for state: MeantViewModel.OverlayState) -> NSSize {
        switch state {
        case .hidden: NSSize(width: 1, height: 1)
        case .acknowledging: NSSize(width: 220, height: 34)
        case .transforming: NSSize(width: 260, height: 36)
        case .preview:
            NSSize(width: 440, height: previewHeight)
        case .noSelection: NSSize(width: 248, height: 42)
        case .failed: NSSize(width: 340, height: 64)
        }
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

private final class IntelligencePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverlayInputMonitor {
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
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

    func stop() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localKeyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

}
