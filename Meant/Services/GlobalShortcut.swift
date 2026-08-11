import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_I),
        carbonModifiers: UInt32(cmdKey),
        keyLabel: "I"
    )

    static let contextDefault = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_I),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "I"
    )

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        let meaningful = UInt32(controlKey | optionKey | cmdKey)
        guard modifiers & meaningful != 0 else { return nil }
        guard !Self.modifierKeyCodes.contains(event.keyCode) else { return nil }

        keyCode = UInt32(event.keyCode)
        carbonModifiers = modifiers
        keyLabel = Self.label(for: event)
    }

    var displayName: String {
        var value = ""
        if carbonModifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += keyLabel == "Space" ? "Space" : keyLabel
        return value
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { value.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { value.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { value.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { value.insert(.command) }
        return value
    }

    var menuKeyEquivalent: String {
        if keyLabel == "Space" { return " " }
        if keyLabel.count == 1 { return keyLabel.lowercased() }
        return ""
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var shortcut: GlobalShortcut {
        didSet { save(shortcut, key: Keys.shortcut) }
    }
    @Published var contextShortcut: GlobalShortcut {
        didSet { save(contextShortcut, key: Keys.contextShortcut) }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let shortcut = "globalShortcut"
        static let contextShortcut = "contextShortcut"
        static let onboarding = "completedOnboarding.v1"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.shortcut),
           let value = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            shortcut = value
        } else {
            shortcut = .default
        }
        if let data = defaults.data(forKey: Keys.contextShortcut),
           let value = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            contextShortcut = value
        } else {
            contextShortcut = .contextDefault
        }
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}

final class GlobalHotKeyManager {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcut: GlobalShortcut?
    private let action: () -> Void
    private let identifier: EventHotKeyID

    init(identifier: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.identifier = EventHotKeyID(signature: Self.fourCharacterCode("MENT"), id: identifier)
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userInfo in
                guard let userInfo else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                DispatchQueue.main.async { manager.action() }
                return noErr
            },
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> String? {
        stop()
        self.shortcut = shortcut
        let carbonStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        if let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown, manager.matches(event) else {
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { manager.action() }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            self.eventTap = eventTap
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        guard carbonStatus == noErr || self.eventTap != nil else {
            self.shortcut = nil
            return "Meant could not monitor the shortcut."
        }
        return nil
    }

    private func matches(_ event: CGEvent) -> Bool {
        guard let shortcut,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(shortcut.keyCode) else {
            return false
        }
        let flags = event.flags
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        return modifiers == shortcut.carbonModifiers
    }

    private func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        hotKey = nil
        shortcut = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }

    private static func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
