import SwiftUI

enum MeantDesign {
    static let graphite = Color(nsColor: dynamicColor(
        light: NSColor(white: 0.08, alpha: 1),
        dark: NSColor(white: 0.94, alpha: 1)
    ))
    static let accent = graphite
    static let onAccent = Color(nsColor: dynamicColor(
        light: NSColor(white: 1, alpha: 1),
        dark: NSColor(white: 0.03, alpha: 1)
    ))
    static let materialTint = Color(nsColor: dynamicColor(
        light: NSColor(white: 1, alpha: 0.88),
        dark: NSColor(white: 0, alpha: 0.82)
    ))

    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

struct MeantMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(MeantDesign.accent)
            Path { path in
                path.move(to: CGPoint(x: size * 0.17, y: size * 0.67))
                path.addCurve(
                    to: CGPoint(x: size * 0.43, y: size * 0.74),
                    control1: CGPoint(x: size * 0.12, y: size * 0.87),
                    control2: CGPoint(x: size * 0.38, y: size * 0.88)
                )
                path.addCurve(
                    to: CGPoint(x: size * 0.32, y: size * 0.27),
                    control1: CGPoint(x: size * 0.53, y: size * 0.60),
                    control2: CGPoint(x: size * 0.17, y: size * 0.57)
                )
                path.addCurve(
                    to: CGPoint(x: size * 0.54, y: size * 0.66),
                    control1: CGPoint(x: size * 0.56, y: size * 0.15),
                    control2: CGPoint(x: size * 0.68, y: size * 0.44)
                )
                path.addCurve(
                    to: CGPoint(x: size * 0.84, y: size * 0.69),
                    control1: CGPoint(x: size * 0.58, y: size * 0.70),
                    control2: CGPoint(x: size * 0.69, y: size * 0.69)
                )
                path.move(to: CGPoint(x: size * 0.84, y: size * 0.63))
                path.addLine(to: CGPoint(x: size * 0.84, y: size * 0.75))
            }
            .stroke(
                MeantDesign.onAccent,
                style: StrokeStyle(
                    lineWidth: max(1.5, size * 0.068),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .frame(width: size, height: size)
    }
}

struct IntelligenceOverlayView: View {
    @ObservedObject var viewModel: MeantViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
                .id(stateIdentity)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                        removal: .opacity.combined(with: .scale(scale: 0.985))
                    )
                )
        }
        .animation(
            reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.3),
            value: stateIdentity
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch viewModel.overlayState {
            case .hidden:
                Color.clear
            case .acknowledging:
                MaterialTrace(label: viewModel.progressMessage)
            case .choosingContext:
                contextChoice
            case .waitingForContext(let message):
                contextWaiting(message)
            case .contextCaptured:
                messageSurface(viewModel.contextLabel ?? "Context captured", symbol: "checkmark")
            case .transforming:
                MaterialTrace(label: viewModel.progressMessage)
            case .preview(let action):
                preview(action)
            case .noSelection(let message):
                messageSurface(message, symbol: "selection.pin.in.out")
            case .failed(let message):
                failure(message)
            }
        }
    }

    private var stateIdentity: String {
        switch viewModel.overlayState {
        case .hidden: "hidden"
        case .acknowledging: "acknowledging"
        case .choosingContext: "choosingContext"
        case .waitingForContext: "waitingForContext"
        case .contextCaptured: "contextCaptured"
        case .transforming: "transforming"
        case .preview: "preview"
        case .noSelection: "message"
        case .failed: "failed"
        }
    }

    private var contextChoice: some View {
        HStack(spacing: 14) {
            Label("Prompt captured", systemImage: "checkmark")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MeantDesign.graphite.opacity(0.68))
                .lineLimit(1)

            Spacer(minLength: 8)

            actionHint(key: "↩", label: "Refine now", primary: true)
            actionHint(key: "select text", label: "Add context", primary: false)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refractedSurface()
    }

    private func contextWaiting(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MeantDesign.graphite.opacity(0.72))

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.contextLabel == nil ? "Waiting for context" : "Context detected")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MeantDesign.graphite)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(MeantDesign.graphite.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            actionHint(key: "↩", label: "Capture", primary: true)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refractedSurface()
    }

    private func actionHint(key: String, label: String, primary: Bool) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 10.5, weight: primary ? .semibold : .medium))
        }
        .foregroundStyle(MeantDesign.graphite.opacity(primary ? 0.82 : 0.56))
    }

    private func preview(_ action: InferredAction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(MeantDesign.graphite.opacity(0.72))
                Spacer()
                if let contextLabel = viewModel.contextLabel {
                    contextCapsule(contextLabel)
                }
                Label(
                    viewModel.deliveryState == .replaced ? "Replaced" : "Copied",
                    systemImage: "checkmark"
                )
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(MeantDesign.accent)
                    .padding(.horizontal, 9)
                    .frame(height: 23)
                    .background(MeantDesign.accent.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)

            ScrollView {
                Text(viewModel.resultText)
                    .textSelection(.enabled)
                    .font(.system(size: 13, design: .rounded))
                    .lineSpacing(3.5)
                    .foregroundStyle(MeantDesign.graphite)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
            }

            Divider().opacity(0.35).padding(.horizontal, 15)

            HStack(spacing: 18) {
                if viewModel.deliveryState == .replaced {
                    Button { viewModel.undoReplacement() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .softControl()
                    Button { viewModel.retry() } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .softControl()
                }
                Button { viewModel.copyPreview() } label: {
                    Label(
                        viewModel.deliveryState == .copied ? "Copy again" : "Copy",
                        systemImage: "doc.on.doc"
                    )
                }
                    .softControl()
                Spacer()
                Button { viewModel.cancelInteraction() } label: { Text("Close") }
                    .softControl()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(MeantDesign.graphite.opacity(0.62))
            .padding(.horizontal, 15)
            .frame(height: 36)
        }
        .refractedSurface()
    }

    private func contextCapsule(_ label: String) -> some View {
        Label(label, systemImage: "text.viewfinder")
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(MeantDesign.graphite.opacity(0.54))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(MeantDesign.graphite.opacity(0.055), in: Capsule())
            .help(viewModel.contextPreview ?? label)
    }

    private func messageSurface(_ message: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(MeantDesign.accent)
            Text(message)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(MeantDesign.graphite.opacity(0.78))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refractedSurface()
    }

    private func failure(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(MeantDesign.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MeantDesign.graphite)
                    .lineLimit(2)
                Text("Return to retry · Esc to close")
                    .font(.system(size: 9.5))
                    .foregroundStyle(MeantDesign.graphite.opacity(0.4))
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refractedSurface()
    }
}

