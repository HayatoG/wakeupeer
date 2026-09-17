import AppKit
import Foundation
import WakeUpeerDomain

/// Abre apps, URLs, arquivos e comandos via NSWorkspace.
public struct NSWorkspaceAppLauncher: AppLauncher {

    public init() {}

    // MARK: - Lançamento

    public func launch(_ profileItem: ProfileItem) async -> LaunchOutcome {
        switch profileItem.item {
        case .application(let bundleID, _, let path):
            return await launchApplication(
                bundleID: bundleID, path: path, profileItem: profileItem)
        case .url(let url):
            return await open(url: url, profileItem: profileItem)
        case .file(let path):
            return await open(url: URL(fileURLWithPath: path), profileItem: profileItem)
        case .shell(let command, let args):
            return runProcess(command: command, args: args)
        }
    }

    private func launchApplication(
        bundleID: String,
        path: String?,
        profileItem: ProfileItem
    ) async -> LaunchOutcome {
        let workspace = NSWorkspace.shared

        // Já aberto: no máximo trazer para frente. Relançar reabriria janelas
        // e, em apps como o Slack, chega a atrapalhar.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if let existing = running.first {
            if profileItem.bringToFront {
                existing.activate(options: [])
                return .activated
            }
            return .alreadyRunning
        }

        let appURL: URL? = if let path, FileManager.default.fileExists(atPath: path) {
            URL(fileURLWithPath: path)
        } else {
            workspace.urlForApplication(withBundleIdentifier: bundleID)
        }

        guard let appURL else {
            return .failed(reason: "App não encontrado (\(bundleID)). Foi desinstalado?")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = profileItem.bringToFront
        configuration.addsToRecentItems = false
        configuration.hides = profileItem.launchHidden

        do {
            _ = try await workspace.openApplication(at: appURL, configuration: configuration)
            return .launched
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func open(url: URL, profileItem: ProfileItem) async -> LaunchOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = profileItem.bringToFront
        configuration.addsToRecentItems = false

        do {
            _ = try await NSWorkspace.shared.open(
                url, configuration: configuration)
            return .launched
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Executável e argumentos separados — nunca uma string entregue a um shell.
    private func runProcess(command: String, args: [String]) -> LaunchOutcome {
        let executable = URL(fileURLWithPath: command)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failed(reason: "Não é um executável: \(command)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return .launched
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    // MARK: - Consulta

    public func runningApps() async -> [RunningApp] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    guard let bundleID = app.bundleIdentifier else { return nil }
                    return RunningApp(
                        bundleID: bundleID,
                        name: app.localizedName ?? bundleID,
                        isActive: app.isActive,
                        launchDate: app.launchDate
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public func isRunning(bundleID: String) async -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Ícone do app, para a UI. Fora do protocolo por ser específico do macOS.
    @MainActor
    public static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Sequenciamento

/// Abre os itens de um perfil em sequência, com uma pausa entre eles.
///
/// Lançar tudo de uma vez trava o Dock e faz apps pesados (Slack, Teams)
/// falharem em cold boot, então o padrão é sequencial.
public struct ProfileLauncher: Sendable {
    private let launcher: any AppLauncher
    private let delayMilliseconds: Int

    public init(launcher: any AppLauncher, delayMilliseconds: Int = 600) {
        self.launcher = launcher
        self.delayMilliseconds = delayMilliseconds
    }

    public func launch(profile: Profile, at date: Date = Date()) async -> LaunchReport {
        var results: [LaunchResult] = []
        let items = profile.enabledItems

        for (index, item) in items.enumerated() {
            let outcome = await launcher.launch(item)
            results.append(
                LaunchResult(
                    itemID: item.id.uuidString,
                    displayName: item.item.displayName,
                    outcome: outcome
                ))

            // Sem pausa depois do último.
            if index < items.count - 1, delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
        }

        return LaunchReport(
            profileID: profile.id,
            profileName: profile.name,
            startedAt: date,
            results: results
        )
    }
}
