import AppKit
import Foundation
import WakeUpeerDomain

/// Observa login, sono e despertar da máquina.
///
/// A duração do sono é medida com relógio monotônico, porque `Date` salta
/// quando o sistema sincroniza a hora e inventa sonos que não houve.
@MainActor
public final class WorkspaceEventSource: SystemEventSource {

    private var continuation: AsyncStream<SystemEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []

    /// Marca o início do sono no relógio monotônico.
    private var sleepMark: ContinuousClock.Instant?
    private let continuousClock = ContinuousClock()

    public init() {}

    nonisolated public func events() -> AsyncStream<SystemEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                self.continuation = continuation
                self.attach()
                continuation.yield(.didLogin)
            }
            continuation.onTermination = { _ in
                Task { @MainActor in self.detach() }
            }
        }
    }

    private func attach() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.sleepMark = ContinuousClock().now
                    self?.continuation?.yield(.willSleep)
                }
            })

        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let slept: TimeInterval
                    if let mark = self.sleepMark {
                        let elapsed = mark.duration(to: self.continuousClock.now)
                        slept = Double(elapsed.components.seconds)
                    } else {
                        // Sem marca (sono abrupto, app iniciado durante o sono):
                        // zero faz o resolver tratar como wake curto, o que é
                        // o lado seguro — não abre nada sem confirmação.
                        slept = 0
                    }
                    self.sleepMark = nil
                    self.continuation?.yield(.didWake(sleptFor: slept))
                }
            })

        observers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.continuation?.yield(.screenUnlocked) }
            })

        let distributed = DistributedNotificationCenter.default()
        observers.append(
            distributed.addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.continuation?.yield(.screenLocked) }
            })
    }

    private func detach() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers = []
        continuation = nil
    }
}
