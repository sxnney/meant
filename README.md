# Meant

**Say what you meant.**

Meant is a quiet native macOS utility for people who work with ChatGPT and Codex. Select a rough prompt in any app, press one shortcut, and Meant turns it into the clear, emphatic prompt you intended. The result goes straight to the clipboard so you stay in control of where it is pasted.

Meant preserves facts, constraints, technical strings, voice, and deliberate emotional force. It removes transcript noise, filler, false starts, and accidental repetition.

## Use

1. Select a prompt in any application.
2. Press `Command-I`, or your configured shortcut.
3. Meant refines the prompt with GPT-5.6 Sol using low reasoning effort.
4. Paste the copied result where you want it.

The small progress surface stays near the selection and dismisses itself. Meant never replaces selected text.

## Requirements

- macOS 14 or later
- Codex CLI or the ChatGPT Mac app
- A ChatGPT account with GPT-5.6 access
- Accessibility permission for reading cross-app selections

Meant uses `codex app-server --stdio` and the ChatGPT account already signed in through Codex. It does not require an API key. Tools and network access are disabled during refinement.

## Install

Download the latest `Meant.zip` from [Releases](https://github.com/sxnney/meant/releases/latest), extract it, and move Meant to Applications. Future versions install through the built-in Sparkle updater.

## Build

```sh
xcodebuild -project Meant.xcodeproj -scheme Meant -configuration Debug \
  -derivedDataPath .derived CODE_SIGNING_ALLOWED=NO build
```

For a release build:

```sh
xcodebuild -project Meant.xcodeproj -scheme Meant -configuration Release \
  -derivedDataPath .release-derived build
```

Meant uses SwiftUI for transient surfaces and Settings. AppKit owns the global shortcut, menu-bar lifecycle, panel placement, Accessibility integration, and process control.

## License

MIT
