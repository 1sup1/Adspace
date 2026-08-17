import SwiftUI

struct CompanionConsensusView: View {
    let preferences: [ComfortPreference]
    let consensus: CompanionConsensus
    let isLoading: Bool
    let approve: () async -> Void
    let choose: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("함께 맞추기", systemImage: "person.2.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AdaptiveDesign.accent)
                Spacer()
                GlassTag(text: "\(preferences.count) JOINED")
            }

            participantGrid
            consensusCard

            if consensus.canApply {
                GlassPrimaryButton(
                    title: "함께 적용",
                    icon: "checkmark",
                    isLoading: isLoading
                ) {
                    Task { await approve() }
                }
                .accessibilityIdentifier("approveConsensus")
            } else {
                choiceButtons
            }
        }
    }

    @ViewBuilder
    private var participantGrid: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                participantColumns
            }
        } else {
            participantColumns
        }
    }

    private var participantColumns: some View {
        HStack(spacing: 12) {
            ForEach(preferences) { preference in
                GlassSurface(tint: Color.white.opacity(0.04), padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: preference.symbol)
                            .font(.headline)
                            .foregroundStyle(AdaptiveDesign.accent)
                        Text(preference.name)
                            .font(.headline)
                        rangeLine(
                            brightnessText(preference.brightnessRange),
                            temperatureText(preference.temperatureRange)
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                }
            }
        }
    }

    private var consensusCard: some View {
        GlassSurface(
            tint: consensus.canApply
                ? AdaptiveDesign.accent.opacity(0.08)
                : AdaptiveDesign.warm.opacity(0.1),
            padding: 20
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    consensus.canApply ? "공통 범위" : "합의 필요",
                    systemImage: consensus.canApply ? "checkmark.circle.fill" : "arrow.left.arrow.right"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(consensus.canApply ? AdaptiveDesign.accent : AdaptiveDesign.warm)

                if let brightness = consensus.brightnessPercent,
                   let temperature = consensus.temperatureC,
                   let brightnessRange = consensus.brightnessRange,
                   let temperatureRange = consensus.temperatureRange {
                    HStack(alignment: .lastTextBaseline, spacing: 24) {
                        consensusValue("밝기", "\(brightness)%")
                        consensusValue("온도", "\(temperature.formatted())°")
                    }
                    rangeLine(
                        brightnessText(brightnessRange),
                        temperatureText(temperatureRange)
                    )
                } else {
                    Text("범위를 선택하세요")
                        .font(.title3.weight(.semibold))
                }
            }
        }
        .accessibilityIdentifier("companionConsensus")
    }

    private var choiceButtons: some View {
        HStack(spacing: 8) {
            ForEach(preferences) { preference in
                GlassSecondaryButton(title: preference.name, icon: preference.symbol) {
                    Task { await choose(preference.id) }
                }
                .accessibilityIdentifier("choosePreference_\(preference.id)")
            }
        }
    }

    private func consensusValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rangeLine(_ brightness: String, _ temperature: String) -> some View {
        Text("\(brightness)  ·  \(temperature)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.56))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func brightnessText(_ range: ClosedRange<Int>) -> String {
        "\(range.lowerBound)–\(range.upperBound)%"
    }

    private func temperatureText(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound.formatted())–\(range.upperBound.formatted())°"
    }
}
