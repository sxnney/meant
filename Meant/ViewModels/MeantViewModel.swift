import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class MeantViewModel: ObservableObject {
    enum DeliveryState: Equatable {
        case pending
        case replaced
        case copied
    }

    enum OverlayState: Equatable {
        case hidden
        case acknowledging
        case transforming(InferredAction)
        case preview(InferredAction)
        case noSelection(String)
        case failed(String)
    }

    @Published private(set) var overlayState: OverlayState = .hidden
    @Published private(set) var sourceText = ""
    @Published private(set) var resultText = ""
    @Published private(set) var selectionBounds: CGRect?
    @Published private(set) var isStreaming = false
    @Published private(set) var deliveryState: DeliveryState = .pending
    @Published private(set) var progressMessage = "Refining your prompt"
    @Published private(set) var account: CodexAccount?
    @Published private(set) var model: CodexModel?
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionError: String?
    @Published private(set) var isAccessibilityTrusted = false
    @Published var shortcutError: String?

    let preferences: AppPreferences
    let loginItem = LoginItemController()
    var onDismiss: (() -> Void)?
    var onYieldFocus: (() -> Void)?

    private let selection: SelectionController
    private let codex: CodexAppServerClient
    private var snapshot: SelectionController.Snapshot?
    private var workTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var interactionID = UUID()
    private var sourceContext = ""
    private var previousProgressMessage: String?

    private static let progressMessages = [
        "Finding the clear version",
        "Tightening the idea",
        "Giving it more focus",
        "Clearing away the noise",
        "Making the point land",
        "Sharpening the thought",
        "Pulling it together",
        "Keeping what matters"
    ]

    private static let refinementAction = InferredAction(
        title: "Refined prompt",
        instruction: "Recover the intended prompt, refine it, and strengthen the emphasis where the source calls for it.",
        presentation: .preview
    )

    init() {
        let preferences = AppPreferences.shared
        let selection = SelectionController()
        self.preferences = preferences
        self.selection = selection
        codex = CodexAppServerClient()
        isAccessibilityTrusted = selection.isTrusted
    }

    var isVisible: Bool { overlayState != .hidden }
    var isCodexReady: Bool { account != nil && model != nil && connectionError == nil }
    var setupComplete: Bool { isAccessibilityTrusted && isCodexReady }

    var connectionLabel: String {
        if isConnecting { return "Connecting to Codex" }
        if let connectionError { return connectionError }
        if let account, let model { return "\(model.displayName) · \(account.label)" }
        return "ChatGPT sign-in required"
    }

    func beginInvocation() {
        stopCurrentWork()
        interactionID = UUID()
        let id = interactionID
        sourceText = ""
        resultText = ""
        deliveryState = .pending
        selectionBounds = nil
        snapshot = nil
        sourceContext = ""
        chooseProgressMessage()
        overlayState = .acknowledging

        isAccessibilityTrusted = selection.isTrusted
        guard isAccessibilityTrusted else {
            selection.requestAccess()
            selection.openAccessibilitySettings()
            overlayState = .noSelection("Enable Meant, then try again")
            scheduleDismiss(after: .seconds(2.8), interactionID: id)
            return
        }

        workTask = Task {
            let captured = await selection.capture()
            try? await Task.sleep(for: .milliseconds(90))
            guard interactionID == id, !Task.isCancelled else { return }
            snapshot = captured
            sourceText = captured.text
            sourceContext = captured.surroundingContext
            selectionBounds = captured.selectionBounds
            isAccessibilityTrusted = selection.isTrusted

            guard captured.hasSelection else {
                let message: String
                if !isAccessibilityTrusted {
                    message = "Enable Meant, then try again"
                } else if captured.selectionAppearsPresent {
                    message = "This app won't share its selection"
                } else {
                    message = "Select some text first"
                }
                overlayState = .noSelection(message)
                scheduleDismiss(after: .seconds(2.2), interactionID: id)
                return
            }

            await ensureConnection()
            guard interactionID == id, !Task.isCancelled else { return }
            guard account != nil else {
                overlayState = .failed("Sign in with ChatGPT in Meant Settings")
                return
            }

            if isCodex(captured.application),
               let conversation = try? await codex.recentConversationContext(windowTitle: captured.windowTitle) {
                sourceContext = [sourceContext, conversation.promptContext]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
            guard interactionID == id, !Task.isCancelled else { return }

            transform(using: Self.refinementAction)
        }
    }

    private func isCodex(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        return bundleIdentifier.contains("openai.codex")
            || bundleIdentifier == "com.openai.chat"
            || name == "codex"
            || name == "chatgpt"
    }

    func copyPreview() {
        guard case .preview = overlayState, !isStreaming, !resultText.isEmpty else { return }
        selection.copy(resultText)
        deliveryState = .copied
        scheduleDismiss(after: .seconds(3), interactionID: interactionID)
    }

    func retry() {
        guard !sourceText.isEmpty else {
            beginInvocation()
            return
        }
        let id = UUID()
        interactionID = id
        stopCurrentWork(keepState: true)
        transform(using: Self.refinementAction)
    }

    func cancelInteraction() {
        interactionID = UUID()
        stopCurrentWork()
        overlayState = .hidden
        onDismiss?()
    }

    func handleKey(code: CGKeyCode, flags: CGEventFlags) -> Bool {
        if code == CGKeyCode(kVK_Escape) {
            cancelInteraction()
            return true
        }

        switch overlayState {
        case .preview:
            if code == CGKeyCode(kVK_Return) || code == CGKeyCode(kVK_ANSI_KeypadEnter) {
                copyPreview()
                return true
            }
            if code == CGKeyCode(kVK_ANSI_C), flags.contains(.maskCommand) {
                copyPreview()
                return true
            }

        case .failed:
            if code == CGKeyCode(kVK_Return) || code == CGKeyCode(kVK_ANSI_KeypadEnter) {
                retry()
                return true
            }

        default:
            break
        }

        return false
    }

    func refreshSystemState() {
        isAccessibilityTrusted = selection.isTrusted
        loginItem.refresh()
        if setupComplete { preferences.hasCompletedOnboarding = true }
    }

    func refreshConnection() async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        defer {
            isConnecting = false
            if setupComplete { preferences.hasCompletedOnboarding = true }
        }

        do {
            account = try await codex.readAccount()
            model = account == nil ? nil : try await codex.solModel()
        } catch {
            account = nil
            model = nil
            connectionError = error.localizedDescription
        }
    }

    private func ensureConnection() async {
        if account != nil { return }
        if !isConnecting {
            await refreshConnection()
            return
        }

        for _ in 0..<80 {
            guard isConnecting else { return }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    func signIn() {
        Task {
            do {
                let url = try await codex.startChatGPTLogin()
                NSWorkspace.shared.open(url)
                isConnecting = true
                connectionError = nil
                defer { isConnecting = false }
                for _ in 0..<120 {
                    try await Task.sleep(for: .seconds(1))
                    if let value = try await codex.readAccount() {
                        account = value
                        model = try await codex.solModel()
                        if setupComplete { preferences.hasCompletedOnboarding = true }
                        return
                    }
                }
                connectionError = "ChatGPT sign-in did not finish."
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    func requestAccessibilityAccess() {
        isAccessibilityTrusted = selection.requestAccess()
        if !isAccessibilityTrusted { selection.openAccessibilitySettings() }
        if setupComplete { preferences.hasCompletedOnboarding = true }
    }

    func openAccessibilitySettings() {
        selection.openAccessibilitySettings()
    }

    private func transform(using action: InferredAction) {
        let id = UUID()
        interactionID = id
        stopCurrentWork(keepState: true)
        resultText = ""
        deliveryState = .pending
        isStreaming = true
        overlayState = .transforming(action)
        let source = sourceText
        let context = sourceContext

        workTask = Task {
            do {
                for try await delta in codex.transform(source: source, context: context, action: action) {
                    guard interactionID == id, !Task.isCancelled else { return }
                    resultText += delta
                }
                guard interactionID == id, !Task.isCancelled else { return }
                isStreaming = false
                guard !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    overlayState = .failed("Codex returned an empty result")
                    return
                }
                let delivery = await selection.replace(with: resultText, using: snapshot)
                guard interactionID == id, !Task.isCancelled else { return }
                deliveryState = delivery == .replaced ? .replaced : .copied
                overlayState = .preview(action)
                scheduleDismiss(after: .seconds(6), interactionID: id)
            } catch is CancellationError {
                if interactionID == id { isStreaming = false }
                return
            } catch {
                guard interactionID == id else { return }
                isStreaming = false
                overlayState = .failed(readable(error))
            }
        }
    }

    private func scheduleDismiss(after duration: Duration, interactionID id: UUID) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self.interactionID == id else { return }
            cancelInteraction()
        }
    }

    private func stopCurrentWork(keepState: Bool = false) {
        workTask?.cancel()
        workTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        codex.cancelAllTurns()
        isStreaming = false
        if !keepState { resultText = "" }
    }

    private func readable(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.count <= 72 { return message }
        return String(message.prefix(69)) + "…"
    }

    private func chooseProgressMessage() {
        let choices = Self.progressMessages.filter { $0 != previousProgressMessage }
        let message = choices.randomElement() ?? Self.progressMessages[0]
        previousProgressMessage = message
        progressMessage = message
    }
}
