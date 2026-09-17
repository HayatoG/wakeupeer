import AppKit
import Foundation
import WakeUpeerDomain

/// Rastreia quanto tempo cada app passa em primeiro plano.
///
/// Grava **intervalos**, não amostras: uma sessão em memória só vira um
/// `TrackingEvent` quando o app em foco muda, o usuário fica ocioso, a
/// máquina dorme ou o dia vira. Amostrar a cada 15s daria ~2 milhões de
/// registros por ano; assim ficam ~300 por dia.
@MainActor
public final class UsageTracker {

    // MARK: Sessão corrente

    private struct Session {
        var bundleID: String
        var appName: String
        var start: Date
        var kind: TrackingEvent.Kind
    }

    private var current: Session?
    private var buffer: [TrackingEvent] = []

    /// Quanto cada app acumulou hoje, para o popover ler sem tocar no disco.
    public private(set) var todayTotals: [String: TimeInterval] = [:]
    /// Tempo ativo total de hoje, sem contar ocioso, sono e tela bloqueada.
    public private(set) var todayActive: TimeInterval = 0

    // MARK: Dependências

    private let store: any StateStore
    private let clock: any Clock
    private var config: TrackingConfig
    /// Preenchido pelo app: em qual perfil o tempo está sendo gasto.
    public var currentProfileID: UUID?

    private var timer: Timer?
    private var flushTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isScreenLocked = false

    /// Relógio monotônico: `Date` salta com ajuste de NTP e inventaria
    /// buracos que não existiram.
    private var lastTick: ContinuousClock.Instant
    private let continuousClock = ContinuousClock()

    public init(store: any StateStore, clock: any Clock, config: TrackingConfig) {
        self.store = store
        self.clock = clock
        self.config = config
        self.lastTick = ContinuousClock().now
    }

    // MARK: - Ciclo de vida

    public func start() {
        guard config.isEnabled else { return }
        loadToday()
        observeWorkspace()
        startTimers()
        openSession(for: NSWorkspace.shared.frontmostApplication)
    }

    public func stop() {
        closeSession(at: clock.now)
        flush()
        timer?.invalidate()
        flushTimer?.invalidate()
        timer = nil
        flushTimer = nil

        let center = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        observers = []
    }

    public func update(config newConfig: TrackingConfig) {
        let wasEnabled = config.isEnabled
        config = newConfig
        if newConfig.isEnabled && !wasEnabled {
            start()
        } else if !newConfig.isEnabled && wasEnabled {
            stop()
        }
    }

    private func startTimers() {
        // A tolerância permite ao sistema agrupar disparos e poupar bateria.
        let sample = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(config.sampleIntervalSeconds), repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sample.tolerance = 5
        timer = sample

        let flush = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        flush.tolerance = 10
        flushTimer = flush
    }

    // MARK: - Observação do sistema

