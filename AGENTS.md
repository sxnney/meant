# Agent Guide

Meant is a native macOS app built with SwiftUI and AppKit.

- Keep global shortcuts, panel behavior, Accessibility APIs, and process control in AppKit service types.
- Keep the main interface in SwiftUI.
- Use `codex app-server --stdio` for Codex integration. Do not add an API-key flow unless the user asks for one.
- Preserve the selected text and the active app when the panel opens.
- Build with `xcodebuild -project Meant.xcodeproj -scheme Meant -configuration Debug CODE_SIGNING_ALLOWED=NO build` before finishing a change.

