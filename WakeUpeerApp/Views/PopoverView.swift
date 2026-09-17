import AppKit
import SwiftUI
import WakeUpeerDomain
import WakeUpeerPlatformMac

/// O painel que abre ao clicar no ícone da barra.
struct PopoverView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: state)

            if let prompt = state.pendingPrompt {
                PromptBanner(prompt: prompt) { answer in
                    Task { await state.answer(answer) }
                }
                .transition(
                    .asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal: .opacity))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let profile = state.activeProfile {
                        ProfileItemsSection(profile: profile, state: state)
                    } else {
                        IdleSection(state: state)
                    }

                    if let report = state.lastReport, report.hasFailures {
                        FailuresSection(report: report)
                    }

                    OtherAppsSection(state: state)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)

            FooterView(state: state, openWindow: openWindow)
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
        // O material deixa o conteúdo atrás transparecer, como nas janelas do sistema.
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.28), value: state.pendingPrompt)
        .animation(.snappy(duration: 0.28), value: state.activeProfile?.id)
        .task { await state.refreshRunningApps() }
        .task {
            // Os tempos sobem à vista, mas só enquanto o painel está aberto:
            // um timer de 1 s rodando o dia inteiro não se justifica.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                state.refreshTick()
            }
        }
    }
}

// MARK: - Cabeçalho

private struct HeaderView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileGlyph(
                    symbol: state.menuBarSymbol,
                    tint: state.activeProfile?.accentColor ?? .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.salutation)
                        .font(.system(size: 15, weight: .semibold))
                        // Tracking negativo: textos maiores pedem letras mais próximas.
                        .tracking(-0.2)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if state.isLaunching {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if state.isTrackingEnabled {
                TodayStrip(state: state)
                    .padding(.horizontal, 14)
                    .padding(.bottom, state.todayHoliday.isHoliday ? 8 : 12)
            }

            if state.todayHoliday.isHoliday {
                HolidayChip(names: state.todayHoliday.names)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var subtitle: String {
        if let profile = state.activeProfile {
            return "\(profile.name) · \(profile.windowLabel)"
        }
        return "Nenhum perfil ativo agora"
    }
}

/// Círculo com o símbolo do perfil. Substitui o ícone solto por algo com peso visual.
private struct ProfileGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Resumo do dia: tempo ativo, onde o foco está agora e o app campeão.
private struct TodayStrip: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Metric(
                label: "Ativo hoje",
                value: DurationFormat.short(state.activeToday),
                symbol: "clock")

            Divider().frame(height: 26).padding(.horizontal, 10)

            if let focused = state.focusedBundleID {
                Metric(
                    label: "Em foco",
                    value: DurationFormat.short(state.timeToday(bundleID: focused)),
                    symbol: "scope",
                    tint: .green)
            } else {
                Metric(label: "Em foco", value: "—", symbol: "scope")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        // Redesenha quando o relógio do popover avança.
        .id(state.tick)
    }
}

private struct Metric: View {
    let label: String
    let value: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5))
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .tracking(-0.2)
                .contentTransition(.numericText())
        }
    }
}

private struct HolidayChip: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 9))
            Text(names.joined(separator: " · "))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Prompt de confirmação

/// Espelha a notificação do sistema, para o caso de ela ter sido
/// descartada ou silenciada pelo modo de Foco.
private struct PromptBanner: View {
    let prompt: Prompt
    let onAnswer: (PromptAnswer) -> Void

    private var tint: Color { prompt.isHolidayPrompt ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: prompt.isHolidayPrompt ? "party.popper.fill" : "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.1)
                    Text(prompt.body)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button(prompt.confirmLabel) { onAnswer(.confirmed) }
                    .buttonStyle(FilledButtonStyle(tint: tint))

                Button(prompt.declineLabel) { onAnswer(.declined) }
                    .buttonStyle(QuietButtonStyle())

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07))
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - Itens do perfil

private struct ProfileItemsSection: View {
    let profile: Profile
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(
                text: "Itens de \(profile.name)",
                trailing: "\(runningCount)/\(profile.enabledItems.count)")

            VStack(spacing: 1) {
                ForEach(profile.enabledItems) { item in
                    ItemRow(
                        item: item,
                        isRunning: state.isRunning(item),
                        isFocused: isFocused(item),
                        timeToday: state.timeToday(item),
                        showsTime: state.isTrackingEnabled)
                }
            }
            .id(state.tick)
        }
    }

    private var runningCount: Int {
        profile.enabledItems.filter { state.isRunning($0) }.count
    }

    private func isFocused(_ item: ProfileItem) -> Bool {
        guard case .application(let bundleID, _, _) = item.item else { return false }
        return state.focusedBundleID == bundleID
    }
}

private struct ItemRow: View {
    let item: ProfileItem
    let isRunning: Bool
    let isFocused: Bool
    let timeToday: TimeInterval
    let showsTime: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item.item)

            Text(item.item.displayName)
                .font(.system(size: 12.5))
                .foregroundStyle(isRunning ? .primary : .secondary)

            Spacer(minLength: 8)

            if showsTime, timeToday >= 60 {
                Text(DurationFormat.short(timeToday))
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.numericText())
            }

            if item.bringToFront {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Este item vem para frente ao abrir")
            }

            StatusDot(isRunning: isRunning, isFocused: isFocused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isRunning ? Color.primary.opacity(0.045) : .clear))
        .animation(.snappy(duration: 0.2), value: isRunning)
    }
}

private struct ItemIcon: View {
    let item: LaunchItem

