import Foundation

struct ComfortPreference: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let brightnessRange: ClosedRange<Int>
    let temperatureRange: ClosedRange<Double>
}

struct CompanionConsensus: Equatable, Sendable {
    let brightnessRange: ClosedRange<Int>?
    let temperatureRange: ClosedRange<Double>?
    let brightnessPercent: Int?
    let temperatureC: Double?

    var canApply: Bool {
        brightnessRange != nil && temperatureRange != nil
            && brightnessPercent != nil && temperatureC != nil
    }

    func profile(basedOn preferred: EnvironmentProfile) -> EnvironmentProfile? {
        guard let brightnessPercent, let temperatureC else { return nil }
        return EnvironmentProfile(
            lighting: LightingProfile(
                brightnessPercent: brightnessPercent,
                colorTemperatureK: preferred.lighting.colorTemperatureK
            ),
            temperatureC: temperatureC,
            soundPreset: preferred.soundPreset
        )
    }
}

enum CompanionConsensusEngine {
    static func resolve(
        _ preferences: [ComfortPreference],
        preferred: EnvironmentProfile
    ) -> CompanionConsensus {
        guard let first = preferences.first else {
            return CompanionConsensus(
                brightnessRange: nil,
                temperatureRange: nil,
                brightnessPercent: nil,
                temperatureC: nil
            )
        }

        let brightnessRange = preferences.dropFirst().reduce(first.brightnessRange as ClosedRange<Int>?) {
            intersection($0, $1.brightnessRange)
        }
        let temperatureRange = preferences.dropFirst().reduce(first.temperatureRange as ClosedRange<Double>?) {
            intersection($0, $1.temperatureRange)
        }

        return CompanionConsensus(
            brightnessRange: brightnessRange,
            temperatureRange: temperatureRange,
            brightnessPercent: brightnessRange.map {
                clamp(preferred.lighting.brightnessPercent, to: $0)
            },
            temperatureC: temperatureRange.map {
                clamp(
                    roundedHalfDegree(clamp(preferred.temperatureC, to: $0)),
                    to: $0
                )
            }
        )
    }

    static func profile(
        for preference: ComfortPreference,
        preferred: EnvironmentProfile
    ) -> EnvironmentProfile {
        EnvironmentProfile(
            lighting: LightingProfile(
                brightnessPercent: clamp(
                    preferred.lighting.brightnessPercent,
                    to: preference.brightnessRange
                ),
                colorTemperatureK: preferred.lighting.colorTemperatureK
            ),
            temperatureC: clamp(
                roundedHalfDegree(
                    clamp(preferred.temperatureC, to: preference.temperatureRange)
                ),
                to: preference.temperatureRange
            ),
            soundPreset: preferred.soundPreset
        )
    }

    private static func intersection<T: Comparable>(
        _ lhs: ClosedRange<T>?,
        _ rhs: ClosedRange<T>
    ) -> ClosedRange<T>? {
        guard let lhs else { return nil }
        let lower = max(lhs.lowerBound, rhs.lowerBound)
        let upper = min(lhs.upperBound, rhs.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func roundedHalfDegree(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }
}
