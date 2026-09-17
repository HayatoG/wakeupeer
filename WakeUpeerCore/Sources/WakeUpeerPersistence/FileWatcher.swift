import Foundation

#if canImport(Darwin)
    import Darwin
#endif

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

    #if canImport(Darwin)
        private var source: DispatchSourceFileSystemObject?
        private var descriptor: CInt = -1
    #endif
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
        #if canImport(Darwin)
            source?.cancel()
        #endif
    }

    public func start() {
        #if canImport(Darwin)
            queue.async { [weak self] in self?.attach() }
        #else
            // `O_EVTONLY` e o observador de sistema de arquivos do Dispatch
            // são específicos do Darwin. Em outras plataformas, comparar a
            // data de modificação de tempos em tempos resolve: o arquivo é
            // pequeno e muda raramente.
            queue.async { [weak self] in self?.pollForChanges() }
        #endif
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWork?.cancel()
            #if canImport(Darwin)
                self.source?.cancel()
                self.source = nil
            #else
                self.isPolling = false
            #endif
        }
    }

    /// Silencia o observador por um instante, para uma gravação feita pelo
    /// próprio app não voltar como "alguém editou o arquivo".
    public func mute(for interval: TimeInterval = 1.0) {
        queue.async { [weak self] in
            self?.muteUntil = Date().addingTimeInterval(interval)
        }
    }

    #if !canImport(Darwin)
        private var isPolling = false
        private var lastModified: Date?

        private func pollForChanges() {
            guard !isPolling else { return }
            isPolling = true
            schedulePoll()
        }

        private func schedulePoll() {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isPolling else { return }
                let attributes = try? FileManager.default.attributesOfItem(atPath: self.url.path)
                let modified = attributes?[.modificationDate] as? Date

                if let modified, let last = self.lastModified, modified > last,
                   Date() >= self.muteUntil
                {
                    self.onChange()
                }
                if modified != nil { self.lastModified = modified }
                self.schedulePoll()
            }
        }
    #endif

    #if canImport(Darwin)
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

    #endif  // canImport(Darwin)

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
