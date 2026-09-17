import AppKit
import SwiftUI
import WakeUpeerDomain

/// Ícone da barra de menu em AppKit.
///
/// Substitui o `MenuBarExtra` do SwiftUI, que não expõe o `NSStatusItem`
/// subjacente — e sem ele não há como fazer menu de clique-direito nem
/// animar o ícone durante o disparo.
@MainActor
final class MenuBarController: NSObject {

    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    /// Fecha o popover quando se clica fora dele.
    private var clickOutsideMonitor: Any?

    /// Anima o ícone enquanto os apps abrem.
    private var pulseTimer: Timer?
    private var pulsePhase = 0

    /// Reavalia o símbolo periodicamente, já que ele muda com o horário.
    private var refreshTimer: Timer?

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        startRefreshTimer()

        state.onLaunchingChanged = { [weak self] isLaunching in
            self?.setPulsing(isLaunching)
        }
    }

    /// Chamado ao encerrar o app. Não há `deinit` porque o controlador vive
    /// enquanto o app vive, e um deinit isolado não pode tocar os timers.
    func tearDown() {
        pulseTimer?.invalidate()
        refreshTimer?.invalidate()
        closePopover()
    }

    // MARK: - Configuração

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = symbolImage(state.menuBarSymbol)
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleClick)
        // Sem isto o clique-direito não chega: o botão só reporta o esquerdo.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(state: state))
    }

    private func startRefreshTimer() {
        // O símbolo depende da hora e do perfil ativo; 30 s é suficiente
        // para a transição de período não passar despercebida.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        timer.tolerance = 10
        refreshTimer = timer
    }

    // MARK: - Ícone

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "WakeUpeer")
    }

    func refreshIcon() {
        guard pulseTimer == nil else { return }  // não atropela a animação
        guard let button = statusItem.button else { return }
        let image = symbolImage(state.menuBarSymbol)
        image?.isTemplate = true
        button.image = image
        button.alphaValue = 1
    }

    /// Pulsa o ícone enquanto o perfil está sendo aberto. Sem isso, disparar
    /// um perfil com o popover fechado não dá retorno nenhum.
    private func setPulsing(_ isPulsing: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil

        guard isPulsing else {
            statusItem.button?.alphaValue = 1
            refreshIcon()
            return
        }

        pulsePhase = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.advancePulse() }
        }
        pulseTimer = timer
        advancePulse()
    }

    /// Alterna entre o símbolo do perfil e um de "abrindo", esmaecendo junto.
    private func advancePulse() {
        guard let button = statusItem.button else { return }
        pulsePhase += 1

        let symbols = ["arrow.up.forward.app", state.menuBarSymbol]
        let image = symbolImage(symbols[pulsePhase % symbols.count])
        image?.isTemplate = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            button.animator().alphaValue = pulsePhase % 2 == 0 ? 1 : 0.55
        }
        button.image = image
    }

    // MARK: - Interação

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        let isSecondary =
            event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)

        if isSecondary {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
            return
        }
        guard let button = statusItem.button else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Um app sem Dock não recebe foco sozinho; sem isto os campos do
        // popover não aceitam teclado.
        popover.contentViewController?.view.window?.makeKey()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Menu de clique-direito: dispara um perfil sem precisar abrir o painel.
    private func showContextMenu() {
        closePopover()

        let menu = NSMenu()

        if let pending = state.pendingPrompt {
            let header = NSMenuItem(title: pending.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let confirm = NSMenuItem(
                title: pending.confirmLabel,
                action: #selector(confirmPending), keyEquivalent: "")
            confirm.target = self
            menu.addItem(confirm)

            let decline = NSMenuItem(
                title: pending.declineLabel,
                action: #selector(declinePending), keyEquivalent: "")
            decline.target = self
            menu.addItem(decline)

            menu.addItem(.separator())
        }

        let title = NSMenuItem(title: "Disparar perfil", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        for (index, profile) in state.config.profiles.enumerated() {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(launchProfile(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.target = self
            item.representedObject = profile.id
            item.image = symbolImage(profile.symbolName)
            item.image?.isTemplate = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let report = NSMenuItem(
            title: "Relatório de uso…", action: #selector(openReport), keyEquivalent: "r")
        report.target = self
        menu.addItem(report)

        let preferences = NSMenuItem(
            title: "Preferências…", action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Sair do WakeUpeer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Atribuir e limpar o menu faz o clique-direito abri-lo sem que o
        // clique esquerdo passe a abrir menu em vez do popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Ações do menu

    @objc private func launchProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = state.config.profile(id: id)
        else { return }
        Task { await state.launchManually(profile: profile) }
    }

    @objc private func confirmPending() {
        Task { await state.answer(.confirmed) }
    }

    @objc private func declinePending() {
        Task { await state.answer(.declined) }
    }

    @objc private func openReport() {
        state.showReport()
    }

    @objc private func openPreferences() {
        state.showPreferences()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
