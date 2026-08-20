import SwiftUI
import AgentMenuCore

/// State channel. Identity lives on the row's accent spine; this carries only
/// what the session is doing, so urgency reads identically across agents.
public struct StatusDot: View {
    let state: SessionState
    let accent: Color
    let alert: Color
    let caution: Color
    let idle: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    public init(state: SessionState, accent: Color, alert: Color, caution: Color, idle: Color) {
        self.state = state; self.accent = accent
        self.alert = alert; self.caution = caution; self.idle = idle
    }

    private var fill: Color {
        switch state {
        case .awaitingPermission(_, .exact):    return alert
        case .awaitingPermission(_, .inferred): return .clear     // hollow ring: it's a guess
        case .working:                          return accent
        case .idle, .done:                      return idle
        case .unavailable:                      return caution
        }
    }

    private var stroke: Color {
        if case .awaitingPermission(_, .inferred) = state { return caution }
        return .clear
    }

    private var period: Double? {
        switch state {
        case .awaitingPermission: return 0.9      // faster = more urgent
        case .working:            return 2.0
        default:                  return nil      // static
        }
    }

    public var body: some View {
        ZStack {
            if case .awaitingPermission(_, .exact) = state {
                Circle().fill(alert.opacity(0.25)).frame(width: 16, height: 16).blur(radius: 3)
            }
            Circle()
                .fill(fill)
                .overlay(Circle().stroke(stroke, lineWidth: 1.5))
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 0.35 : 1.0)
        }
        .frame(width: 16, height: 16)
        .onAppear { startPulse() }
        .onChange(of: period) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard let period, !reduceMotion else { pulsing = false; return }
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
