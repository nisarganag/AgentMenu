import Foundation

/// The running build's own version, for the popover footer.
///
/// A pure function over the Info.plist string rather than a `Bundle.main` read
/// at the call site, for the ordinary reason: under `swift test` `Bundle.main`
/// is the test runner, not the app, so an inline read is untestable and would
/// silently render the wrong thing in exactly the environment where a mistake
/// is hardest to notice.
public enum AppVersion {
    /// `"v1.3.0"` from `CFBundleShortVersionString`.
    ///
    /// Deliberately does NOT append `CFBundleVersion`. That counter is
    /// published nowhere — not in a release tag, not in the DMG name — so to
    /// anyone reading a bug report it is noise on the one line in the footer
    /// that has to stay glanceable, and since the two use different numbering
    /// schemes it would be appended every single time rather than only when it
    /// distinguished something.
    ///
    /// Returns nil rather than a placeholder when the version is missing or
    /// blank, following the rule the rest of the app uses for anything it
    /// cannot establish: an unknown value renders as absent, never as a
    /// plausible-looking stand-in. A footer reading `v—` would be worse than
    /// an empty corner. In practice this is the `swift run` case, where there
    /// is no bundle.
    public static func display(short: String?) -> String? {
        guard let short = short?.trimmingCharacters(in: .whitespaces), !short.isEmpty
        else { return nil }
        return "v\(short)"
    }
}
