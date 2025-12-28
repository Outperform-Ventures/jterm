import AppKit

extension AppDelegate: Ghostty.Delegate {
    func ghosttySurface(id: UUID) -> Ghostty.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }
            for surface in controller.surfaceTree {
                if surface.id == id {
                    return surface
                }
            }
        }
        
        return nil
    }
}
