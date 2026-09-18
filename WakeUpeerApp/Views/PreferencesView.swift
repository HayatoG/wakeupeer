import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WakeUpeerDomain
import WakeUpeerPlatformMac

struct PreferencesView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("Geral", systemImage: "gearshape") }

            ProfilesTab(state: state)
                .tabItem { Label("Perfis", systemImage: "person.2") }

            HolidaysTab(state: state)
                .tabItem { Label("Feriados", systemImage: "calendar") }

            TrackingTab(state: state)
                .tabItem { Label("Uso", systemImage: "chart.bar") }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - Geral

private struct GeneralTab: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Início automático") {
                Toggle(
                    "Iniciar junto com o macOS",
                    isOn: Binding(
                        get: { state.loginItemStatus == .enabled },
                        set: { enabled in Task { await state.setLaunchAtLogin(enabled) } }
                    ))

                loginItemStatusRow
            }

            Section {
                LabeledContent("Despertar do sono") {
                    HStack(spacing: 6) {
                        Stepper(
                            value: Binding(
                                get: { state.config.wakeThresholdHours },
                                set: { state.setWakeThreshold($0) }),
                            in: 0...24, step: 0.5
                        ) {
                            Text("\(state.config.wakeThresholdHours, format: .number) h")
                                .monospacedDigit()
                        }
                    }
                }

                LabeledContent("Pausa entre lançamentos") {
                    Stepper(
                        value: Binding(
                            get: { state.config.launchDelayMilliseconds },
                            set: { state.setLaunchDelay($0) }),
                        in: 0...3000, step: 100
                    ) {
                        Text("\(state.config.launchDelayMilliseconds) ms")
                            .monospacedDigit()
                    }
                }

                Picker(
                    "Em feriados",
                    selection: Binding(
                        get: { state.config.holidayBehavior },
                        set: { state.setHolidayBehavior($0) })
                ) {
                    Text("Perguntar se vai trabalhar").tag(HolidayBehavior.ask)
                    Text("Nunca abrir").tag(HolidayBehavior.alwaysSkip)
                    Text("Tratar como dia comum").tag(HolidayBehavior.ignore)
                }
            } header: {
                Text("Comportamento")
            } footer: {
                Text(
                    "O despertar só dispara um perfil se o Mac ficou suspenso por mais tempo que o limite. A pausa evita travar o Dock ao abrir vários apps."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Dados") {
                LabeledContent("Pasta de configuração") {
                    Button("Abrir no Finder") {
                        NSWorkspace.shared.open(state.configDirectory)
                    }
                }
                LabeledContent("Alterações externas") {
                    Button("Recarregar config.json") { state.reloadConfig() }
                }
                if let error = state.storeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(state.configWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// O registro de login falha em silêncio quando o app está fora de
    /// /Applications ou quando o usuário desativou nos Ajustes do Sistema —
    /// os dois casos precisam ficar visíveis.
    @ViewBuilder
    private var loginItemStatusRow: some View {
        switch state.loginItemStatus {
        case .requiresApproval:
            HStack(spacing: 8) {
                Label(
                    "Você desativou o WakeUpeer nos Ajustes do Sistema.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                Spacer()

                Button("Abrir Ajustes") {
                    Task { await state.openLoginItemSettings() }
                }
                .controlSize(.small)
            }

        case .unavailable(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)

        case .enabled, .notRegistered:
            if !state.isInStableLocation {
                Label(
                    "Mova o app para /Applications — fora de lá o início automático não se mantém.",
                    systemImage: "info.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Perfis

private struct ProfilesTab: View {
    let state: AppState
    @State private var selection: Profile.ID?
    @State private var profileToDelete: Profile?

    var body: some View {
        // HStack, e não HSplitView: o NSSplitView por trás dele salva a
        // posição das divisórias em disco sob um nome que não controlamos, e
        // restaurava a geometria de uma versão antiga da janela — 708 pt de
        // subviews numa janela de 640 — deixando o conteúdo encolhido no
        // rodapé. A largura da lista sempre foi fixa, então a divisória
        // arrastável não fazia falta.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(
            "Apagar “\(profileToDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) {
                if let profile = profileToDelete {
                    if selection == profile.id { selection = nil }
                    state.delete(profileID: profile.id)
                }
                profileToDelete = nil
            }
            Button("Cancelar", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.config.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.symbolName)
                            .foregroundStyle(profile.accentColor)
                            .frame(width: 16)
                        Text(profile.name)
                            .foregroundStyle(profile.isEnabled ? .primary : .secondary)
                        Spacer()
                        if !profile.isEnabled {
                            Image(systemName: "pause.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(profile.id)
                }
                .onMove { source, destination in
                    state.moveProfiles(from: source, to: destination)
                }
            }

            Divider()

            HStack(spacing: 2) {
                Button {
                    selection = state.addProfile().id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Novo perfil")

                Button {
                    if let id = selection, let profile = state.config.profile(id: id) {
                        profileToDelete = profile
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Apagar perfil")

                Button {
                    if let id = selection, let profile = state.config.profile(id: id) {
                        selection = state.duplicate(profile: profile).id
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selection == nil)
                .help("Duplicar perfil")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let profile = state.config.profile(id: id) {
            ProfileEditor(profile: profile, state: state)
                .id(id)
        } else {
            ContentUnavailableView(
                "Selecione um perfil",
                systemImage: "person.crop.circle",
                description: Text("Ou crie um novo com o botão +."))
        }
    }
}

// MARK: - Editor

private struct ProfileEditor: View {
    /// Cópia local editável; cada alteração é persistida na hora.
    @State private var draft: Profile
    let state: AppState

    @State private var isImportingApp = false
    @State private var newURL = ""

    init(profile: Profile, state: AppState) {
        _draft = State(initialValue: profile)
        self.state = state
    }

    /// Persiste a cada mudança — não há botão "Salvar" a esquecer.
    private func commit() {
        state.update(profile: draft)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $draft.name)
                    .onSubmit(commit)

                Toggle("Perfil ativo", isOn: $draft.isEnabled)

                Picker("Ícone", selection: $draft.symbolName) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Label(Self.symbolLabel(symbol), systemImage: symbol).tag(symbol)
                    }
                }
            }

            Section("Dias da semana") {
                WeekdayPicker(selection: $draft.weekdays)
                    .padding(.vertical, 2)
            }

            Section {
                TimeField(label: "Início", minutes: $draft.window.startMinutes)
                TimeField(label: "Fim", minutes: $draft.window.endMinutes)

                LabeledContent("Resumo") {
                    Text(windowSummary)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Tolerância") {
                    Stepper(
                        value: $draft.graceMinutes, in: 0...240, step: 15
                    ) {
                        Text(
                            draft.graceMinutes == 0
                                ? "nenhuma" : "\(draft.graceMinutes) min após o fim"
                        )
                        .monospacedDigit()
                    }
                }
            } header: {
                Text("Horário")
            } footer: {
                Text(
                    "Com tolerância, ligar o Mac um pouco depois do fim da janela ainda oferece o perfil. Se o fim for menor ou igual ao início, a janela atravessa a meia-noite."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Perguntar antes em feriados", isOn: $draft.skipOnHoliday)

                LabeledContent("Prioridade") {
                    Stepper(value: $draft.priority, in: 0...100) {
                        Text("\(draft.priority)").monospacedDigit()
                    }
                }
            } header: {
                Text("Regras")
            } footer: {
                Text(
                    "Quando dois perfis se sobrepõem, vence o de maior prioridade; empatando, o de janela mais estreita."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if draft.items.isEmpty {
                    Text("Nenhum item. Adicione um app ou endereço abaixo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($draft.items) { $item in
                    ItemEditorRow(item: $item, draft: $draft, commit: commit)
                }
                .onDelete { offsets in
                    draft.items.remove(atOffsets: offsets)
                    commit()
                }
                .onMove { source, destination in
                    draft.items.move(fromOffsets: source, toOffset: destination)
                    commit()
                }

                HStack(spacing: 8) {
                    Button {
                        isImportingApp = true
                    } label: {
                        Label("Adicionar app", systemImage: "plus.app")
                    }

                    TextField("https://…", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addURL)

                    Button("Adicionar", action: addURL)
                        .disabled(URL(string: newURL)?.scheme == nil)
                }
            } header: {
                Text("Abre \(draft.items.count) \(draft.items.count == 1 ? "item" : "itens")")
            } footer: {
                Text("Arraste para reordenar — os itens abrem nesta ordem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Persiste a cada alteração de controle; o TextField usa onSubmit.
        .onChange(of: draft.isEnabled) { _, _ in commit() }
        .onChange(of: draft.symbolName) { _, _ in commit() }
        .onChange(of: draft.weekdays) { _, _ in commit() }
        .onChange(of: draft.window) { _, _ in commit() }
        .onChange(of: draft.graceMinutes) { _, _ in commit() }
        .onChange(of: draft.skipOnHoliday) { _, _ in commit() }
        .onChange(of: draft.priority) { _, _ in commit() }
        .onDisappear(perform: commit)
        .fileImporter(
            isPresented: $isImportingApp,
            allowedContentTypes: [.application],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addApp(at: url) }
        }
    }

    // MARK: Ações

    private func addApp(at url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        draft.items.append(
            ProfileItem(
                item: .application(bundleID: bundleID, displayName: name, path: url.path)))
        commit()
    }

    private func addURL() {
        guard let url = URL(string: newURL), url.scheme != nil else { return }
        draft.items.append(ProfileItem(item: .url(url)))
        newURL = ""
        commit()
    }

    // MARK: Apoio

    private var windowSummary: String {
        let window = draft.window
        if window.isAllDay { return "dia inteiro" }
        let range = "\(Profile.hhmm(window.startMinutes))–\(Profile.hhmm(window.endMinutes))"
        let duration = DurationFormat.short(TimeInterval(window.durationMinutes * 60))
        if window.crossesMidnight {
            return "\(range) · \(duration) · atravessa a meia-noite"
        }
        return "\(range) · \(duration)"
    }

    static let symbols = [
        "briefcase", "laptopcomputer", "moon", "moon.stars", "sun.max", "sun.horizon",
        "figure.walk", "gamecontroller", "book", "music.note", "heart", "circle",
    ]

    static func symbolLabel(_ symbol: String) -> String {
        switch symbol {
        case "briefcase": "Trabalho"
        case "laptopcomputer": "Computador"
        case "moon": "Noite"
        case "moon.stars": "Madrugada"
        case "sun.max": "Dia"
        case "sun.horizon": "Manhã"
        case "figure.walk": "Lazer"
        case "gamecontroller": "Jogos"
        case "book": "Estudo"
        case "music.note": "Música"
        case "heart": "Pessoal"
        default: "Genérico"
        }
    }
}

// MARK: - Linha de item

private struct ItemEditorRow: View {
    @Binding var item: ProfileItem
    @Binding var draft: Profile
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $item.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .onChange(of: item.isEnabled) { _, _ in commit() }

            icon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.item.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.isEnabled ? .primary : .secondary)
                if case .url(let url) = item.item {
                    Text(url.absoluteString)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Button {
                setBringToFront(!item.bringToFront)
            } label: {
                Image(
                    systemName: item.bringToFront
                        ? "arrow.up.forward.app.fill" : "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(item.bringToFront ? Color.accentColor : .secondary)
            .help("Trazer para frente ao abrir")
        }
    }

    /// Só um item por perfil pode reivindicar o primeiro plano; deixar dois
    /// faz a ordem de lançamento decidir por sorteio.
    private func setBringToFront(_ value: Bool) {
        if value {
            for index in draft.items.indices {
                draft.items[index].bringToFront = (draft.items[index].id == item.id)
            }
        } else {
            item.bringToFront = false
        }
        commit()
    }

    @ViewBuilder
    private var icon: some View {
        if case .application(let bundleID, _, _) = item.item,
           let image = NSWorkspaceAppLauncher.icon(forBundleID: bundleID)
        {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: fallbackSymbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private var fallbackSymbol: String {
        switch item.item {
        case .application: "app.dashed"
        case .url: "globe"
        case .file: "doc"
        case .shell: "terminal"
        }
    }
}

// MARK: - Controles

/// Sete botões em vez de um menu: você vê o conjunto inteiro de uma vez.
private struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    private let ordered: [Weekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ordered, id: \.self) { day in
                    let isOn = selection.contains(day)
                    Button {
                        if isOn { selection.remove(day) } else { selection.insert(day) }
                    } label: {
                        Text(Self.label(day))
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 34, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.06)))
                            .foregroundStyle(isOn ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Button("Dias úteis") { selection = Weekday.workdays }
                Button("Fim de semana") { selection = Weekday.weekend }
                Button("Todos") { selection = Weekday.everyDay }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private static func label(_ day: Weekday) -> String {
        switch day {
        case .monday: "Seg"
        case .tuesday: "Ter"
        case .wednesday: "Qua"
        case .thursday: "Qui"
        case .friday: "Sex"
        case .saturday: "Sáb"
        case .sunday: "Dom"
        }
    }
}

/// Campo de hora que trabalha em minutos desde a meia-noite, sem converter
/// para Date e voltar — a ida e volta introduziria fuso horário onde não há.
private struct TimeField: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Stepper(value: hourBinding, in: 0...23) {
                    Text(pad(minutes / 60)).monospacedDigit().frame(width: 24)
                }
                Text(":").foregroundStyle(.secondary)
                Stepper(value: minuteBinding, in: 0...59, step: 5) {
                    Text(pad(minutes % 60)).monospacedDigit().frame(width: 24)
                }
            }
        }
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { minutes / 60 },
            set: { minutes = $0 * 60 + (minutes % 60) })
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { minutes % 60 },
            set: { minutes = (minutes / 60) * 60 + $0 })
    }

    private func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

// MARK: - Feriados

private struct HolidaysTab: View {
    let state: AppState

    var body: some View {
        Form {
            Section {
                switch state.calendarAuthorization {
                case .authorized:
                    Label("Acesso ao Calendário concedido", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)

                case .notDetermined:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "Conceda acesso ao Calendário para detectar feriados municipais, estaduais e datas pessoais."
                        )
                        .font(.callout)
                        Button("Permitir acesso ao Calendário") {
                            Task { await state.requestCalendarAccess() }
                        }
                    }

                case .denied, .writeOnly:
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            state.calendarAuthorization == .writeOnly
                                ? "O acesso concedido é somente de escrita e não permite ler feriados."
                                : "Acesso ao Calendário negado.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                        Button("Abrir Ajustes de Privacidade") {
                            state.openCalendarSettings()
                        }
                    }
                }
            } header: {
                Text("Permissão")
            } footer: {
                Text(
                    "Os feriados nacionais brasileiros — incluindo Carnaval, Sexta-feira Santa e Corpus Christi — são calculados localmente e funcionam mesmo sem esta permissão."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if state.calendarAuthorization == .authorized {
                Section("Calendários consultados") {
                    if state.availableCalendars.isEmpty {
                        Text("Nenhum calendário encontrado.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(state.availableCalendars) { info in
                        Toggle(
                            isOn: Binding(
                                get: { state.config.holidayCalendarIDs.contains(info.id) },
                                set: { isOn in
                                    var ids = state.config.holidayCalendarIDs
                                    if isOn {
                                        if !ids.contains(info.id) { ids.append(info.id) }
                                    } else {
                                        ids.removeAll { $0 == info.id }
                                    }
                                    state.setHolidayCalendars(ids)
                                })
                        ) {
                            HStack(spacing: 6) {
                                Text(info.title)
                                if info.isSubscribed {
                                    Text("assinado")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Hoje") {
                switch state.todayHoliday {
                case .holiday(let names):
                    Label(names.joined(separator: ", "), systemImage: "party.popper.fill")
                        .foregroundStyle(.orange)
                case .notHoliday:
                    Label("Dia comum", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Label(reason, systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Próximos feriados nacionais") {
                ForEach(upcomingHolidays, id: \.label) { entry in
                    LabeledContent(entry.name) {
                        Text(entry.label)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshCalendars() }
    }

    /// Os cinco próximos feriados nacionais, a partir da tabela local.
    private var upcomingHolidays: [(name: String, label: String)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let year = calendar.component(.year, from: today)

        var entries: [(Date, String)] = []
        for target in [year, year + 1] {
            for holiday in BrazilianHolidays.holidays(year: target) {
                var components = DateComponents()
                components.year = target
                components.month = holiday.month
                components.day = holiday.day
                components.hour = 12
                if let date = calendar.date(from: components), date >= today {
                    entries.append((date, holiday.name))
                }
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEE, d 'de' MMM"

        return entries
            .sorted { $0.0 < $1.0 }
            .prefix(5)
            .map { (name: $0.1, label: formatter.string(from: $0.0)) }
    }
}

// MARK: - Uso

private struct TrackingTab: View {
    let state: AppState
    @State private var isConfirmingErase = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Registrar tempo de uso",
                    isOn: Binding(
                        get: { state.config.tracking.isEnabled },
                        set: { enabled in
                            var tracking = state.config.tracking
                            tracking.isEnabled = enabled
                            state.setTracking(tracking)
                        }))

                LabeledContent("Considerar ocioso após") {
                    Stepper(
                        value: Binding(
                            get: { state.config.tracking.idleThresholdSeconds / 60 },
                            set: { minutes in
                                var tracking = state.config.tracking
                                tracking.idleThresholdSeconds = minutes * 60
                                state.setTracking(tracking)
                            }), in: 1...60
                    ) {
                        Text("\(state.config.tracking.idleThresholdSeconds / 60) min")
                            .monospacedDigit()
                    }
                }

                LabeledContent("Guardar histórico por") {
                    Stepper(
                        value: Binding(
                            get: { state.config.tracking.retentionDays },
                            set: { days in
                                var tracking = state.config.tracking
                                tracking.retentionDays = days
                                state.setTracking(tracking)
                            }), in: 7...730, step: 30
                    ) {
                        Text("\(state.config.tracking.retentionDays) dias")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Rastreamento")
            } footer: {
                Text(
                    "O WakeUpeer registra qual app está em primeiro plano e por quanto tempo. Nada sai do seu Mac, e títulos de janela nunca são lidos."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Resumo semanal") {
                Toggle(
                    "Avisar quando a semana fechar",
                    isOn: Binding(
                        get: { state.config.weeklyReportEnabled },
                        set: {
                            state.setWeeklyReport(
                                enabled: $0,
                                weekday: state.config.weeklyReportWeekday,
                                hour: state.config.weeklyReportHour)
                        }))

                if state.config.weeklyReportEnabled {
                    Picker(
                        "Dia",
                        selection: Binding(
                            get: { state.config.weeklyReportWeekday },
                            set: {
                                state.setWeeklyReport(
                                    enabled: state.config.weeklyReportEnabled,
                                    weekday: $0, hour: state.config.weeklyReportHour)
                            })
                    ) {
                        Text("Sexta-feira").tag(Weekday.friday)
                        Text("Segunda-feira").tag(Weekday.monday)
                        Text("Domingo").tag(Weekday.sunday)
                    }

                    LabeledContent("Horário") {
                        Stepper(
                            value: Binding(
                                get: { state.config.weeklyReportHour },
                                set: {
                                    state.setWeeklyReport(
                                        enabled: state.config.weeklyReportEnabled,
                                        weekday: state.config.weeklyReportWeekday, hour: $0)
                                }), in: 0...23
                        ) {
                            Text("\(state.config.weeklyReportHour)h").monospacedDigit()
                        }
                    }
                }
            }

            Section {
                LabeledContent("Tempo ativo hoje") {
                    Text(DurationFormat.short(state.activeToday))
                        .monospacedDigit()
                }

                Button("Apagar todo o histórico de uso", role: .destructive) {
                    isConfirmingErase = true
                }
            } header: {
                Text("Dados")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Apagar todo o histórico de uso?",
            isPresented: $isConfirmingErase, titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) { state.eraseTrackingData() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Os relatórios ficarão vazios. Esta ação não pode ser desfeita.")
        }
    }
}