    /// As notificações do NSWorkspace dão as trocas de app com precisão e
    /// custo zero; o timer existe só como rede de segurança e para o ocioso.
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in self?.switchTo(app) }
            })

        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.beginSystemState(.sleep) }
            })

        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.lastTick = ContinuousClock().now
                    self?.switchTo(NSWorkspace.shared.frontmostApplication)
                }
            })

        let distributed = DistributedNotificationCenter.default()
        observers.append(
            distributed.addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isScreenLocked = true
                    self?.beginSystemState(.locked)
                }
            })

        observers.append(
            distributed.addObserver(
                forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isScreenLocked = false
                    self?.switchTo(NSWorkspace.shared.frontmostApplication)
                }
            })
    }

    // MARK: - Amostragem

    private func tick() {
        let now = clock.now
        let tickNow = continuousClock.now
        let elapsed = lastTick.duration(to: tickNow)
        let elapsedSeconds = Double(elapsed.components.seconds)
        lastTick = tickNow

        // Um salto muito maior que o intervalo significa que a máquina dormiu
        // sem avisar (queda de bateria, sono abrupto). O buraco vira `.sleep`.
        let expected = Double(config.sampleIntervalSeconds)
        if elapsedSeconds > expected * 2 {
            closeSession(at: now.addingTimeInterval(-elapsedSeconds))
            record(
                TrackingEvent(
                    start: now.addingTimeInterval(-elapsedSeconds),
                    end: now,
                    bundleID: "system.sleep",
                    appName: "Suspenso",
                    profileID: currentProfileID,
                    kind: .sleep))
            switchTo(NSWorkspace.shared.frontmostApplication)
            return
        }

        guard !isScreenLocked else { return }

        let idle = Self.idleSeconds()
        let isIdle = idle >= Double(config.idleThresholdSeconds)

        if isIdle, current?.kind == .foreground {
            // Retroage o fim da sessão para quando a inatividade começou;
            // sem isso, cada transição infla o total com minutos fantasmas.
            closeSession(at: now.addingTimeInterval(-idle))
            current = Session(
                bundleID: "system.idle", appName: "Ocioso",
                start: now.addingTimeInterval(-idle), kind: .idle)
            return
        }

        if !isIdle, current?.kind == .idle {
            switchTo(NSWorkspace.shared.frontmostApplication)
            return
        }

        // Rede de segurança: uma notificação de troca pode ter se perdido.
        if !isIdle, let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier, bundleID != current?.bundleID
        {
            switchTo(front)
        }

        // Fecha a sessão na virada do dia para os totais diários baterem.
        if let session = current,
           !clock.calendar.isDate(session.start, inSameDayAs: now)
        {
            let midnight = clock.calendar.startOfDay(for: now)
            closeSession(at: midnight)
            current = Session(
                bundleID: session.bundleID, appName: session.appName,
                start: midnight, kind: session.kind)
            todayTotals = [:]
            todayActive = 0
        }
    }

    /// Segundos desde o último evento de entrada. Não exige permissão de
    /// Acessibilidade nem de Monitoramento de Entrada.
    private static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .init(rawValue: ~0)!)
    }

    // MARK: - Transições de sessão

    private func switchTo(_ app: NSRunningApplication?) {
        let now = clock.now
        guard let app, let bundleID = app.bundleIdentifier else {
            closeSession(at: now)
            return
        }
        guard bundleID != current?.bundleID || current?.kind != .foreground else { return }

        closeSession(at: now)
        guard !config.excludedBundleIDs.contains(bundleID) else { return }

        current = Session(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            start: now,
            kind: .foreground)
    }

    private func openSession(for app: NSRunningApplication?) {
        switchTo(app)
    }

    private func beginSystemState(_ kind: TrackingEvent.Kind) {
        let now = clock.now
        closeSession(at: now)
        current = Session(
            bundleID: kind == .sleep ? "system.sleep" : "system.locked",
            appName: kind == .sleep ? "Suspenso" : "Bloqueado",
            start: now,
            kind: kind)
        flush()
    }

    private func closeSession(at end: Date) {
        guard let session = current else { return }
        current = nil
        guard end > session.start else { return }

        record(
            TrackingEvent(
                start: session.start,
                end: end,
                bundleID: session.bundleID,
                appName: session.appName,
                profileID: currentProfileID,
                kind: session.kind))
    }

    private func record(_ event: TrackingEvent) {
        buffer.append(event)
        guard event.kind == .foreground else { return }
        todayTotals[event.bundleID, default: 0] += event.duration
        todayActive += event.duration
    }

    // MARK: - Escrita

    /// Zera os totais em memória depois que o histórico é apagado.
    public func resetToday() {
        todayTotals = [:]
        todayActive = 0
        buffer = []
        current = nil
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        let pending = buffer
        buffer = []
        do {
            try store.appendTracking(pending)
        } catch {
            // Devolve ao buffer: melhor tentar de novo do que perder o dia.
            buffer.insert(contentsOf: pending, at: 0)
        }
    }

    /// Recompõe os totais de hoje a partir do disco, para que reiniciar o
    /// app não zere o que já foi medido.
    private func loadToday() {
        let startOfDay = clock.calendar.startOfDay(for: clock.now)
        guard let events = try? store.trackingEvents(from: startOfDay, to: clock.now)
        else { return }

        var totals: [String: TimeInterval] = [:]
        var active: TimeInterval = 0
        for event in events where event.kind == .foreground {
            totals[event.bundleID, default: 0] += event.duration
            active += event.duration
        }
        todayTotals = totals
        todayActive = active
    }

    // MARK: - Consulta ao vivo

    /// Total de hoje já incluindo a sessão que ainda está aberta, para o
    /// número no popover subir enquanto você olha.
    public func timeToday(bundleID: String) -> TimeInterval {
        var total = todayTotals[bundleID] ?? 0
        if let session = current, session.bundleID == bundleID, session.kind == .foreground {
            total += clock.now.timeIntervalSince(session.start)
        }
        return total
    }

    public var activeToday: TimeInterval {
        var total = todayActive
        if let session = current, session.kind == .foreground {
            total += clock.now.timeIntervalSince(session.start)
        }
        return total
    }

    public var focusedBundleID: String? {
        current?.kind == .foreground ? current?.bundleID : nil
    }
}
