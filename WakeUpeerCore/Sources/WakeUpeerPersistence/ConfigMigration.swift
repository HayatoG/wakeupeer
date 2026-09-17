import Foundation
import WakeUpeerDomain

/// Leitura tolerante do `config.json`.
///
/// O arquivo é editável à mão, então precisa sobreviver a uma chave que
/// ainda não existia, a um campo removido e a uma versão futura vinda de
/// outra máquina. A alternativa — recusar e voltar ao padrão — apagaria
/// perfis que o usuário levou tempo montando.
public enum ConfigMigration {

    public enum Outcome: Sendable, Equatable {
        case current
        case migrated(from: Int)
        /// Gravado por uma versão mais nova do app; carregamos o que dá.
        case fromFuture(version: Int)
    }

    public struct Result: Sendable {
        public var config: AppConfig
        public var outcome: Outcome
        /// Mensagens para mostrar ao usuário quando algo teve de ser assumido.
        public var warnings: [String]
    }

    /// Decodifica aplicando as migrações necessárias.
    public static func decode(_ data: Data, decoder: JSONDecoder) throws -> Result {
        let version = try detectVersion(data, decoder: decoder)
        var warnings: [String] = []

        // Um arquivo de versão futura pode ter chaves que não entendemos.
        // Decodificar mesmo assim preserva o que é compatível, em vez de
        // descartar a configuração inteira.
        if version > AppConfig.currentSchemaVersion {
            let config = try decodeTolerantly(data, decoder: decoder, warnings: &warnings)
            warnings.append(
                "A configuração foi criada por uma versão mais recente do WakeUpeer (formato \(version)). Campos desconhecidos foram mantidos como estão."
            )
            return Result(
                config: config, outcome: .fromFuture(version: version), warnings: warnings)
        }

        let config = try decodeTolerantly(data, decoder: decoder, warnings: &warnings)

        guard version < AppConfig.currentSchemaVersion else {
            return Result(config: config, outcome: .current, warnings: warnings)
        }

        var migrated = config
        migrated.schemaVersion = AppConfig.currentSchemaVersion
        // Não há migrações entre versões ainda; quando houver, elas entram
        // aqui em cadeia, cada uma elevando uma versão por vez.
        return Result(
            config: migrated, outcome: .migrated(from: version), warnings: warnings)
    }

    private static func detectVersion(_ data: Data, decoder: JSONDecoder) throws -> Int {
        struct VersionProbe: Decodable { var schemaVersion: Int? }
        let probe = try? decoder.decode(VersionProbe.self, from: data)
        // Um arquivo sem a chave veio de antes dela existir: trate como 1.
        return probe?.schemaVersion ?? 1
    }

    /// Decodifica e, se falhar, tenta salvar o que for aproveitável em vez
    /// de perder tudo por causa de um perfil malformado.
    private static func decodeTolerantly(
        _ data: Data, decoder: JSONDecoder, warnings: inout [String]
    ) throws -> AppConfig {
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            // Segunda tentativa: decodifica perfil a perfil, descartando só
            // os quebrados. Um erro de digitação num perfil não deve levar
            // os outros junto.
            guard let salvaged = salvageProfiles(data, decoder: decoder, warnings: &warnings)
            else { throw error }
            return salvaged
        }
    }

    private static func salvageProfiles(
        _ data: Data, decoder: JSONDecoder, warnings: inout [String]
    ) -> AppConfig? {
        struct Loose: Decodable {
            var schemaVersion: Int?
            var profiles: [FailableProfile]?
            var wakeThresholdHours: Double?
            var holidayCalendarIDs: [String]?
            var launchDelayMilliseconds: Int?
            var launchAtLogin: Bool?
        }

        /// Envelope que transforma um perfil indecodificável em `nil` em vez
        /// de derrubar o array inteiro.
        struct FailableProfile: Decodable {
            var value: Profile?
            init(from decoder: any Decoder) throws {
                value = try? Profile(from: decoder)
            }
        }

        guard let loose = try? decoder.decode(Loose.self, from: data) else { return nil }

        let all = loose.profiles ?? []
        let recovered = all.compactMap(\.value)
        let lost = all.count - recovered.count
        if lost > 0 {
            warnings.append(
                "\(lost) \(lost == 1 ? "perfil não pôde ser lido e foi ignorado" : "perfis não puderam ser lidos e foram ignorados"). Verifique o config.json."
            )
        }

        var config = AppConfig()
        config.profiles = recovered
        if let value = loose.wakeThresholdHours { config.wakeThresholdHours = value }
        if let value = loose.holidayCalendarIDs { config.holidayCalendarIDs = value }
        if let value = loose.launchDelayMilliseconds { config.launchDelayMilliseconds = value }
        if let value = loose.launchAtLogin { config.launchAtLogin = value }
        return config
    }
}
