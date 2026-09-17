import AppKit
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

        // Janela própria em vez da cena Settings: num app LSUIElement o
        // openSettings() abre atrás de tudo ou simplesmente não aparece.
        Window("Preferências do WakeUpeer", id: WindowID.preferences) {
            PreferencesView(state: state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Relatório de uso", id: WindowID.report) {
            ReportView(state: state)
        }
        .defaultSize(width: 820, height: 640)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let preferences = "preferences"
    static let report = "report"
}

/// Traz a janela para frente. Sem isto, um app sem Dock abre janelas atrás
/// do app que estava em foco.
@MainActor
func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
}
