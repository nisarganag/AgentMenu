import SwiftUI

public struct HeaderView: View {
    let todayCost: Double
    let burn5h: Int
    /// nil unless the user set a budget — never a provider quota (spec §6).
    let burnFraction: Double?
    /// Feature 1: true when at least one displayed session (opencode; or an
    /// unreadable source) could not contribute to `todayCost`/`burn5h` — the
    /// figures are a real sum, just not necessarily over every agent, and
    /// that must stay visible rather than read as a silent under-report.
    let figuresPartial: Bool
    /// Feature 2: percentage of Claude's trailing-5h burn against the
    /// lowest rolling-5h burn AgentMenu has ever observed at a real
    /// rate-limit error. Nil until at least one has actually happened.
    let rateLimitFraction: Double?
    let onPreferences: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    public init(todayCost: Double, burn5h: Int, burnFraction: Double?, figuresPartial: Bool,
                rateLimitFraction: Double?, onPreferences: @escaping () -> Void) {
        self.todayCost = todayCost; self.burn5h = burn5h
        self.burnFraction = burnFraction; self.figuresPartial = figuresPartial
        self.rateLimitFraction = rateLimitFraction; self.onPreferences = onPreferences
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Feature 1: this used to be labelled "Since Launch" because the
            // figure only ever counted burn actually OBSERVED while
            // AgentMenu was running. The parsers now compute a true
            // calendar-day total directly from each message's own
            // timestamp, so "Today" is no longer a plausible-looking lie —
            // except opencode, whose schema has no per-message breakdown to
            // window, so an opencode session contributes nothing to this
            // sum. The trailing `*` and tooltip say so rather than let the
            // total silently read as covering every agent.
            metric(figuresPartial ? "TODAY*" : "TODAY", String(format: "$%.2f", todayCost))
                .help(figuresPartial
                    ? "Excludes opencode sessions (and any source AgentMenu could not read) — their data has no per-message timestamps to compute a calendar-day total."
                    : "Calendar-day total since local midnight.")
            // Round 2 Fix 1: `burn5h` is already `workTokens` (input+output),
            // not `.total` — see ViewModel.refresh(). The tooltip says so
            // explicitly so the smaller figure reads as "cache reads
            // excluded on purpose," never as under-reporting.
            metric("LAST 5H", burnFraction.map {
                "\(SessionRowView.compact(burn5h)) tok  \(Int($0 * 100))%"
            } ?? "\(SessionRowView.compact(burn5h)) tok")
                .help("Input + output tokens over the trailing 5 hours. Excludes cache-read/cache-write tokens, which re-count prior context on every turn and would otherwise dwarf the tokens actually read or written.")
            // Feature 2: spec §6 still refuses a percentage of an OFFICIAL
            // quota (`rateLimits` is null on disk) — this is a MEASURED one,
            // shown only once AgentMenu has actually seen Claude get
            // rate-limited, and coloured/captioned as an estimate rather
            // than an authoritative fact.
            if let rateLimitFraction {
                metric("OBSERVED LIMIT", "\(Int(rateLimitFraction * 100))%",
                       tint: Theme.caution(dark: dark))
                    .help("Percentage of Claude's trailing 5h token burn against the lowest burn AgentMenu has ever seen Claude get rate-limited at. Measured from what happened on this machine, not an official quota.")
            }
            Spacer()
            Button(action: onPreferences) {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary(dark: dark))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func metric(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            // Aggregates are neutral grey — they belong to no single agent.
            Text(label.uppercased())
                .font(Theme.label).foregroundStyle(Theme.textTertiary(dark: dark))
            Text(value)
                .font(Theme.mono(11)).foregroundStyle(tint ?? Theme.textPrimary(dark: dark))
        }
    }
}
