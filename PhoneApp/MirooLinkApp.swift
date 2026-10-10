import SwiftUI

@main
struct MirooLinkApp: App {
    @StateObject private var session = PhoneSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onChange(of: scenePhase) { phase in
                    print("[phone] scenePhase -> \(phase)")
                    UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                    if phase != .inactive { session.setActive(phase == .active) }
                }
        }
    }
}
