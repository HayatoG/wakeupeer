import AppKit
import Foundation
import ServiceManagement
import WakeUpeerDomain

/// Registro de início automático via SMAppService.
///
/// `SMLoginItemSetEnabled` e o LSSharedFileList legado não são usados:
/// estão obsoletos e falham silenciosamente nas versões recentes do macOS.
public struct SMAppServiceLoginItem: LoginItemManager {

    public init() {}

    public func status() async -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            // O usuário desativou em Ajustes do Sistema; só ele pode reverter.
            return .requiresApproval
        case .notFound:
            return .unavailable(reason: "O app não foi encontrado pelo sistema.")
        @unknown default:
            return .unavailable(reason: "Estado desconhecido.")
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }

    @MainActor
    public func openSystemSettings() async {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// O registro só funciona se o app estiver num local estável. Rodando a
    /// partir do DerivedData ou de ~/Downloads, `register()` falha ou o
    /// vínculo quebra assim que o binário se move.
    public static var isInStableLocation: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications")
    }
}
