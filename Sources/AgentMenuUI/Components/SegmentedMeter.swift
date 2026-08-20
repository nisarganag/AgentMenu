import SwiftUI

/// 14 discrete segments rather than a continuous bar.
///
/// Segmentation is deliberate: a smooth bar makes small context changes
/// invisible, while discrete cells make each step perceptible at a glance.
/// The tail shifts to caution past 80% and alert past 92%.
public struct SegmentedMeter: View {
    public static let segments = 14

    let fraction: Double
    let accent: Color
    let caution: Color
    let alert: Color
    let empty: Color

    public init(fraction: Double, accent: Color, caution: Color, alert: Color, empty: Color) {
        self.fraction = max(0, min(1, fraction))
        self.accent = accent; self.caution = caution; self.alert = alert; self.empty = empty
    }

    private func color(at index: Int) -> Color {
        let filledCount = Int((fraction * Double(Self.segments)).rounded())
        guard index < filledCount else { return empty }
        let position = Double(index + 1) / Double(Self.segments)
        if position > 0.92 { return alert }
        if position > 0.80 { return caution }
        return accent
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(at: i))
                    .frame(width: 6, height: 5)
            }
        }
        .accessibilityLabel("Context \(Int(fraction * 100)) percent full")
    }
}
