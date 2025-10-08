import SwiftUI
import Sparkle

/// A popover view that displays detailed update information and action buttons.
///
/// The view adapts its content based on the current update state, showing appropriate
/// UI for checking, downloading, installing, or handling errors.
struct UpdatePopoverView: View {
    /// The update view model that provides the current state and information
    @ObservedObject var model: UpdateViewModel
    
    /// Environment value for dismissing the popover
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .idle:
                // Shouldn't happen in a well-formed view stack. Higher levels
                // should not call the popover for idles.
                EmptyView()
                
            case .permissionRequest(let request):
                PermissionRequestView(request: request, dismiss: dismiss)
                
            case .checking(let checking):
                CheckingView(checking: checking, dismiss: dismiss)
                
            case .updateAvailable(let update):
                UpdateAvailableView(update: update, dismiss: dismiss)
                
            case .downloading(let download):
                DownloadingView(download: download, dismiss: dismiss)
                
            case .extracting(let extracting):
                ExtractingView(extracting: extracting)
                
            case .readyToInstall(let ready):
                ReadyToInstallView(ready: ready, dismiss: dismiss)
                
            case .installing:
                InstallingView()
                
            case .notFound:
                NotFoundView(dismiss: dismiss)
                
            case .error(let error):
                UpdateErrorView(error: error, dismiss: dismiss)
            }
        }
        .frame(width: 300)
    }
}

fileprivate struct PermissionRequestView: View {
    let request: UpdateState.PermissionRequest
    let dismiss: DismissAction
    
    var body: some View {
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
                    request.reply(SUUpdatePermissionResponse(
                        automaticUpdateChecks: false,
                        sendSystemProfile: false))
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Allow") {
                    request.reply(SUUpdatePermissionResponse(
                        automaticUpdateChecks: true,
                        sendSystemProfile: false))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

fileprivate struct CheckingView: View {
    let checking: UpdateState.Checking
    let dismiss: DismissAction
    
    var body: some View {
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
                    checking.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct UpdateAvailableView: View {
    let update: UpdateState.UpdateAvailable
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update Available")
                        .font(.system(size: 13, weight: .semibold))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Version:")
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            Text(update.appcastItem.displayVersionString)
                        }
                        .font(.system(size: 11))
                    }
                }
                
                HStack(spacing: 8) {
                    Button("Skip") {
                        update.reply(.skip)
                        dismiss()
                    }
                    .controlSize(.small)
                    
                    Button("Later") {
                        update.reply(.dismiss)
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Install") {
                        update.reply(.install)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)
        }
    }
}

fileprivate struct DownloadingView: View {
    let download: UpdateState.Downloading
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading Update")
                    .font(.system(size: 13, weight: .semibold))
                
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = Double(download.progress) / Double(expectedLength)
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
                    download.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct ExtractingView: View {
    let extracting: UpdateState.Extracting
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preparing Update")
                .font(.system(size: 13, weight: .semibold))
            
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: extracting.progress, total: 1.0)
                Text(String(format: "%.0f%%", extracting.progress * 100))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }
}

fileprivate struct ReadyToInstallView: View {
    let ready: UpdateState.ReadyToInstall
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to Install")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("The update is ready to install.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 8) {
                Button("Later") {
                    ready.reply(.dismiss)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                
                Spacer()
                
                Button("Install and Relaunch") {
                    ready.reply(.install)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct InstallingView: View {
    var body: some View {
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
}

fileprivate struct NotFoundView: View {
    let dismiss: DismissAction
    
    var body: some View {
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
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct UpdateErrorView: View {
    let error: UpdateState.Error
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 13))
                    Text("Update Failed")
                        .font(.system(size: 13, weight: .semibold))
                }
                
                Text(error.error.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 8) {
                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                
                Spacer()
                
                Button("Retry") {
                    error.retry()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}
