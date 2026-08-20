import Foundation
import ServiceManagement

/// Wraps `SMAppService` rather than installing a LaunchAgent plist, so the app
/// appears in System Settings ▸ General ▸ Login Items under its own name —
/// where the user would actually look to turn it off (spec §12).
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return "Starts at login"
        case .notRegistered:     return "Not set to start at login"
        case .requiresApproval:  return "Waiting for approval in System Settings"
        case .notFound:          return "Move AgentMenu to /Applications to enable this"
        @unknown default:        return "Unknown"
        }
    }

    public static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
