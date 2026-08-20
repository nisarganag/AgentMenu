import Foundation

extension SessionState {
    /// Lower sorts first. The ordering IS the feature: whatever needs the user
    /// is always at the top of the popover (spec §5).
    var sortRank: Int {
        switch self {
        case .awaitingPermission: return 0
        case .working:            return 1
        case .idle:               return 2
        case .done:               return 3
        case .unavailable:        return 4
        }
    }
}

extension Array where Element == AgentSession {
    public func sortedForDisplay() -> [AgentSession] {
        sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            return $0.lastEventAt > $1.lastEventAt   // most recent first
        }
    }
}
