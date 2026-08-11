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

    var body: some View {
        Group {
            switch viewModel.overlayState {
            case .hidden:
                Color.clear
            case .acknowledging:
                MaterialTrace(label: viewModel.progressMessage)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func preview(_ action: InferredAction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(MeantDesign.graphite.opacity(0.72))
                Spacer()
                Label("Copied", systemImage: "checkmark")
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

            Divider().opacity(0.45).padding(.horizontal, 12)

            HStack(spacing: 18) {
                Button { viewModel.copyPreview() } label: { Label("Copy again", systemImage: "doc.on.doc") }
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
        .padding(.horizontal, 12)
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
        .padding(.horizontal, 12)
        .refractedSurface()
    }
}

private struct MaterialTrace: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(MeantDesign.accent)

                    Canvas { context, size in
                        let bandWidth = max(24, size.width * 0.28)
                        let progress = reduceMotion ? 0.5 : time.truncatingRemainder(dividingBy: 1.15) / 1.15
                        let x = CGFloat(progress) * (size.width + bandWidth) - bandWidth
                        let band = Path(CGRect(x: x, y: 1, width: bandWidth, height: size.height - 2))
                        context.fill(
                            band,
                            with: .linearGradient(
                                Gradient(colors: [
                                    .clear,
                                    MeantDesign.onAccent.opacity(0.34),
                                    .clear
                                ]),
                                startPoint: CGPoint(x: x, y: 0),
                                endPoint: CGPoint(x: x + bandWidth, y: 0)
                            )
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: 9) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(MeantDesign.onAccent)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { index in
                                let wave = reduceMotion ? 0.65 : (sin(time * 4.2 - Double(index) * 0.9) + 1) / 2
                                Circle()
                                    .fill(MeantDesign.onAccent)
                                    .frame(width: 3.5, height: 3.5)
                                    .opacity(0.28 + wave * 0.66)
                                    .scaleEffect(0.82 + wave * 0.18)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(MeantDesign.onAccent.opacity(0.22), lineWidth: 0.75)
                }
            }
        }
    }
}

private struct RefractedSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(MeantDesign.materialTint.opacity(0.46))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MeantDesign.graphite.opacity(0.10), lineWidth: 0.8)
            }
            .shadow(color: MeantDesign.graphite.opacity(0.10), radius: 14, y: 6)
    }
}

private struct ActionShardSurfaceModifier: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(selected ? MeantDesign.accent.opacity(0.055) : MeantDesign.materialTint.opacity(0.42))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? MeantDesign.accent.opacity(0.30) : MeantDesign.graphite.opacity(0.08), lineWidth: 0.8)
            }
            .shadow(color: MeantDesign.graphite.opacity(selected ? 0.09 : 0.045), radius: 7, y: 3)
    }
}

private extension View {
    func refractedSurface() -> some View {
        modifier(RefractedSurfaceModifier())
    }

    func actionShardSurface(selected: Bool) -> some View {
        modifier(ActionShardSurfaceModifier(selected: selected))
    }

    func softControl() -> some View {
        self
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(MeantDesign.graphite.opacity(0.055), in: Capsule())
    }
}
