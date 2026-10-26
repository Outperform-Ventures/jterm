import Cocoa

struct QuickTerminalRestorableState: TerminalRestorable {
    static var version: Int { 1 }

    let focusedSurface: String?
    let surfaceTree: SplitTree<JTerm.SurfaceView>
    let screenStateEntries: QuickTerminalScreenStateCache.Entries

    init(from controller: QuickTerminalController) {
        controller.saveScreenState(exitFullscreen: true)
        self.focusedSurface = controller.focusedSurface?.id.uuidString
        self.surfaceTree = controller.surfaceTree
        self.screenStateEntries = controller.screenStateCache.stateByDisplay
    }

    init(copy other: QuickTerminalRestorableState) {
        self = other
    }

    var baseConfig: JTerm.SurfaceConfiguration? {
        var config = JTerm.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        return config
    }
}
