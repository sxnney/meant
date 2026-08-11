import AppKit

final class WorkflowHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 760, height: 440)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meant Workflow Test"
        window.center()

        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 18)
        textView.textContainerInset = NSSize(width: 34, height: 34)
        textView.string = "hey can you fix the codex integration because sometimes it hangs after streaming and also make sure cancellation really stops it but please don't rewrite all the architecture, i want it reliable and keep the existing subscription login"
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        self.window = window
    }
}

let app = NSApplication.shared
let delegate = WorkflowHostDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
