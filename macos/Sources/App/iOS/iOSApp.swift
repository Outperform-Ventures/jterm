import SwiftUI
import GhosttyKit

@main
struct JTermiOSApp: App {
    @StateObject private var ghostty_app: JTerm.App

    init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            preconditionFailure("Initialize ghostty backend failed")
        }
        _ghostty_app = StateObject(wrappedValue: JTerm.App())
    }

    var body: some Scene {
        WindowGroup {
            iOSJTermTerminal()
                .environmentObject(ghostty_app)
        }
    }
}

struct iOSJTermTerminal: View {
    @EnvironmentObject private var ghostty_app: JTerm.App

    var body: some View {
        ZStack {
            // Make sure that our background color extends to all parts of the screen
            Color(ghostty_app.config.backgroundColor).ignoresSafeArea()

            JTerm.Terminal()
        }
    }
}

struct iOSJTermInitView: View {
    @EnvironmentObject private var ghostty_app: JTerm.App

    var body: some View {
        VStack {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            Text("jTerm")
            Text("State: \(ghostty_app.readiness.rawValue)")
        }
        .padding()
    }
}
