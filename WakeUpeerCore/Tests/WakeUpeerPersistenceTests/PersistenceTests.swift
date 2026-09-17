import Foundation
import Testing
import WakeUpeerDomain

@testable import WakeUpeerPersistence

private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wakeupeer-tests-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - Migração

@Suite("Migração de configuração")
struct ConfigMigrationTests {

    @Test("Arquivo na versão atual passa sem alteração")
    func currentVersionIsUntouched() throws {
        let config = DefaultProfiles.makeConfig()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let result = try ConfigMigration.decode(data, decoder: makeDecoder())
        #expect(result.outcome == .current)
        #expect(result.config.profiles.count == config.profiles.count)
        #expect(result.warnings.isEmpty)
    }

    @Test("Arquivo sem schemaVersion é tratado como versão 1")
    func missingVersionDefaultsToOne() throws {
        let json = """
        {
          "profiles": [],
          "wakeThresholdHours": 4,
          "holidayCalendarIDs": [],
          "holidayBehavior": "ask",
          "tracking": {
            "isEnabled": true, "sampleIntervalSeconds": 15,
            "idleThresholdSeconds": 180, "excludedBundleIDs": [], "retentionDays": 180
          },
          "launchAtLogin": false,
          "launchDelayMilliseconds": 600,
          "weeklyReportEnabled": true,
          "weeklyReportWeekday": 6,
          "weeklyReportHour": 17
        }
        """

        let result = try ConfigMigration.decode(
            Data(json.utf8), decoder: makeDecoder())
        // A versão atual também é 1, então nada a migrar — mas não deve falhar.
        #expect(result.config.schemaVersion == 1)
    }

    @Test("Arquivo de versão futura é carregado com aviso, não descartado")
    func futureVersionIsSalvaged() throws {
        var config = DefaultProfiles.makeConfig()
        config.schemaVersion = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let result = try ConfigMigration.decode(data, decoder: makeDecoder())
        #expect(result.outcome == .fromFuture(version: 99))
        #expect(result.config.profiles.count == config.profiles.count, "os perfis sobrevivem")
        #expect(!result.warnings.isEmpty, "o usuário precisa saber")
    }

    @Test("Um perfil quebrado não leva os outros junto")
    func salvagesGoodProfiles() throws {
        // O segundo perfil tem weekdays com tipo errado.
        let json = """
        {
          "schemaVersion": 1,
          "profiles": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Bom", "isEnabled": true, "weekdays": [2, 3],
              "window": {"startMinutes": 480, "endMinutes": 1020},
              "greeting": {"style": "automatic"}, "items": [],
              "skipOnHoliday": false, "priority": 0, "graceMinutes": 0,
              "dedupeScope": "oncePerDay", "symbolName": "sun.max"
            },
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "Quebrado", "isEnabled": true, "weekdays": "segunda",
              "window": {"startMinutes": 480, "endMinutes": 1020},
              "greeting": {"style": "automatic"}, "items": [],
              "skipOnHoliday": false, "priority": 0, "graceMinutes": 0,
              "dedupeScope": "oncePerDay", "symbolName": "sun.max"
            }
          ],
          "wakeThresholdHours": 6
        }
        """

        let result = try ConfigMigration.decode(Data(json.utf8), decoder: makeDecoder())
        #expect(result.config.profiles.count == 1, "o perfil válido é preservado")
        #expect(result.config.profiles.first?.name == "Bom")
        #expect(result.config.wakeThresholdHours == 6, "os outros campos também")
        #expect(!result.warnings.isEmpty, "a perda precisa ser reportada")
    }

    @Test("JSON irrecuperável lança erro em vez de devolver lixo")
    func unrecoverableThrows() {
        let data = Data("isto não é json".utf8)
        #expect(throws: (any Error).self) {
            try ConfigMigration.decode(data, decoder: makeDecoder())
        }
    }
}

// MARK: - Store

@Suite("Persistência em arquivos")
struct FileStateStoreTests {

    @Test("O primeiro lançamento cria a configuração padrão")
    func createsDefaultOnFirstLaunch() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        let config = try store.loadConfig()

