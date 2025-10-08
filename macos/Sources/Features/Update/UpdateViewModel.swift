import Foundation
import SwiftUI

struct UpdateUIActions {
    let allowAutoChecks: () -> Void
    let denyAutoChecks: () -> Void
    let cancel: () -> Void
    let install: () -> Void
    let remindLater: () -> Void
    let skipThisVersion: () -> Void
    let showReleaseNotes: () -> Void
    let retry: () -> Void
}

class UpdateViewModel: ObservableObject {
    @Published var state: State = .idle
    @Published var progress: Double? = nil
    @Published var details: Details? = nil
    @Published var error: ErrorInfo? = nil
    
    enum State: Equatable {
        case idle
        case permissionRequest
        case checking
        case updateAvailable
        case downloading
        case extracting
        case readyToInstall
        case installing
        case notFound
        case error
    }
    
    struct ErrorInfo: Equatable {
        let title: String
        let message: String
    }
    
    struct Details: Equatable {
        let version: String
        let build: String?
        let size: String?
        let date: Date?
        let notesSummary: String?
    }
    
    var stateTooltip: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "Update permission required"
        case .checking:
            return "Checking for updates…"
        case .updateAvailable:
            if let details {
                return "Update available: \(details.version)"
            }
            return "Update available"
        case .downloading:
            if let progress {
                return String(format: "Downloading %.0f%%…", progress * 100)
            }
            return "Downloading…"
        case .extracting:
            if let progress {
                return String(format: "Preparing %.0f%%…", progress * 100)
            }
            return "Preparing…"
        case .readyToInstall:
            return "Ready to install"
        case .installing:
            return "Installing…"
        case .notFound:
            return "No updates found"
        case .error:
            return error?.title ?? "Update failed"
        }
    }
    
    var text: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "Update Permission"
        case .checking:
            return "Checking for Updates…"
        case .updateAvailable:
            if let details {
                return "Update Available: \(details.version)"
            }
            return "Update Available"
        case .downloading:
            if let progress {
                return String(format: "Downloading: %.0f%%", progress * 100)
            }
            return "Downloading…"
        case .extracting:
            if let progress {
                return String(format: "Preparing: %.0f%%", progress * 100)
            }
            return "Preparing…"
        case .readyToInstall:
            return "Install Update"
        case .installing:
            return "Installing…"
        case .notFound:
            return "No Updates Available"
        case .error:
            return error?.title ?? "Update Failed"
        }
    }
    
    var iconName: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .updateAvailable:
            return "arrow.down.circle.fill"
        case .downloading, .extracting:
            return "" // Progress ring instead
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .notFound:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    var iconColor: Color {
        switch state {
        case .idle:
            return .secondary
        case .permissionRequest, .checking:
            return .secondary
        case .updateAvailable, .readyToInstall:
            return .accentColor
        case .downloading, .extracting, .installing:
            return .secondary
        case .notFound:
            return .secondary
        case .error:
            return .orange
        }
    }
    
    var backgroundColor: Color {
        switch state {
        case .updateAvailable:
            return .accentColor
        case .readyToInstall:
            return Color(nsColor: NSColor.systemGreen.blended(withFraction: 0.3, of: .black) ?? .systemGreen)
        case .error:
            return .orange.opacity(0.2)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }
    
    var foregroundColor: Color {
        switch state {
        case .updateAvailable, .readyToInstall:
            return .white
        case .error:
            return .orange
        default:
            return .primary
        }
    }
}
