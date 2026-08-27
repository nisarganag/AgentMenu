import AppKit

/// The popover's window.
///
/// `NSPopover` cannot be used for a Liquid Glass surface. Its background and
/// arrow are drawn by a private frame view that sits BELOW the hosted content,
/// so anything glassy layered on top samples that frame's material rather than
/// the desktop — glass over grey, which is exactly what the old build looked
/// like. Confirmed by dumping the live hierarchy: `_NSPopoverWindow` is already
/// `opaque=false` with a clear background colour and contains no
/// `NSVisualEffectView` at all, so there was nothing in reach to neutralise.
///
/// A borderless panel with a genuinely clear background lets the SwiftUI
/// `.glassEffect` underneath sample what is actually behind the window, which
/// is how Control Center reads the way it does.
///
/// `NSPanel` rather than `NSWindow`, and key-capable rather than
/// `.nonactivatingPanel`: Preferences lives inside this window now and its burn
/// budget field has to accept typing. A panel that never becomes key would
/// render a text field that silently swallows every keystroke.
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        // Menu-bar level, so it sits above ordinary windows the way the real
        // popover did rather than slipping behind whatever was focused.
        level = .popUpMenu
        // Follows the user across spaces and survives full-screen apps —
        // without this the panel is stranded on the space it opened in.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        animationBehavior = .none
    }
}
