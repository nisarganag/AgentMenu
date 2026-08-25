import SwiftUI
import AppKit

/// Liquid Glass where the OS has it, a material card where it doesn't.
///
/// The app deploys to macOS 14 but `glassEffect` is macOS 26+, so every use is
/// behind `#available` here rather than sprinkled through `PreferencesView`.
/// The fallback is deliberately a real card and not a no-op: without a
/// background the sections lose their grouping entirely on older systems, and
/// "looks plainer" is a fine degradation where "reads as one undifferentiated
/// column of switches" is not.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            base.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            base.background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// `maxWidth: .infinity` is what makes the stack read as a column rather
    /// than a ragged pile: without it every card shrink-wraps its own longest
    /// row, so section widths visibly jump between "Start at login" and
    /// "PERMISSION DETECTION". Verified by screenshot, not by eye — the
    /// difference is obvious on screen and invisible in the source.
    private var base: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

/// Groups sibling `GlassCard`s so the system can blend them as one optical
/// unit — that lensing between nearby shapes is the whole point of Liquid
/// Glass, and cards applied individually outside a container just look like
/// separate frosted rectangles.
struct GlassStack<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                VStack(alignment: .leading, spacing: spacing) { content }
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}