    var body: some View {
        Group {
            if case .application(let bundleID, _, _) = item,
               let icon = NSWorkspaceAppLauncher.icon(forBundleID: bundleID)
            {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 19, height: 19)
    }

    private var fallbackSymbol: String {
        switch item {
        case .application: "app.dashed"
        case .url: "globe"
        case .file: "doc"
        case .shell: "terminal"
        }
    }
}

private struct StatusDot: View {
    let isRunning: Bool
    var isFocused: Bool = false

    var body: some View {
        Circle()
            .fill(isRunning ? Color.green : Color.secondary.opacity(0.25))
            .frame(width: 6, height: 6)
            .overlay {
                // O halo dá presença ao estado ativo sem precisar de texto,
                // e fica mais forte no app que está em foco agora.
                if isRunning {
                    Circle()
                        .stroke(
                            Color.green.opacity(isFocused ? 0.45 : 0.22),
                            lineWidth: isFocused ? 4 : 3)
                        .frame(width: isFocused ? 12 : 10, height: isFocused ? 12 : 10)
                }
            }
            .animation(.snappy(duration: 0.2), value: isFocused)
            .help(isFocused ? "Em foco agora" : (isRunning ? "Rodando" : "Fechado"))
    }
}

// MARK: - Ocioso

private struct IdleSection: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Próximos perfis")

            VStack(spacing: 1) {
                ForEach(state.config.profiles.filter(\.isEnabled)) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(profile.accentColor)
                            .frame(width: 19)

                        Text(profile.name)
                            .font(.system(size: 12.5))

                        Spacer(minLength: 8)

                        Text(profile.scheduleLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

// MARK: - Falhas

private struct FailuresSection: View {
    let report: LaunchReport

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Falhas no último disparo", tint: .orange)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(report.failures) { failure in
                    if case .failed(let reason) = failure.outcome {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .padding(.top, 1.5)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(reason)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Outros apps

private struct OtherAppsSection: View {
    let state: AppState
    @State private var isExpanded = false

    /// Ordenados por tempo de hoje: o que você mais usou aparece primeiro.
    private var otherApps: [RunningApp] {
        let profileBundleIDs = Set(
            (state.activeProfile?.enabledItems ?? []).compactMap { item -> String? in
                guard case .application(let bundleID, _, _) = item.item else { return nil }
                return bundleID
            })
        return state.runningApps
            .filter { !profileBundleIDs.contains($0.bundleID) }
            .sorted { state.timeToday(bundleID: $0.bundleID) > state.timeToday(bundleID: $1.bundleID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)

                    Text("Outros apps abertos")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .foregroundStyle(.secondary)

                    Text("\(otherApps.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(otherApps) { app in
                        HStack(spacing: 10) {
                            if let icon = NSWorkspaceAppLauncher.icon(forBundleID: app.bundleID) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                            Text(app.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 8)

                            let elapsed = state.timeToday(bundleID: app.bundleID)
                            if state.isTrackingEnabled, elapsed >= 60 {
                                Text(DurationFormat.short(elapsed))
                                    .font(.system(size: 10, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }

                            if app.isActive {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 5, height: 5)
                                    .help("Em foco agora")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
                .id(state.tick)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: isExpanded)
    }
}

// MARK: - Rodapé

private struct FooterView: View {
    let state: AppState
    let openWindow: OpenWindowAction

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(state.config.profiles) { profile in
                    Button {
                        Task { await state.launchManually(profile: profile) }
                    } label: {
                        Label(profile.name, systemImage: profile.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text("Disparar perfil").font(.system(size: 12, weight: .medium))
                }
            }
            .menuStyle(.button)
            .buttonStyle(QuietButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: 0)

            IconButton(symbol: "chart.bar", help: "Relatório de uso") {
                (NSApp.delegate as? AppDelegate)?.showReportWindow()
            }

            IconButton(symbol: "gearshape", help: "Preferências") {
                activateApp()
                openWindow(id: WindowID.preferences)
            }

            IconButton(symbol: "power", help: "Sair do WakeUpeer") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35))
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Componentes compartilhados

private struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                // Tracking positivo: texto pequeno em caixa alta precisa de ar.
                .tracking(0.4)
                .foregroundStyle(tint ?? .secondary)

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 0.5)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isHovering)
        .help(help)
    }
}

/// Botão de ação primária. O reflexo acontece no pressionar, não no soltar.
private struct FilledButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    Color.primary.opacity(
                        configuration.isPressed ? 0.14 : (isHovering ? 0.09 : 0.055))))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .animation(.snappy(duration: 0.15), value: isHovering)
    }
}

// MARK: - Apoio de apresentação

extension Profile {
    /// Cor derivada do nome, estável entre execuções: o mesmo perfil mantém
    /// sempre a mesma cor sem precisar guardá-la na configuração.
    var accentColor: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    var windowLabel: String {
        if window.isAllDay { return "dia inteiro" }
        return "\(Self.hhmm(window.startMinutes))–\(Self.hhmm(window.endMinutes))"
    }

    var scheduleLabel: String {
        "\(weekdaysShortLabel) · \(windowLabel)"
    }

    var weekdaysShortLabel: String {
        if weekdays == Weekday.workdays { return "Seg–Sex" }
        if weekdays == Weekday.weekend { return "Sáb–Dom" }
        if weekdays == Weekday.everyDay { return "Todo dia" }
        let names: [Weekday: String] = [
            .monday: "Seg", .tuesday: "Ter", .wednesday: "Qua", .thursday: "Qui",
            .friday: "Sex", .saturday: "Sáb", .sunday: "Dom",
        ]
        return weekdays
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { names[$0] }
            .joined(separator: ", ")
    }

    static func hhmm(_ minutes: Int) -> String {
        let hour = minutes / 60
        let minute = minutes % 60
        let hh = hour < 10 ? "0\(hour)" : "\(hour)"
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(hh):\(mm)"
    }
}
