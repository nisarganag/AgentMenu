import AppKit
import SwiftUI
import AgentMenuCore

@MainActor
public final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model: AppViewModel
    private let onQuit: () -> Void
    private let onPreferences: () -> Void

    public init(model: AppViewModel, onPreferences: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
        self.onPreferences = onPreferences
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // NOTE: `contentViewController` is deliberately NOT built here — see
        // `mountContent()`. It is created on open and destroyed on close.
    }

    /// PERF (owner report: 17% CPU at rest). The popover's SwiftUI tree used
    /// to be built once in `init` and then live for the entire run of the
    /// app, on screen or not. `StatusDot` drives a
    /// `.repeatForever(autoreverses:)` pulse for every working or
    /// permission-blocked session, and a repeating animation does not care
    /// whether anyone can see it: it keeps requesting display updates, so
    /// Core Animation re-ran the full commit/layout cycle at frame rate
    /// forever, behind a closed popover.
    ///
    /// Measured on the owner's machine, popover closed, one session working:
    /// 17.0% CPU with the tree resident, 4.5% with the pulse disabled — the
    /// hidden animation alone was ~12.5 points.
    ///
    /// Suppressing model mutations while hidden (the earlier fix, still in
    /// `AppDelegate.tick`) could never have caught this: the animation is
    /// self-perpetuating and needs no model change to keep going. So the
    /// tree is now mounted on open and torn down on close — a hidden view
    /// that does not exist cannot do work, which closes the whole class of
    /// bug rather than this one instance of it.
    ///
    /// Rebuilding is cheap (one small view, milliseconds) and loses nothing:
    /// the only cross-open state that matters, the current page, lives on
    /// `AppViewModel`, not in SwiftUI `@State`.
    private func mountContent() {
        guard popover.contentViewController == nil else { return }
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model, onPreferences: onPreferences, onQuit: onQuit))
        // Belt-and-suspenders alongside PopoverView's own fixed `.frame`
        // (round-2 fix): NSPopover would otherwise size itself from
        // NSHostingController's preferred content size, which is exactly
        // the path that let the popover resize/reposition/clip as content
        // changed. Setting this explicitly makes NSPopover authoritative
        // too, not just the SwiftUI view. Must be re-applied on every mount,
        // since it is a property of the content pairing.
        popover.contentSize = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
    }

    /// Closed by ANY route — the status item clicked again, click-outside on
    /// a `.transient` popover, or Escape. Deferred by one runloop turn so the
    /// controller is never released from inside AppKit's own dismissal.
    public func popoverDidClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item
        updateIcon(inferredAttention: 0, activeKinds: [], exactAttentionProjects: [])
    }

    /// Whether the popover is currently on screen.
    ///
    /// The caller uses this to skip refreshing the observable model while
    /// hidden. Still worth doing even though `mountContent`/`popoverDidClose`
    /// now destroy the hidden tree outright: refreshing costs real work
    /// (`store.all`, windowed token folds) whose only consumer is that tree,
    /// so with nothing mounted there is nobody left to render the result.
    public var isPopoverShown: Bool { popover.isShown }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            // Land on whichever agent actually wants the user right now —
            // a permission prompt first, else the longest-running session,
            // else a turn that finished recently enough to still be why the
            // popover is being opened — rather than always reopening on
            // whatever page was last viewed. Set BEFORE `show`, so the
            // paged view is already scrolled to the right page the instant
            // it becomes visible — no on-screen jump.
            model.currentPage = model.pageToShowOnOpen()
            mountContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Composites the glyph, the attention badge, and the live-agent pips.
    ///
    /// `exactAttentionProjects` and `inferredAttention` are kept as two
    /// separate signals (Fix 3 / review Ruling F61), never merged before
    /// reaching this method: this is the app's only surface visible with
    /// the popover closed, so it must never render a Codex stall guess with
    /// the same alert-red badge as a fact-backed Claude permission prompt.
    /// An exact hit always wins the badge colour when both are present — it
    /// is strictly more actionable than a guess. (There is no longer a
    /// separate exact `attention: Int` — `exactAttentionProjects.count` IS
    /// that count, and deriving it from one place instead of two numbers
    /// that merely ought to agree is what actually guarantees they can't
    /// drift apart.)
    ///
    /// Round 2 Fix 4: `exactAttentionProjects` additionally names what's
    /// blocked, without opening the popover — see `overlay(...)` below for
    /// why this is scoped to exact confidence only.
    public func updateIcon(inferredAttention: Int, activeKinds: [AgentKind],
                           exactAttentionProjects: [String]) {
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
        button.attributedTitle = overlay(inferredAttention: inferredAttention,
                                         kinds: activeKinds, exactAttentionProjects: exactAttentionProjects)
        // Round 2 Fix 4: the full name is still available on hover even when
        // the title itself had to truncate it.
        button.toolTip = exactAttentionProjects.count == 1 ? exactAttentionProjects[0] : nil
    }

    private func overlay(inferredAttention: Int, kinds: [AgentKind],
                         exactAttentionProjects: [String]) -> NSAttributedString {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let result = NSMutableAttributedString()
        if !exactAttentionProjects.isEmpty {
            result.append(NSAttributedString(string: " ●", attributes: [
                .foregroundColor: NSColor(Theme.alert(dark: dark)),
                .font: NSFont.systemFont(ofSize: 9),
            ]))
            // Round 2 Fix 4: name a single blocked session outright; fall
            // back to a count once there's more than one, so glancing at the
            // menu bar can tell you WHETHER to even look, not just THAT
            // something's pending. Deliberately gated on exact attention
            // only — an `.inferred`-only guess (the branch below) never
            // reaches this text at all, which is how "the existing
            // exact/inferred distinction survives into this text": extending
            // "name what's blocked" wording to a guess that might not be
            // blocked at all would describe it with a certainty it doesn't
            // have.
            let label = exactAttentionProjects.count == 1
                ? " " + Self.truncate(exactAttentionProjects[0])
                : " \(exactAttentionProjects.count)"
            result.append(NSAttributedString(string: label, attributes: [
                .foregroundColor: NSColor(Theme.alert(dark: dark)),
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ]))
        } else if inferredAttention > 0 {
            // A guess, not a fact (Fix 3) — caution amber, never alert red,
            // so the badge cannot claim more certainty than the row itself
            // does. No appended text either (Fix 4): the title returns to
            // just the glyph and pips, exactly as when nothing needs
            // attention — only the dot's colour signals "maybe."
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

    /// The menu bar is scarce (Fix 4); a single very long project name must
    /// not push the rest of the menu bar off-screen. `String.prefix` counts
    /// `Character` (grapheme clusters), so this can never split an emoji or
    /// combining sequence mid-way.
    private static func truncate(_ s: String, maxLength: Int = 18) -> String {
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }
}
