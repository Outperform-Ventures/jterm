import AppKit

// MARK: JTerm Delegate

/// This implements the JTerm app delegate protocol which is used by the JTerm
/// APIs for app-global information.
extension AppDelegate: JTerm.Delegate {
    func ghosttySurface(id: UUID) -> JTerm.SurfaceView? {
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
