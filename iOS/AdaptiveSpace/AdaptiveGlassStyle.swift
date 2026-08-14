import SwiftUI

enum AdaptiveDesign {
    static let accent = Color(red: 0.38, green: 0.31, blue: 0.98)
    static let aqua = Color(red: 0.20, green: 0.82, blue: 0.72)
    static let warm = Color(red: 1.00, green: 0.69, blue: 0.35)
    static let radius: CGFloat = 28
}

struct AmbientBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [
                    AdaptiveDesign.accent.opacity(0.18),
                    AdaptiveDesign.aqua.opacity(0.11),
                    Color(.systemBackground).opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(AdaptiveDesign.accent.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 72)
                .offset(x: -150, y: -300)
            Circle()
                .fill(AdaptiveDesign.aqua.opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 76)
                .offset(x: 170, y: 240)
        }
        .ignoresSafeArea()
    }
}

struct GlassSurface<Content: View>: View {
    let tint: Color?
    @ViewBuilder let content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .modifier(AdaptiveGlassSurfaceModifier(tint: tint))
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: AdaptiveDesign.radius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: AdaptiveDesign.radius))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AdaptiveDesign.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: AdaptiveDesign.radius)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }
        }
    }
}

struct GlassMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .modifier(AdaptiveMetricGlassModifier())
    }
}

private struct AdaptiveMetricGlassModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct GlassTag: View {
    let text: String
    var tint = AdaptiveDesign.accent.opacity(0.16)

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(AdaptiveTagGlassModifier(tint: tint))
    }
}

private struct AdaptiveTagGlassModifier: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: .capsule)
        } else {
            content.background(tint, in: Capsule())
        }
    }
}

struct GlassPrimaryButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .disabled(isLoading)

        if #available(iOS 26.0, *) {
            button
                .buttonStyle(.glassProminent)
                .tint(AdaptiveDesign.accent)
        } else {
            button
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 18))
                .tint(AdaptiveDesign.accent)
        }
    }
}

struct GlassSecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .controlSize(.regular)

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