private struct MaterialTrace: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private let cellDelays: [TimeInterval] = [
        0.09, 0.18, 0.27,
        0.00, 0.09, 0.18,
        0.09, 0.18, 0.27
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            HStack(spacing: 10) {
                PixelWave(elapsed: elapsed, delays: cellDelays, reduceMotion: reduceMotion)

                shimmeringLabel(elapsed: elapsed)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(elapsedLabel(elapsed))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(MeantDesign.graphite.opacity(0.42))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .refractedSurface()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(elapsedLabel(elapsed))")
        }
        .onAppear { startedAt = Date() }
    }

    private func shimmeringLabel(elapsed: TimeInterval) -> some View {
        let phase = reduceMotion ? 0.5 : elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4
        return Text(label)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(MeantDesign.graphite.opacity(0.48))
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        colors: [
                            MeantDesign.graphite.opacity(0.30),
                            MeantDesign.graphite,
                            MeantDesign.graphite.opacity(0.30)
                        ],
                        startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                        endPoint: UnitPoint(x: phase * 2, y: 0.5)
                    )
                    .mask {
                        Text(label)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                }
            }
    }

    private func elapsedLabel(_ elapsed: TimeInterval) -> String {
        if elapsed < 60 {
            return String(format: "%.1fs", elapsed)
        }
        let minutes = Int(elapsed) / 60
        return String(format: "%dm %.1fs", minutes, elapsed.truncatingRemainder(dividingBy: 60))
    }
}

private struct PixelWave: View {
    let elapsed: TimeInterval
    let delays: [TimeInterval]
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(MeantDesign.graphite)
                            .frame(width: 4, height: 4)
                            .opacity(opacity(for: delays[index]))
                    }
                }
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }

    private func opacity(for delay: TimeInterval) -> Double {
        guard !reduceMotion else { return 0.15 }
        let duration = 0.65
        var phase = (elapsed - delay).truncatingRemainder(dividingBy: duration)
        if phase < 0 { phase += duration }
        let pulse = pow(max(0, sin(.pi * phase / duration)), 5)
        return 0.15 + pulse * 0.85
    }
}

private struct RefractedSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
                .overlay(MeantDesign.materialTint.opacity(0.34))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MeantDesign.graphite.opacity(0.10), lineWidth: 0.8)
            }
    }
}

private extension View {
    func refractedSurface() -> some View {
        modifier(RefractedSurfaceModifier())
    }

    func softControl() -> some View {
        self
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(MeantDesign.graphite.opacity(0.055), in: Capsule())
    }

}
