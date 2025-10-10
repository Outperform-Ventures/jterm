import Sparkle
import Cocoa

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private let updaterDelegate = UpdaterDelegate()
    
    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }
    
    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: updaterDelegate
        )
    }
    
    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }
    
    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }
    
    /// Validate the check for updates menu item.
    ///
    /// - Parameter item: The menu item to validate
    /// - Returns: Whether the menu item should be enabled
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return updater.canCheckForUpdates
        }
        return true
    }
}
