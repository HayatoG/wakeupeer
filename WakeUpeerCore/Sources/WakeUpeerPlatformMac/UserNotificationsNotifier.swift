import Foundation
import UserNotifications
import WakeUpeerDomain

/// Notificações do sistema com botões de ação.
///
/// Exige bundle assinado: rodando por `swift run` a autorização é negada
/// com "Notifications are not allowed for this application". Por isso o
/// popover sempre espelha o prompt — se a notificação não aparecer, a
/// pergunta continua acessível.
public final class UserNotificationsNotifier: NSObject, Notifier, @unchecked Sendable {

    private enum ActionID {
        static let confirm = "wakeupeer.confirm"
        static let decline = "wakeupeer.decline"
        static let category = "wakeupeer.prompt"
        static let reportCategory = "wakeupeer.report"
    }

    /// Para onde as respostas voltam. O app registra o seu AppState aqui.
    public weak var answerSink: (any AnswerSink)?
    /// Chamado quando o usuário toca no resumo semanal.
    public var onOpenReport: (@Sendable () -> Void)?

    private let center = UNUserNotificationCenter.current()

    public override init() {
        super.init()
        // O delegate precisa estar pronto antes do app terminar de iniciar,
        // ou as respostas às ações não chegam.
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let confirm = UNNotificationAction(
            identifier: ActionID.confirm, title: "Abrir agora", options: [.foreground])
        let decline = UNNotificationAction(
            identifier: ActionID.decline, title: "Agora não", options: [])

        let prompt = UNNotificationCategory(
            identifier: ActionID.category,
            actions: [confirm, decline],
            intentIdentifiers: [],
            options: [])

        let report = UNNotificationCategory(
            identifier: ActionID.reportCategory,
            actions: [],
            intentIdentifiers: [],
            options: [])

        center.setNotificationCategories([prompt, report])
    }

    // MARK: - Notifier

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public func present(_ prompt: Prompt) async {
        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = prompt.body
        content.categoryIdentifier = ActionID.category
        content.sound = .default
        // Fura o modo de Foco: a pergunta perde o sentido se chegar à noite.
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            "profileID": prompt.profileID.uuidString,
            "windowDay": prompt.windowDay,
        ]

        // Os rótulos do feriado são diferentes; como as ações da categoria são
        // fixas, o texto do corpo já deixa a pergunta explícita.
        let request = UNNotificationRequest(
            identifier: identifier(profileID: prompt.profileID, windowDay: prompt.windowDay),
            content: content,
            trigger: nil)

        try? await center.add(request)
    }

    public func postInfo(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        try? await center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public func postWeeklyReport(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = ActionID.reportCategory
        content.sound = .default
        content.userInfo = ["openReport": true]

        try? await center.add(
            UNNotificationRequest(
                identifier: "wakeupeer.weekly.\(UUID().uuidString)",
                content: content, trigger: nil))
    }

    public func withdrawPrompt(profileID: UUID, windowDay: String) async {
        let id = identifier(profileID: profileID, windowDay: windowDay)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func identifier(profileID: UUID, windowDay: String) -> String {
        "wakeupeer.prompt.\(profileID.uuidString).\(windowDay)"
    }
}

// MARK: - Delegate

extension UserNotificationsNotifier: UNUserNotificationCenterDelegate {

    /// Sem isto a notificação não aparece quando o app está em primeiro plano.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo

        if info["openReport"] as? Bool == true {
            onOpenReport?()
            return
        }

        guard let idString = info["profileID"] as? String,
              let profileID = UUID(uuidString: idString),
              let windowDay = info["windowDay"] as? String
        else { return }

        let answer: PromptAnswer =
            switch response.actionIdentifier {
            case ActionID.confirm, UNNotificationDefaultActionIdentifier: .confirmed
            case ActionID.decline: .declined
            // Descartar não é recusar: a pergunta continua no popover.
            default: .ignored
            }

        await answerSink?.receive(answer: answer, profileID: profileID, windowDay: windowDay)
    }
}
