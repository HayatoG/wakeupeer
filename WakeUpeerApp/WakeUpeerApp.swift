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

    /// Mantida viva enquanto o app roda; é ela que hospeda o relatório
    /// quando a notificação semanal é tocada.
    private var reportWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.onOpenReport = { [weak self] in
            self?.showReportWindow()
        }
        Task { await state.bootstrap() }
    }

    /// Abre o relatório em AppKit puro. Num app sem Dock, `openWindow` do
    /// SwiftUI só está disponível dentro de uma view viva — e o popover,
    /// que seria o candidato natural, não existe quando está fechado.
    func showReportWindow() {
        activateApp()

        if let existing = reportWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Relatório de uso"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReportView(state: state))
        window.makeKeyAndOrderFront(nil)
        reportWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
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