        #expect(config.profiles.count == 4, "os quatro perfis de fábrica")
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("config.json").path))
    }

    @Test("Ida e volta da configuração preserva tudo")
    func configRoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        var config = try store.loadConfig()
        config.wakeThresholdHours = 7.5
        config.profiles[0].name = "Renomeado"
        config.profiles[0].graceMinutes = 45
        try store.saveConfig(config)

        let reloaded = try FileStateStore(root: root).loadConfig()
        #expect(reloaded.wakeThresholdHours == 7.5)
        #expect(reloaded.profiles[0].name == "Renomeado")
        #expect(reloaded.profiles[0].graceMinutes == 45)
    }

    @Test("Eventos de uso sobrevivem à ida e volta")
    func trackingRoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        let start = Date()
        let events = (0..<5).map { index in
            TrackingEvent(
                start: start.addingTimeInterval(Double(index) * 600),
                end: start.addingTimeInterval(Double(index) * 600 + 300),
                bundleID: "com.example.app\(index)",
                appName: "App \(index)")
        }
        try store.appendTracking(events)

        let loaded = try store.trackingEvents(
            from: start.addingTimeInterval(-60), to: start.addingTimeInterval(4000))
        #expect(loaded.count == 5)
        #expect(loaded.first?.bundleID == "com.example.app0")
    }

    @Test("Append acumula em vez de sobrescrever")
    func appendAccumulates() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        let start = Date()

        for index in 0..<3 {
            try store.appendTracking([
                TrackingEvent(
                    start: start.addingTimeInterval(Double(index) * 100),
                    end: start.addingTimeInterval(Double(index) * 100 + 50),
                    bundleID: "com.example.app", appName: "App")
            ])
        }

        let loaded = try store.trackingEvents(
            from: start.addingTimeInterval(-10), to: start.addingTimeInterval(1000))
        #expect(loaded.count == 3)
    }

    /// Uma queda de energia deixa a última linha pela metade. Perder essa
    /// linha é aceitável; perder o arquivo inteiro não é.
    @Test("Última linha truncada não derruba o arquivo")
    func truncatedLastLineIsSkipped() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        let start = Date()
        try store.appendTracking([
            TrackingEvent(
                start: start, end: start.addingTimeInterval(60),
                bundleID: "com.example.good", appName: "Bom")
        ])

        // Simula a escrita interrompida no meio de um objeto JSON.
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month], from: start)
        let mm = (parts.month ?? 1) < 10 ? "0\(parts.month ?? 1)" : "\(parts.month ?? 1)"
        let file = root.appendingPathComponent("tracking/\(parts.year ?? 0)-\(mm).jsonl")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"start":"2026-09-17T10:00:00Z","bund"#.utf8))
        try handle.close()

        let loaded = try store.trackingEvents(
            from: start.addingTimeInterval(-60), to: start.addingTimeInterval(600))
        #expect(loaded.count == 1, "o evento íntegro continua legível")
        #expect(loaded.first?.bundleID == "com.example.good")
    }

    @Test("Um fire-log corrompido vira um log vazio em vez de travar o app")
    func corruptedFireLogDegradesGracefully() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        try Data("{{{ não é json".utf8).write(
            to: root.appendingPathComponent("fire-log.json"))

        let log = try store.loadFireLog()
        #expect(log.records.isEmpty)
        #expect(log.pending.isEmpty)
    }

    @Test("A purga remove só os meses anteriores ao corte")
    func purgeRemovesOldMonths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileStateStore(root: root)
        let tracking = root.appendingPathComponent("tracking")
        for name in ["2025-01.jsonl", "2025-06.jsonl", "2026-09.jsonl"] {
            try Data("{}\n".utf8).write(to: tracking.appendingPathComponent(name))
        }

        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        let cutoff = Calendar(identifier: .gregorian).date(from: components)!
        try store.purgeTracking(olderThan: cutoff)

        let remaining = try FileManager.default.contentsOfDirectory(
            atPath: tracking.path
        ).sorted()
        #expect(remaining == ["2026-09.jsonl"], "os arquivos de 2025 saem, o de 2026 fica")
    }

    @Test("Migrar guarda uma cópia do arquivo original")
    func migrationKeepsBackup() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Escreve um config declarando uma versão anterior à atual.
        var config = DefaultProfiles.makeConfig()
        config.schemaVersion = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: root.appendingPathComponent("config.json"))

        let store = try FileStateStore(root: root)
        _ = try store.loadConfig()

        let backup = root.appendingPathComponent("config.backup-v0.json")
        #expect(
            FileManager.default.fileExists(atPath: backup.path),
            "o original precisa continuar recuperável")
    }
}
