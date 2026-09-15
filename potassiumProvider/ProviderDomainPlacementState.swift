import Foundation
import PotassiumProviderCore

enum ProviderDomainPlacementState: Equatable, Sendable {
    case connected
    case authenticationRequired
    case volumeUnavailable
    case registering
    case moving
    case needsRepair(String)

    var isAttentionRequired: Bool {
        switch self {
        case .authenticationRequired, .volumeUnavailable, .needsRepair:
            true
        case .connected, .registering, .moving:
            false
        }
    }

    var title: String {
        switch self {
        case .connected:
            "Connected"
        case .authenticationRequired:
            "Authentication Required"
        case .volumeUnavailable:
            "External Drive Disconnected"
        case .registering:
            "Registering"
        case .moving:
            "Moving"
        case .needsRepair:
            "Needs Repair"
        }
    }

    var detail: String? {
        switch self {
        case .authenticationRequired:
            "Reconnect this account, then repair the File Provider connection."
        case .volumeUnavailable:
            "Connect the configured external drive to continue."
        case .needsRepair(let detail):
            detail
        case .connected, .registering, .moving:
            nil
        }
    }
}

struct ProviderPreservedDataLocation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    let driveName: String
}

extension ProviderDomainStorageLocation {
    var userFacingTitle: String {
        switch self {
        case .onThisMac:
            "On This Mac"
        case .externalVolume(_, let displayName):
            displayName
        }
    }

    var isExternal: Bool {
        if case .externalVolume = self { return true }
        return false
    }
}
