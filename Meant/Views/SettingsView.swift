import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MeantViewModel

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "switch.2") }
            codex
                .tabItem { Label("Codex", systemImage: "person.crop.circle") }
        }
        .frame(width: 540, height: 430)
        .padding(18)
        .tint(MeantDesign.accent)
        .fontDesign(.rounded)
        .task {
            viewModel.refreshSystemState()
            await viewModel.refreshConnection()
        }
    }

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: MeantDesign.accent.opacity(0.16), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meant")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("Say what you meant.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Setup") {
                LabeledContent("Selection access") {
                    setupStatus(
                        ready: viewModel.isAccessibilityTrusted,
                        readyText: "Allowed",
                        missingText: "Not allowed"
                    )
                }
                Button(viewModel.isAccessibilityTrusted ? "Open Accessibility Settings" : "Allow Selection Access") {
                    viewModel.isAccessibilityTrusted
                        ? viewModel.openAccessibilitySettings()
                        : viewModel.requestAccessibilityAccess()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("Accessibility lets Meant read and replace selected text. If an app blocks replacement, Meant copies the result instead.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                LabeledContent("Codex") {
                    setupStatus(
                        ready: viewModel.isCodexReady,
                        readyText: viewModel.connectionLabel,
                        missingText: "Needs attention"
                    )
                }
            }

            Section("Shortcut") {
                LabeledContent("Use Meant on selection") {
                    ShortcutRecorder(shortcut: shortcutBinding)
                        .frame(width: 138, height: 30)
                }
                if let error = viewModel.shortcutError {
                    Text(error).foregroundStyle(MeantDesign.graphite)
                }
                LabeledContent("Capture page context") {
                    ShortcutRecorder(shortcut: contextShortcutBinding)
                        .frame(width: 138, height: 30)
                }
                if let error = viewModel.contextShortcutError {
                    Text(error).foregroundStyle(MeantDesign.graphite)
                }
                Text("Meant reads reliable context from the active window. If a page does not expose enough, focus the page and capture it before refining. Captured context is used once.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Meant at login", isOn: Binding(
                    get: { viewModel.loginItem.isEnabled },
                    set: { viewModel.loginItem.setEnabled($0) }
                ))
                if let error = viewModel.loginItem.errorMessage {
                    Text(error).foregroundStyle(MeantDesign.graphite)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var codex: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status", value: viewModel.connectionLabel)
                if let account = viewModel.account {
                    LabeledContent("Account", value: account.email ?? account.label)
                }
                if let model = viewModel.model {
                    LabeledContent("Refinement model", value: model.displayName)
                }
                LabeledContent("Reasoning effort", value: "Low")
            }

            Section {
                Text("Meant uses the local Codex app server and the ChatGPT account already signed in through Codex. It does not need an API key.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    if viewModel.account == nil {
                        Button("Sign in with ChatGPT") { viewModel.signIn() }
                            .buttonStyle(.borderedProminent)
                            .tint(MeantDesign.accent)
                    }
                    Button("Reconnect") { Task { await viewModel.refreshConnection() } }
                        .disabled(viewModel.isConnecting)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }

            Section("How it works") {
                Text("Meant uses GPT-5.6 Sol to refine the selected prompt and strengthen its emphasis. It replaces the selection when possible, with a clipboard fallback. It uses low reasoning effort with tools disabled.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setupStatus(ready: Bool, readyText: String, missingText: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? MeantDesign.accent : MeantDesign.graphite.opacity(0.45))
                .frame(width: 8, height: 8)
            Text(ready ? readyText : missingText)
                .foregroundStyle(ready ? MeantDesign.graphite.opacity(0.55) : MeantDesign.graphite)
                .lineLimit(1)
        }
    }

    private var shortcutBinding: Binding<GlobalShortcut> {
        Binding(
            get: { viewModel.preferences.shortcut },
            set: { viewModel.preferences.shortcut = $0 }
        )
    }

    private var contextShortcutBinding: Binding<GlobalShortcut> {
        Binding(
            get: { viewModel.preferences.contextShortcut },
            set: { viewModel.preferences.contextShortcut = $0 }
        )
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let view = ShortcutRecorderControl()
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderControl, context: Context) {
        view.shortcut = shortcut
        view.needsDisplay = true
    }
}

private final class ShortcutRecorderControl: NSView {
    var shortcut: GlobalShortcut = .default
    var onChange: ((GlobalShortcut) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 136, height: 30) }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }
        guard let value = GlobalShortcut(event: event) else {
            NSSound.beep()
            return
        }
        shortcut = value
        onChange?(value)
        isRecording = false
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        (isRecording ? NSColor.labelColor.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        (isRecording ? NSColor.labelColor.withAlphaComponent(0.7) : NSColor.separatorColor).setStroke()
        shape.lineWidth = isRecording ? 1.5 : 1
        shape.stroke()

        let text = isRecording ? "Type shortcut…" : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
