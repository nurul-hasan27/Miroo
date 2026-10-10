import SwiftUI

@main
struct MirooApp: App {
    @StateObject private var model = MacModel()
    init() { setvbuf(stdout, nil, _IOLBF, 0) }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

extension MacModel {
    var menuIcon: String {
        switch link {
        case .streaming: return "iphone.gen3.radiowaves.left.and.right"
        case .connecting: return "iphone.gen3.badge.exclamationmark"
        default: return "iphone.gen3"
        }
    }
}
