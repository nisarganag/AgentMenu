import SwiftUI
import AgentMenuCore

public enum Theme {
    /// Hex helper: `#RRGGBB`.
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8)  & 0xFF) / 255,
              blue:  Double( v        & 0xFF) / 255)
    }

    /// Identity channel. Constant per agent, never varies with state.
    public static func accent(for kind: AgentKind, dark: Bool) -> Color {
        switch kind {
        case .claudeCode: return dark ? hex(0xE8845C) : hex(0xC9673F)
        case .codex:      return dark ? hex(0x6FC2E8) : hex(0x2A8FBF)
        case .opencode:   return dark ? hex(0x5BD98A) : hex(0x2E9E5B)
        }
    }

    public static func alert(dark: Bool)   -> Color { dark ? hex(0xFF6B5A) : hex(0xD93B28) }
    public static func caution(dark: Bool) -> Color { dark ? hex(0xFFB340) : hex(0xB87400) }

    public static func textPrimary(dark: Bool)   -> Color { dark ? hex(0xF2F3F5) : hex(0x1B1D21) }
    public static func textSecondary(dark: Bool) -> Color { dark ? hex(0x8C919B) : hex(0x5F646E) }
    public static func textTertiary(dark: Bool)  -> Color { dark ? hex(0x5A5F69) : hex(0x8E939C) }
    public static func hairline(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.10)
    }

    /// Tabular figures are mandatory: these numbers tick live, and proportional
    /// digits make every row jitter as they change.
    public static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced).monospacedDigit()
    }
    public static var project: Font { .system(size: 13, weight: .semibold) }
    public static var activity: Font { .system(size: 11, weight: .regular) }
    public static var label: Font { .system(size: 10, weight: .semibold) }

    public static let popoverWidth: CGFloat = 360
    /// Total popover content height — width AND height are both fixed so
    /// `NSPopover` never resizes/repositions/clips as content changes
    /// (round-2 fix). Deliberately NOT a `maxHeight` on some inner scroll
    /// view: the OUTER frame is what `NSHostingController` reports to
    /// `NSPopover`, so only fixing that outer frame stops the popover
    /// itself from moving. Content shorter than this stays top-aligned
    /// rather than stretching (see `PopoverView`/`PagedPopoverView`).
    public static let popoverHeight: CGFloat = 540
}
