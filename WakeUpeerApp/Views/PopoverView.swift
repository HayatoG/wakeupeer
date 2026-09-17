import AppKit
import SwiftUI
import WakeUpeerDomain
import WakeUpeerPlatformMac

/// O painel que abre ao clicar no ícone da barra.
struct PopoverView: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header

            if let prompt = state.pendingPrompt {
                Divider()
                PromptBanner(prompt: prompt) { answer in
                    Task { await state.answer(answer) }
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let profile = state.activeProfile {
                        ProfileItemsSection(profile: profile, state: state)
                    } else {
                        Text("Nenhum perfil ativo agora.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let report = state.lastReport, report.hasFailures {
                        FailuresSection(report: report)
                    }

                    OtherAppsSection(state: state)
                }
                .padding(12)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 520)
        .task {
            await state.bootstrap()
        }
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.salutation)!")
                    .font(.headline)
                if let profile = state.activeProfile {
                    Text("Perfil ativo: \(profile.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Fora de qualquer janela")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if state.isLaunching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .overlay(alignment: .bottom) {
            if state.todayHoliday.isHoliday {
                HolidayBadge(names: state.todayHoliday.names)
            }
        }
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack(spacing: 8) {
            Menu("Disparar perfil") {
                ForEach(state.config.profiles) { profile in
                    Button(profile.name) {
                        Task { await state.launchManually(profile: profile) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Preferências")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Sair do WakeUpeer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Prompt de confirmação

/// O banner que aparece quando um perfil quer disparar. Espelha a notificação
/// do sistema, para o caso de ela ter sido descartada ou silenciada pelo Foco.
private struct PromptBanner: View {
    let prompt: Prompt
    let onAnswer: (PromptAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: prompt.isHolidayPrompt ? "party.popper" : "bell.badge")
                    .foregroundStyle(.tint)
                Text(prompt.title).font(.headline)
            }
            Text(prompt.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(prompt.confirmLabel) { onAnswer(.confirmed) }
                    .buttonStyle(.borderedProminent)
                Button(prompt.declineLabel) { onAnswer(.declined) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08))
    }
}

private struct HolidayBadge: View {
    let names: [String]

    var body: some View {
        Text("Feriado: \(names.joined(separator: ", "))")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.2), in: Capsule())
            .padding(.bottom, 2)
    }
}

// MARK: - Itens do perfil

private struct ProfileItemsSection: View {
    let profile: Profile
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Itens de \(profile.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(profile.enabledItems) { item in
                HStack(spacing: 8) {
                    ItemIcon(item: item.item)
                    Text(item.item.displayName)
                        .font(.callout)
                    Spacer()
                    StatusDot(isRunning: state.isRunning(item))
                }
            }
        }
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
                Image(systemName: fallbackSymbol).resizable().scaledToFit()
            }
        }
        .frame(width: 18, height: 18)
    }

    private var fallbackSymbol: String {
        switch item {
        case .application: "app"
        case .url: "globe"
        case .file: "doc"
        case .shell: "terminal"
        }
    }
}

private struct StatusDot: View {
    let isRunning: Bool

    var body: some View {
        Circle()
            .fill(isRunning ? .green : .secondary.opacity(0.3))
            .frame(width: 7, height: 7)
            .help(isRunning ? "Rodando" : "Fechado")
    }
}

// MARK: - Falhas

private struct FailuresSection: View {
    let report: LaunchReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Falhas no último disparo", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(report.failures) { failure in
                if case .failed(let reason) = failure.outcome {
                    Text("\(failure.displayName): \(reason)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Outros apps

private struct OtherAppsSection: View {
    let state: AppState
    @State private var isExpanded = false

    private var otherApps: [RunningApp] {
        let profileBundleIDs = Set(
            (state.activeProfile?.enabledItems ?? []).compactMap { item -> String? in
                guard case .application(let bundleID, _, _) = item.item else { return nil }
                return bundleID
            })
        return state.runningApps.filter { !profileBundleIDs.contains($0.bundleID) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(otherApps) { app in
                    HStack(spacing: 8) {
                        if let icon = NSWorkspaceAppLauncher.icon(forBundleID: app.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(app.name).font(.caption)
                        Spacer()
                        if app.isActive {
                            Text("em foco")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Outros apps abertos (\(otherApps.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
