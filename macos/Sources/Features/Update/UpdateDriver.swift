import Sparkle

/// Implement the SPUUserDriver to modify our UpdateViewModel for custom presentation.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    let retryHandler: () -> Void
    
    init(viewModel: UpdateViewModel, retryHandler: @escaping () -> Void) {
        self.viewModel = viewModel
        self.retryHandler = retryHandler
        super.init()
    }
    
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        viewModel.state = .permissionRequest(.init(request: request, reply: reply))
    }
    
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        viewModel.state = .checking(.init(cancel: cancellation))
    }
    
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        viewModel.state = .updateAvailable(.init(appcastItem: appcastItem, reply: reply))
    }
    
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // We don't do anything with the release notes here because Ghostty
        // doesn't use the release notes feature of Sparkle currently.
    }
    
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // We don't do anything with release notes. See `showUpdateReleaseNotes`
    }
    
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        viewModel.state = .notFound
        // TODO: Do we need to acknowledge?
    }
    
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        viewModel.state = .error(.init(error: error, retry: retryHandler))
    }
    
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        viewModel.state = .downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0))
    }
    
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }
            
        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0))
    }
    
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }
        
        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length))
    }
    
    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(.init(progress: 0))
    }
    
    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(.init(progress: progress))
    }
    
    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        viewModel.state = .readyToInstall(.init(reply: reply))
    }
    
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        viewModel.state = .installing
    }
    
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // We don't do anything here.
        viewModel.state = .idle
    }
    
    func showUpdateInFocus() {
        // We don't currently implement this because our update state is
        // shown in a terminal window. We may want to implement this at some
        // point to handle the case that no windows are open, though.
    }
    
    func dismissUpdateInstallation() {
        viewModel.state = .idle
    }
}
