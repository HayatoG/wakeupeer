import AppKit
import SwiftUI
import WakeUpeerDomain

/// Preferências. Na Fase 1 ainda é somente leitura: a edição de verdade
/// acontece no config.json. O editor completo chega na Fase 3.
struct PreferencesView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("Geral", systemImage: "gearshape") }

            ProfilesTab(state: state)
                .tabItem { Label("Perfis", systemImage: "person.2") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Geral

private struct GeneralTab: View {
    let state: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("Threshold de wake") {
                    Text("\(state.config.wakeThresholdHours, format: .number) h")
                }
                LabeledContent("Pausa entre lançamentos") {
                    Text("\(state.config.launchDelayMilliseconds) ms")
                }
                LabeledContent("Feriados") {
                    Text(holidayBehaviorLabel)
                }
            } header: {
                Text("Comportamento")
            }

            Section {
                LabeledContent("Pasta de dados") {
                    Button("Abrir no Finder") {
                        NSWorkspace.shared.open(state.configDirectory)
                    }
                }
                LabeledContent("Configuração") {
                    Button("Recarregar config.json") {
                        state.reloadConfig()
                    }
                }
                if let error = state.storeError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Dados")
            } footer: {
                Text("Nesta fase os perfis são editados direto no config.json. O editor gráfico chega em seguida.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var holidayBehaviorLabel: String {
        switch state.config.holidayBehavior {
        case .ask: "Perguntar se vai trabalhar"
        case .alwaysSkip: "Nunca abrir em feriado"
        case .ignore: "Tratar como dia comum"
        }
    }
}

// MARK: - Perfis

private struct ProfilesTab: View {
    let state: AppState
    @State private var selection: Profile.ID?

    var body: some View {
        NavigationSplitView {
            List(state.config.profiles, selection: $selection) { profile in
                Label(profile.name, systemImage: profile.symbolName)
                    .foregroundStyle(profile.isEnabled ? .primary : .secondary)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            if let selection, let profile = state.config.profile(id: selection) {
                ProfileDetail(profile: profile)
            } else {
                ContentUnavailableView(
                    "Selecione um perfil", systemImage: "person.crop.circle")
            }
        }
    }
}

private struct ProfileDetail: View {
    let profile: Profile

    var body: some View {
        Form {
            Section("Quando") {
                LabeledContent("Dias", value: weekdaysLabel)
                LabeledContent("Horário", value: windowLabel)
                if profile.graceMinutes > 0 {
                    LabeledContent("Tolerância", value: "\(profile.graceMinutes) min após o fim")
                }
                LabeledContent("Prioridade", value: "\(profile.priority)")
                if profile.skipOnHoliday {
                    Label("Pergunta antes em feriado", systemImage: "party.popper")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Abre") {
                ForEach(profile.enabledItems) { item in
                    HStack {
                        Text(item.item.displayName)
                        if item.bringToFront {
                            Spacer()
                            Text("em foco")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var weekdaysLabel: String {
        let names: [Weekday: String] = [
            .monday: "Seg", .tuesday: "Ter", .wednesday: "Qua", .thursday: "Qui",
            .friday: "Sex", .saturday: "Sáb", .sunday: "Dom",
        ]
        if profile.weekdays == Weekday.workdays { return "Seg–Sex" }
        if profile.weekdays == Weekday.weekend { return "Sáb–Dom" }
        if profile.weekdays == Weekday.everyDay { return "Todo dia" }
        return profile.weekdays
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { names[$0] }
            .joined(separator: ", ")
    }

    private var windowLabel: String {
        let window = profile.window
        if window.isAllDay { return "Dia inteiro" }
        let suffix = window.crossesMidnight ? " (atravessa a meia-noite)" : ""
        return "\(format(window.startMinutes))–\(format(window.endMinutes))\(suffix)"
    }

    private func format(_ minutes: Int) -> String {
        let hour = minutes / 60
        let minute = minutes % 60
        let hh = hour < 10 ? "0\(hour)" : "\(hour)"
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(hh):\(mm)"
    }
}
