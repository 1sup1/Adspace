import SwiftUI

enum AdaptiveDesign {
    static let canvas = Color(red: 0.025, green: 0.03, blue: 0.045)
    static let ink = Color(red: 0.055, green: 0.07, blue: 0.08)
    static let accent = Color(red: 0.73, green: 1.0, blue: 0.72)
    static let cobalt = Color(red: 0.35, green: 0.46, blue: 1.0)
    static let warm = Color(red: 1.0, green: 0.67, blue: 0.38)
    static let radius: CGFloat = 30
}

struct AmbientBackdrop: View {
    var body: some View {
        ZStack {
            AdaptiveDesign.canvas
            LinearGradient(
                colors: [Color.white.opacity(0.035), .clear, AdaptiveDesign.cobalt.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(AdaptiveDesign.cobalt.opacity(0.32))
                .frame(width: 300, height: 300)
                .blur(radius: 110)
                .offset(x: 170, y: -340)
            Circle()
                .fill(AdaptiveDesign.accent.opacity(0.13))
                .frame(width: 280, height: 280)
                .blur(radius: 120)
                .offset(x: -190, y: 360)
        }
        .ignoresSafeArea()
    }
}

struct GlassSurface<Content: View>: View {
    let tint: Color?
    let padding: CGFloat
    let content: Content

    init(tint: Color? = nil, padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
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
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

struct GlassMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(.horizontal, 16)
        .modifier(AdaptiveMetricGlassModifier())
    }
}

private struct AdaptiveMetricGlassModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: .rect(cornerRadius: 20))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

struct GlassTag: View {
    let text: String
    var tint = Color.white.opacity(0.08)

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
                    ProgressView().tint(AdaptiveDesign.ink)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
            }
            .font(.headline)
            .foregroundStyle(AdaptiveDesign.ink)
            .frame(maxWidth: .infinity)
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
                .buttonBorderShape(.roundedRectangle(radius: 22))
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
        .tint(.white)

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
