import AppKit
import SwiftUI
import WakeUpeerDomain

@main
struct WakeUpeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: delegate.state)
        } label: {
            Image(systemName: delegate.state.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // Janela própria em vez da cena Settings: num app LSUIElement o
        // openSettings() abre atrás de tudo ou simplesmente não aparece.
        Window("Preferências do WakeUpeer", id: WindowID.preferences) {
            PreferencesView(state: delegate.state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// O rastreamento e a automação precisam começar no lançamento do app,
/// não quando o popover é aberto pela primeira vez — senão nada acontece
/// até você clicar no ícone.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let state = AppState.live()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await state.bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }
}

enum WindowID {
    static let preferences = "preferences"
}

/// Traz a janela para frente. Sem isto, um app sem Dock abre janelas atrás
/// do app que estava em foco.
@MainActor
func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
}
