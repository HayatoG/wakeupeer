import AppKit
import SwiftUI
import WakeUpeerDomain

@main
struct WakeUpeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A barra de menu e as janelas são criadas em AppKit, não como cenas
        // SwiftUI: MenuBarExtra não expõe o NSStatusItem, e sem ele não há
        // clique-direito nem ícone animado. Esta cena existe só para
        // satisfazer o protocolo App — nada é exibido por ela.
        Settings {
            EmptyView()
        }
    }
}

/// O rastreamento e a automação precisam começar no lançamento do app,
/// não quando o popover é aberto pela primeira vez — senão nada acontece
/// até você clicar no ícone.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let state = AppState.live()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(state: state)
        state.onDismissPopover = { [weak self] in
            self?.menuBar?.closePopover()
        }
        Task { await state.bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.tearDown()
        state.shutdown()
    }
}

/// Traz a janela para frente. Sem isto, um app sem Dock abre janelas atrás
/// do app que estava em foco.
@MainActor
func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
}
