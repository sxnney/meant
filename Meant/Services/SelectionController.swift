import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class SelectionController {
    struct SelectionGeometry: Equatable {
        let bounds: CGRect
        let finalLineBounds: CGRect
    }

    private struct WindowTextCandidate {
        let text: String
        let area: CGFloat
    }

    enum CaptureMethod: Sendable {
        case accessibility
        case clipboard
        case none
    }

    struct Snapshot {
        let text: String
        let application: NSRunningApplication?
        let focusedElement: AXUIElement?
        let selectedRange: CFRange?
        let selectionGeometry: SelectionGeometry?
        let selectionAppearsPresent: Bool
        let method: CaptureMethod
        let surroundingContext: String
        let windowTitle: String?

        var hasSelection: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    enum ReplacementResult: Equatable {
        case replaced
        case copied
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let value = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }

    func capture() async -> Snapshot {
        let element = focusedElement()
        let application = element.flatMap(applicationOwning) ?? NSWorkspace.shared.frontmostApplication
        let selectionAppearsPresent = selectedRangeLength(from: element) > 0

        if let element,
           let text = selectedText(from: element),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let geometry = selectedGeometry(from: element, selectedText: text)
            return Snapshot(
                text: text,
                application: application,
                focusedElement: element,
                selectedRange: selectedRange(from: element),
                selectionGeometry: geometry,
                selectionAppearsPresent: true,
                method: .accessibility,
                surroundingContext: context(for: element, application: application, selection: text),
                windowTitle: focusedWindowTitle(for: application)
            )
        }

        guard isTrusted else {
            return Snapshot(
                text: "",
                application: application,
                focusedElement: element,
                selectedRange: selectedRange(from: element),
                selectionGeometry: nil,
                selectionAppearsPresent: selectionAppearsPresent,
                method: .none,
                surroundingContext: context(for: element, application: application, selection: ""),
                windowTitle: focusedWindowTitle(for: application)
            )
        }

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(from: pasteboard)
        sendCommandKey(CGKeyCode(kVK_ANSI_C))
        try? await Task.sleep(for: .milliseconds(110))

        let copiedChangeCount = pasteboard.changeCount
        let text = copiedChangeCount != saved.changeCount ? pasteboard.string(forType: .string) ?? "" : ""
        saved.restore(to: pasteboard, ifCurrentChangeCount: copiedChangeCount)
        let geometry = selectedGeometry(from: element, selectedText: text)

        return Snapshot(
            text: text,
            application: application,
            focusedElement: element,
            selectedRange: selectedRange(from: element),
            selectionGeometry: geometry,
            selectionAppearsPresent: selectionAppearsPresent || !text.isEmpty,
            method: text.isEmpty ? .none : .clipboard,
            surroundingContext: context(for: element, application: application, selection: text),
            windowTitle: focusedWindowTitle(for: application)
        )
    }

    private func focusedWindowTitle(for application: NSRunningApplication?) -> String? {
        guard let application else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue else { return nil }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowValue as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else { return nil }
        return titleValue as? String
    }

    private func context(
        for element: AXUIElement?,
        application: NSRunningApplication?,
        selection: String
    ) -> String {
        var parts: [String] = []
        if let name = application?.localizedName { parts.append("Active app: \(name)") }
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if let element,
           !trimmedSelection.isEmpty,
           let value = textValue(from: element)?.trimmingCharacters(in: .whitespacesAndNewlines),
           value != trimmedSelection,
           let range = value.range(of: trimmedSelection) {
            let selectionOffset = value.distance(from: value.startIndex, to: range.lowerBound)
            let startOffset = max(0, selectionOffset - 2_000)
            let endOffset = min(value.count, selectionOffset + trimmedSelection.count + 2_000)
            let start = value.index(value.startIndex, offsetBy: startOffset)
            let end = value.index(value.startIndex, offsetBy: endOffset)
            parts.append("Surrounding editor content:\n\(value[start..<end])")
        }
        return parts.joined(separator: "\n\n")
    }

    private func activeWindowConversationText(
        for application: NSRunningApplication,
        excluding selection: String
    ) -> String? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue else { return nil }

        let window = windowValue as! AXUIElement
        var candidates: [WindowTextCandidate] = []
        collectScrollableTextCandidates(from: window, depth: 0, candidates: &candidates)
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let best = candidates
            .map({
                WindowTextCandidate(
                    text: cleanWindowText($0.text, excluding: trimmedSelection),
                    area: $0.area
                )
            })
            .filter({ $0.text.count >= 180 })
            .max(by: { $0.area < $1.area }) else { return nil }
        return String(best.text.suffix(18_000))
    }

    private func collectScrollableTextCandidates(
        from element: AXUIElement,
        depth: Int,
        candidates: inout [WindowTextCandidate]
    ) {
        guard depth < 18 else { return }
        let role = stringAttribute(kAXRoleAttribute, from: element)
        if role == kAXScrollAreaRole as String {
            var values: [String] = []
            collectReadableText(from: element, depth: 0, values: &values)
            let text = values.joined(separator: "\n")
            if !text.isEmpty {
                candidates.append(WindowTextCandidate(text: text, area: area(of: element)))
            }
        }
        for child in children(of: element) {
            collectScrollableTextCandidates(from: child, depth: depth + 1, candidates: &candidates)
        }
    }

    private func collectReadableText(
        from element: AXUIElement,
        depth: Int,
        values: inout [String]
    ) {
        guard depth < 22, values.count < 2_000 else { return }
        let role = stringAttribute(kAXRoleAttribute, from: element)
        if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String {
            if let value = stringAttribute(kAXValueAttribute, from: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty,
               values.last != value {
                values.append(value)
            }
        }
        for child in children(of: element) {
            collectReadableText(from: child, depth: depth + 1, values: &values)
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func area(of element: AXUIElement) -> CGFloat {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return 0 }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return 0 }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return 0 }
        return size.width * size.height
    }

    private func cleanWindowText(_ text: String, excluding selection: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != selection, result.last != value else { continue }
            result.append(value)
        }
        return result.joined(separator: "\n")
    }

    func replace(with text: String, using snapshot: Snapshot?) async -> ReplacementResult {
        guard let snapshot, snapshot.hasSelection else {
            copy(text)
            return .copied
        }

        guard await activate(snapshot.application) else {
            copy(text)
            return .copied
        }

        guard isTrusted else {
            copy(text)
            return .copied
        }

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount
        guard snapshot.application?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            saved.restore(to: pasteboard, ifCurrentChangeCount: replacementChangeCount)
            copy(text)
            return .copied
        }

        if let element = snapshot.focusedElement,
           elementBelongsToSnapshot(element, snapshot: snapshot) {
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }

        let valueBeforeReplacement = snapshot.focusedElement.flatMap(textValue)
        let rangeBeforeReplacement = snapshot.focusedElement.flatMap(selectedRange)

        sendCommandKey(CGKeyCode(kVK_ANSI_V))
        try? await Task.sleep(for: .milliseconds(280))

        if replacementSucceeded(
            using: snapshot,
            replacementText: text,
            valueBeforeReplacement: valueBeforeReplacement,
            rangeBeforeReplacement: rangeBeforeReplacement
        ) {
            saved.restore(to: pasteboard, ifCurrentChangeCount: replacementChangeCount)
            return .replaced
        }

        if let element = snapshot.focusedElement,
           elementBelongsToSnapshot(element, snapshot: snapshot),
           AXUIElementSetAttributeValue(
               element,
               kAXSelectedTextAttribute as CFString,
               text as CFTypeRef
           ) == .success {
            try? await Task.sleep(for: .milliseconds(80))
            if replacementSucceeded(
                using: snapshot,
                replacementText: text,
                valueBeforeReplacement: valueBeforeReplacement,
                rangeBeforeReplacement: rangeBeforeReplacement
            ) {
                saved.restore(to: pasteboard, ifCurrentChangeCount: replacementChangeCount)
                return .replaced
            }
        }

        saved.restore(to: pasteboard, ifCurrentChangeCount: replacementChangeCount)
        copy(text)
        return .copied
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func restoreApplication(from snapshot: Snapshot?) {
        snapshot?.application?.activate(options: [.activateAllWindows])
    }

    func undo(using snapshot: Snapshot?, replacementText: String) async -> Bool {
        guard let snapshot, await activate(snapshot.application), isTrusted else { return false }

        if let element = snapshot.focusedElement,
           let originalRange = snapshot.selectedRange,
           elementBelongsToSnapshot(element, snapshot: snapshot) {
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            var replacementRange = CFRange(
                location: originalRange.location,
                length: replacementText.utf16.count
            )
            if let rangeValue = AXValueCreate(.cfRange, &replacementRange),
               AXUIElementSetAttributeValue(
                   element,
                   kAXSelectedTextRangeAttribute as CFString,
                   rangeValue
               ) == .success,
               AXUIElementSetAttributeValue(
                   element,
                   kAXSelectedTextAttribute as CFString,
                   snapshot.text as CFTypeRef
               ) == .success {
                return true
            }
        }

        sendCommandKey(CGKeyCode(kVK_ANSI_Z))
        return true
    }

    private func focusedElement() -> AXUIElement? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func textValue(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func selectedGeometry(from element: AXUIElement?, selectedText: String) -> SelectionGeometry? {
        guard let element else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue else { return nil }

        var selectedRange = CFRange()
        let rangeAXValue = rangeValue as! AXValue
        guard AXValueGetType(rangeAXValue) == .cfRange,
              AXValueGetValue(rangeAXValue, .cfRange, &selectedRange),
              selectedRange.length > 0 else { return nil }

        let selectionBounds = rect(for: rangeValue, in: element)
        let text = selectedText as NSString
        var trailingNewlineCount = 0
        while trailingNewlineCount < min(text.length, selectedRange.length) {
            let character = text.character(at: text.length - trailingNewlineCount - 1)
            guard character == 10 || character == 13 else { break }
            trailingNewlineCount += 1
        }

        let finalCharacterOffset = selectedRange.length - trailingNewlineCount - 1
        var finalLineBounds: CGRect?
        if finalCharacterOffset >= 0 {
            var finalCharacterRange = CFRange(
                location: selectedRange.location + finalCharacterOffset,
                length: 1
            )
            if let value = AXValueCreate(.cfRange, &finalCharacterRange) {
                finalLineBounds = rect(for: value, in: element)
            }
        }

        if finalLineBounds == nil {
            var endRange = CFRange(
                location: selectedRange.location + selectedRange.length,
                length: 0
            )
            if let value = AXValueCreate(.cfRange, &endRange) {
                finalLineBounds = rect(for: value, in: element)
            }
        }

        guard let finalLineBounds else { return nil }
        return SelectionGeometry(
            bounds: selectionBounds ?? finalLineBounds,
            finalLineBounds: finalLineBounds
        )
    }

    private func rect(for rangeValue: CFTypeRef, in element: AXUIElement) -> CGRect? {
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success, let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        let axValue = boundsValue as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect),
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height > 0 else { return nil }
        return rect
    }

    private func selectedRangeLength(from element: AXUIElement?) -> Int {
        selectedRange(from: element)?.length ?? 0
    }

    private func selectedRange(from element: AXUIElement?) -> CFRange? {
        guard let element else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        let axValue = rangeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return CFRange(location: range.location, length: max(0, range.length))
    }

    private func applicationOwning(_ element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func elementBelongsToSnapshot(_ element: AXUIElement, snapshot: Snapshot) -> Bool {
        guard let expectedPID = snapshot.application?.processIdentifier else { return false }
        var elementPID: pid_t = 0
        return AXUIElementGetPid(element, &elementPID) == .success && elementPID == expectedPID
    }

    private func replacementSucceeded(
        using snapshot: Snapshot,
        replacementText: String,
        valueBeforeReplacement: String?,
        rangeBeforeReplacement: CFRange?
    ) -> Bool {
        guard let element = snapshot.focusedElement,
              elementBelongsToSnapshot(element, snapshot: snapshot) else { return false }

        if let before = valueBeforeReplacement,
           let after = textValue(from: element),
           before != after {
            if let range = rangeBeforeReplacement,
               let expected = Self.replacingUTF16Range(range, in: before, with: replacementText) {
                return after == expected || after.contains(replacementText)
            }
            return after.contains(replacementText)
        }

        return selectedText(from: element) == replacementText
    }

    static func replacingUTF16Range(_ range: CFRange, in source: String, with replacement: String) -> String? {
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= source.utf16.count else { return nil }
        return (source as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
    }

    private func activate(_ application: NSRunningApplication?) async -> Bool {
        guard let application, !application.isTerminated else { return false }
        application.activate(options: [.activateAllWindows])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func sendCommandKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
        up.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    let changeCount: Int
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: items)
    }

    func restore(to pasteboard: NSPasteboard, ifCurrentChangeCount expected: Int) {
        guard pasteboard.changeCount == expected else { return }
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { item.setData($1, forType: $0) }
            return item
        }
        pasteboard.clearContents()
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
