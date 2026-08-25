import Testing
import Foundation
@testable import AgentMenuCore

@Test func versionRendersWithALeadingV() {
    #expect(AppVersion.display(short: "1.3.0") == "v1.3.0")
}

// Same rule the rest of the app follows for figures it cannot establish: an
// unknown value renders as absent, never as a plausible-looking stand-in.
// A footer reading "v—" or "v0.0.0" would be worse than an empty corner.
// This is the `swift run` case, where there is no bundle to read.
@Test func anUnknownVersionRendersAsNothingRatherThanAPlaceholder() {
    #expect(AppVersion.display(short: nil) == nil)
    #expect(AppVersion.display(short: "") == nil)
    #expect(AppVersion.display(short: "   ") == nil)
}

@Test func surroundingWhitespaceIsTrimmedRatherThanRendered() {
    #expect(AppVersion.display(short: " 1.3.0 ") == "v1.3.0")
}
