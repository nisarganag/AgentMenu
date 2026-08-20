import AppKit
import SwiftUI
import AgentMenuCore

@MainActor
public final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model: AppViewModel
    private let onQuit: () -> Void

    public init(model: AppViewModel, onPreferences: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model, onPreferences: onPreferences, onQuit: onQuit))
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item
        updateIcon(attention: 0, inferredAttention: 0, activeKinds: [])
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Composites the glyph, the attention badge, and the live-agent pips.
    ///
    /// `attention` and `inferredAttention` are kept as two separate counts
    /// (Fix 3 / review Ruling F61), not merged before reaching this method:
    /// this is the app's only surface visible with the popover closed, so it
    /// must never render a Codex stall guess with the same alert-red badge
    /// as a fact-backed Claude permission prompt. An exact hit always wins
    /// the badge colour when both are present — it is strictly more
    /// actionable than a guess.
    public func updateIcon(attention: Int, inferredAttention: Int, activeKinds: [AgentKind]) {
        guard let button = statusItem?.button else { return }
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Base glyph: a rounded square with a pulse stroke. Drawn in black
            // and marked as a template so AppKit recolours it per menu bar.
            NSColor.black.setStroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 3, y: 5, width: 14, height: 11),
                                    xRadius: 3, yRadius: 3)
            body.lineWidth = 1.3
            body.stroke()
            let pulse = NSBezierPath()
            pulse.move(to: NSPoint(x: 6, y: 10.5))
            pulse.line(to: NSPoint(x: 8.5, y: 10.5))
            pulse.line(to: NSPoint(x: 10, y: 13))
            pulse.line(to: NSPoint(x: 11.5, y: 8))
            pulse.line(to: NSPoint(x: 13, y: 10.5))
            pulse.line(to: NSPoint(x: 14.5, y: 10.5))
            pulse.lineWidth = 1.2
            pulse.lineJoinStyle = .round
            pulse.stroke()
            _ = rect
            return true
        }
        image.isTemplate = true
        button.image = image

        // Colour cannot live in a template image, so the badge and pips are a
        // separate non-template overlay drawn as the button's attributed title.
        button.imagePosition = .imageLeading
        button.attributedTitle = overlay(attention: attention, inferredAttention: inferredAttention,
                                         kinds: activeKinds)
    }

    private func overlay(attention: Int, inferredAttention: Int, kinds: [AgentKind]) -> NSAttributedString {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let result = NSMutableAttributedString()
        if attention > 0 {
            result.append(NSAttributedString(string: " ●", attributes: [
                .foregroundColor: NSColor(Theme.alert(dark: dark)),
                .font: NSFont.systemFont(ofSize: 9),
            ]))
        } else if inferredAttention > 0 {
            // A guess, not a fact (Fix 3) — caution amber, never alert red,
            // so the badge cannot claim more certainty than the row itself does.
            result.append(NSAttributedString(string: " ●", attributes: [
                .foregroundColor: NSColor(Theme.caution(dark: dark)),
                .font: NSFont.systemFont(ofSize: 9),
            ]))
        } else {
            for kind in kinds.prefix(3) {
                result.append(NSAttributedString(string: "·", attributes: [
                    .foregroundColor: NSColor(Theme.accent(for: kind, dark: dark)),
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                ]))
            }
        }
        return result
    }
}
