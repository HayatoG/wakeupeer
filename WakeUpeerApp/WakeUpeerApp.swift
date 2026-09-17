import SwiftUI
import WakeUpeerDomain

@main
struct WakeUpeerApp: App {
    @State private var state = AppState.live()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: state)
        } label: {
            Image(systemName: state.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(state: state)
        }
    }
}
