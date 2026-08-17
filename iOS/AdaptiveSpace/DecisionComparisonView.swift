import SwiftUI

struct DecisionComparisonView: View {
    let comparison: DecisionComparison
    let profile: EnvironmentProfile

    var body: some View {
        VStack(spacing: 16) {
            signalStrip
            decisionGrid
            policyOutput
        }
    }

    private var signalStrip: some View {
        GlassSurface(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    comparison.conflictDetected ? "상충 신호" : "신호 합의",
                    systemImage: comparison.conflictDetected ? "arrow.left.arrow.right" : "equal"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(comparison.conflictDetected ? AdaptiveDesign.warm : AdaptiveDesign.accent)

                HStack(spacing: 8) {
                    ForEach(comparison.signalEvidence, id: \.self) { evidence in
                        Text(evidence)
                            .font(.caption.monospaced().weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityIdentifier("comparisonSignals")
    }

    @ViewBuilder
    private var decisionGrid: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                decisionColumns
            }
        } else {
            decisionColumns
        }
    }

    private var decisionColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            decisionCard(
                label: "RULES",
                decision: comparison.ruleBased,
                tint: .white.opacity(0.04),
                identifier: "rulesDecision"
            )
            decisionCard(
                label: comparison.selected == "agent" ? "AGENT" : "FALLBACK",
                decision: comparison.agent,
                tint: comparison.selected == "agent"
                    ? AdaptiveDesign.cobalt.opacity(0.16)
                    : Color.white.opacity(0.04),
                identifier: "agentDecision"
            )
        }
    }

    private func decisionCard(
        label: String,
        decision: ContextDecision,
        tint: Color,
        identifier: String
    ) -> some View {
        GlassSurface(tint: tint, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(label)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(label == "AGENT" ? AdaptiveDesign.accent : .white.opacity(0.52))
                Text(contextTitle(decision.context))
                    .font(.title2.weight(.semibold))
                Text("\(Int(decision.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                Text(decision.evidence.first ?? "—")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .accessibilityIdentifier(identifier)
    }

    private var policyOutput: some View {
        GlassSurface(tint: AdaptiveDesign.accent.opacity(0.08), padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("POLICY OUTPUT")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(AdaptiveDesign.accent)
                    Spacer()
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(AdaptiveDesign.accent)
                }

                HStack(spacing: 12) {
                    outputValue("밝기", "\(profile.lighting.brightnessPercent)%")
                    outputValue("온도", "\(profile.temperatureC.formatted())°")
                    outputValue("사운드", profile.soundPreset.uppercased())
                }
            }
        }
        .accessibilityIdentifier("policyOutput")
    }

    private func outputValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextTitle(_ context: DemoScenario) -> String {
        switch context {
        case .recovery: "회복"
        case .focus: "집중"
        case .calm: "휴식"
        }
    }
}
