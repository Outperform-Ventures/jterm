import SwiftUI

/// A popover view that displays detailed update information and action buttons.
///
/// The view adapts its content based on the current update state, showing appropriate
/// UI for checking, downloading, installing, or handling errors.
struct UpdatePopoverView: View {
    /// The update view model that provides the current state and information
    @ObservedObject var model: UpdateViewModel
    
    /// The actions that can be performed on updates
    let actions: UpdateUIActions
    
    /// Environment value for dismissing the popover
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .idle:
                EmptyView()
                
            case .permissionRequest:
                permissionRequestView
                
            case .checking:
                checkingView
                
            case .updateAvailable:
                updateAvailableView
                
            case .downloading:
                downloadingView
                
            case .extracting:
                extractingView
                
            case .readyToInstall:
                readyToInstallView
                
            case .installing:
                installingView
                
            case .notFound:
                notFoundView
                
            case .error:
                errorView
            }
        }
        .frame(width: 300)
    }
    
    /// View shown when requesting permission to enable automatic updates
    private var permissionRequestView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable automatic updates?")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("Ghostty can automatically check for and download updates in the background.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 8) {
                Button("Not Now") {
                    actions.denyAutoChecks()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Allow") {
                    actions.allowAutoChecks()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
    
    /// View shown while checking for updates
    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .font(.system(size: 13))
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    actions.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
    
    /// View shown when an update is available, displaying version and size information
    private var updateAvailableView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update Available")
                        .font(.system(size: 13, weight: .semibold))
                    
                    if let details = model.details {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Version:")
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                Text(details.version)
                            }
                            .font(.system(size: 11))
                            
                            if let size = details.size {
                                HStack(spacing: 6) {
                                    Text("Size:")
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, alignment: .trailing)
                                    Text(size)
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                }
                
                HStack(spacing: 8) {
                    Button("Skip") {
                        actions.skipThisVersion()
                        dismiss()
                    }
                    .controlSize(.small)
                    
                    Button("Later") {
                        actions.remindLater()
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Install") {
                        actions.install()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)
            
            if model.details?.notesSummary != nil {
                Divider()
                
                Button(action: actions.showReleaseNotes) {
                    HStack {
                        Text("View Release Notes")
                            .font(.system(size: 11))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
    
    /// View shown while downloading an update, with progress indicator
    private var downloadingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading Update")
                    .font(.system(size: 13, weight: .semibold))
                
                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    actions.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
    
    /// View shown while extracting/preparing the downloaded update
    private var extractingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preparing Update")
                .font(.system(size: 13, weight: .semibold))
            
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
    
    /// View shown when an update is ready to be installed
    private var readyToInstallView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to Install")
                    .font(.system(size: 13, weight: .semibold))
                
                if let details = model.details {
                    Text("Version \(details.version) is ready to install.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            HStack(spacing: 8) {
                Button("Later") {
                    actions.remindLater()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                
                Spacer()
                
                Button("Install and Relaunch") {
                    actions.install()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
    
    /// View shown during the installation process
    private var installingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.system(size: 13, weight: .semibold))
            }
            
            Text("The application will relaunch shortly.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(16)
    }
    
    /// View shown when no updates are found (already on latest version)
    private var notFoundView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No Updates Found")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("You're already running the latest version.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack {
                Spacer()
                Button("OK") {
                    actions.remindLater()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
    
    /// View shown when an error occurs during the update process
    private var errorView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 13))
                    Text(model.error?.title ?? "Update Failed")
                        .font(.system(size: 13, weight: .semibold))
                }
                
                if let message = model.error?.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            HStack(spacing: 8) {
                Button("OK") {
                    actions.remindLater()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                
                Spacer()
                
                Button("Retry") {
                    actions.retry()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}
