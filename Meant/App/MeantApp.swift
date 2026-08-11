import SwiftUI

@main
struct MeantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(viewModel: appDelegate.viewModel)
        }
        .defaultSize(width: 540, height: 466)
    }
}
