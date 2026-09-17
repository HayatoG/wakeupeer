import Foundation

/// Observa um arquivo e avisa quando ele muda fora do app.
///
/// Serve para o `config.json` editado à mão continuar valendo sem
/// reiniciar. Editores costumam salvar substituindo o arquivo em vez de
/// reescrevê-lo, então o observador precisa se reatar quando o inode
/// original desaparece — senão passa a vigiar um arquivo que já não existe.
public final class FileWatcher: @unchecked Sendable {

    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pendingWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.guilherme.WakeUpeer.filewatcher")

    /// Ignora as mudanças que o próprio app acabou de fazer.
    private var muteUntil: Date = .distantPast

    public init(
        url: URL,
        debounce: TimeInterval = 0.4,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    public func start() {
        queue.async { [weak self] in self?.attach() }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.pendingWork?.cancel()
            self?.source?.cancel()
            self?.source = nil
        }
    }

    /// Silencia o observador por um instante, para uma gravação feita pelo
    /// próprio app não voltar como "alguém editou o arquivo".
    public func mute(for interval: TimeInterval = 1.0) {
        queue.async { [weak self] in
            self?.muteUntil = Date().addingTimeInterval(interval)
        }
    }

    private func attach() {
        source?.cancel()
        source = nil

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // O arquivo pode ainda não existir; tenta de novo em instantes.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attach() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data

            // Renomear ou apagar significa que este descritor ficou órfão:
            // é preciso reabrir o caminho para seguir observando.
            if flags.contains(.rename) || flags.contains(.delete) {
                self.scheduleNotification()
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.attach()
                }
                return
            }

            self.scheduleNotification()
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }

        source.resume()
        self.source = source
    }

    /// Um salvamento gera vários eventos; o debounce recolhe a rajada.
    private func scheduleNotification() {
        pendingWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, Date() >= self.muteUntil else { return }
            self.onChange()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
