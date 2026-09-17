import Foundation
import WakeUpeerDomain

/// Persistência em arquivos, sem dependência de framework da Apple.
///
/// Layout, dentro do diretório-raiz recebido no init:
/// ```
/// config.json              escrita atômica
/// fire-log.json            escrita atômica
/// tracking/2026-09.jsonl   append-only, um arquivo por mês
/// cache/                   snapshots de feriados
/// ```
/// O diretório vem de fora justamente para o dia do Linux: lá seria
/// `~/.config/wakeupeer` em vez de `~/Library/Application Support/WakeUpeer`.
public final class FileStateStore: StateStore, @unchecked Sendable {

    public enum StoreError: Error, CustomStringConvertible {
        case cannotCreateDirectory(String)
        case unreadableConfig(String)

        public var description: String {
            switch self {
            case .cannotCreateDirectory(let path): "Não foi possível criar o diretório: \(path)"
            case .unreadableConfig(let detail): "config.json ilegível: \(detail)"
            }
        }
    }

    private let root: URL
    private let fileManager: FileManager
    /// Serializa as escritas; o tracking vem de uma thread, a UI de outra.
    private let queue = DispatchQueue(label: "com.guilherme.WakeUpeer.store")

    private var configURL: URL { root.appendingPathComponent("config.json") }
    private var fireLogURL: URL { root.appendingPathComponent("fire-log.json") }
    private var trackingDirectory: URL { root.appendingPathComponent("tracking", isDirectory: true) }
    public var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try createDirectories()
    }

    private func createDirectories() throws {
        for directory in [root, trackingDirectory, cacheDirectory] {
            guard !fileManager.fileExists(atPath: directory.path) else { continue }
            do {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                throw StoreError.cannotCreateDirectory(directory.path)
            }
        }
    }

    // MARK: - Codificadores

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Compacto para o JSONL: uma linha por evento, sem espaços supérfluos.
    private static func makeLineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Config

    /// Avisos da última leitura: perfis descartados, formato futuro, etc.
    public private(set) var lastLoadWarnings: [String] = []

    /// Cria a configuração padrão no primeiro lançamento em vez de falhar.
    public func loadConfig() throws -> AppConfig {
        try queue.sync {
            guard fileManager.fileExists(atPath: configURL.path) else {
                let fresh = DefaultProfiles.makeConfig()
                try writeConfig(fresh)
                return fresh
            }

            let data = try Data(contentsOf: configURL)
            do {
                let result = try ConfigMigration.decode(data, decoder: Self.makeDecoder())
                lastLoadWarnings = result.warnings

                // Uma migração reescreve o arquivo, mas só depois de guardar
                // o original — se a conversão estiver errada, os dados ainda
                // estão lá para recuperar à mão.
                if case .migrated(let from) = result.outcome {
                    try? backupConfig(data, suffix: "v\(from)")
                    try writeConfig(result.config)
                }
                return result.config
            } catch {
                throw StoreError.unreadableConfig(String(describing: error))
            }
        }
    }

    private func backupConfig(_ data: Data, suffix: String) throws {
        let url = root.appendingPathComponent("config.backup-\(suffix).json")
        try data.write(to: url, options: .atomic)
    }

    public func saveConfig(_ config: AppConfig) throws {
        try queue.sync { try writeConfig(config) }
    }

    private func writeConfig(_ config: AppConfig) throws {
        let data = try Self.makeEncoder().encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - Registro de disparos

    public func loadFireLog() throws -> FireLog {
        try queue.sync {
            guard fileManager.fileExists(atPath: fireLogURL.path) else { return FireLog() }
            let data = try Data(contentsOf: fireLogURL)
            // Um fire-log corrompido não vale travar o app: perde-se o dedupe do dia.
            return (try? Self.makeDecoder().decode(FireLog.self, from: data)) ?? FireLog()
        }
    }

    public func saveFireLog(_ log: FireLog) throws {
        try queue.sync {
            let data = try Self.makeEncoder().encode(log)
            try data.write(to: fireLogURL, options: .atomic)
        }
    }

    // MARK: - Tracking

    private func trackingFileURL(for date: Date, calendar: Calendar) -> URL {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let mm = month < 10 ? "0\(month)" : "\(month)"
        return trackingDirectory.appendingPathComponent("\(year)-\(mm).jsonl")
    }

    public func appendTracking(_ events: [TrackingEvent]) throws {
        guard !events.isEmpty else { return }
        try queue.sync {
            let calendar = Calendar(identifier: .gregorian)
            let encoder = Self.makeLineEncoder()

            // Um mesmo lote pode atravessar a virada do mês.
            let grouped = Dictionary(grouping: events) {
                trackingFileURL(for: $0.start, calendar: calendar)
            }

            for (url, group) in grouped {
                var payload = Data()
                for event in group {
                    payload.append(try encoder.encode(event))
                    payload.append(0x0A)  // \n
                }
                try append(payload, to: url)
            }
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func trackingEvents(from: Date, to: Date) throws -> [TrackingEvent] {
        queue.sync {
            let calendar = Calendar(identifier: .gregorian)
            let decoder = Self.makeDecoder()

            // Varre os arquivos mensais que intersectam o intervalo.
            var urls: [URL] = []
            var cursor = from
            while cursor <= to {
                let url = trackingFileURL(for: cursor, calendar: calendar)
                if !urls.contains(url) { urls.append(url) }
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
            let endURL = trackingFileURL(for: to, calendar: calendar)
            if !urls.contains(endURL) { urls.append(endURL) }

            var events: [TrackingEvent] = []
            for url in urls where fileManager.fileExists(atPath: url.path) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = line.data(using: .utf8),
                          let event = try? decoder.decode(TrackingEvent.self, from: data)
                    else {
                        // Última linha truncada por queda de energia: pula e segue.
                        continue
                    }
                    guard event.end >= from, event.start <= to else { continue }
                    events.append(event)
                }
            }
            return events.sorted { $0.start < $1.start }
        }
    }

    public func purgeTracking(olderThan date: Date) throws {
        try queue.sync {
            let calendar = Calendar(identifier: .gregorian)
            let cutoffFile = trackingFileURL(for: date, calendar: calendar).lastPathComponent

            let contents = try fileManager.contentsOfDirectory(
                at: trackingDirectory, includingPropertiesForKeys: nil)
            for url in contents where url.pathExtension == "jsonl" {
                // Os nomes são "AAAA-MM.jsonl", então a ordem lexicográfica é cronológica.
                if url.lastPathComponent < cutoffFile {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }
}

// MARK: - Local padrão no macOS

extension FileStateStore {
    /// `~/Library/Application Support/WakeUpeer` no macOS.
    /// No Linux isto viraria `~/.config/wakeupeer`.
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("WakeUpeer", isDirectory: true)
    }
}
