# Portar o WakeUpeer para Linux e Windows

O domínio foi escrito para isto: toda a lógica — qual perfil dispara, quando é feriado, como agregar o relatório — vive em `WakeUpeerDomain`, que importa apenas `Foundation`. Portar é implementar oito protocolos e escrever uma interface.

Este guia diz exatamente o que implementar, com qual API de cada plataforma, e onde estão as armadilhas.

---

## Sumário

- [Swift fora da Apple](#swift-fora-da-apple)
- [O que já está pronto](#o-que-já-está-pronto)
- [O que precisa ser escrito](#o-que-precisa-ser-escrito)
- [Estrutura do novo alvo](#estrutura-do-novo-alvo)
- [As oito portas](#as-oito-portas)
- [Ajustes necessários no código existente](#ajustes-necessários-no-código-existente)
- [Linux](#linux)
- [Windows](#windows)
- [Ordem de implementação](#ordem-de-implementação)
- [Como verificar](#como-verificar)
- [Armadilhas](#armadilhas)

---

## Swift fora da Apple

Vale começar por aqui, porque a dúvida costuma ser se isto é viável, não como fazer.

Linux e Windows são plataformas **oficiais** do Swift, no mesmo nível: *Deployment and Development* — o compilador roda nelas e programas podem ser construídos para elas. Mudanças no compilador precisam passar nos testes dessas plataformas antes de serem integradas, então não é suporte de fachada.

| | Linux | Windows |
|---|---|---|
| Versão atual | 6.4 | 6.4 |
| Oficial desde | 2016 | 2020 |
| Mínimo | Ubuntu 22.04 · Debian 12 · Fedora 41 · RHEL/UBI 9 · Amazon Linux 2023 | Windows 10 |
| Foundation, Dispatch, testes | Sim | Sim |
| Estabilidade de ABI | Não | Não |

A ausência de estabilidade de ABI significa que binários precisam ser distribuídos com as bibliotecas do runtime, em vez de contar com o que o sistema tem. Para uso pessoal, é detalhe de empacotamento.

Em janeiro de 2026 foi criado um [workgroup dedicado ao Windows](https://www.swift.org/blog/announcing-windows-workgroup/), com a tarefa explícita de aproximar Foundation e Dispatch dos idiomas da plataforma — sinal de que o suporte segue avançando em vez de estagnar.

### Instalar o compilador

**Linux** — pelo [swiftly](https://www.swift.org/install/linux/), o gerenciador oficial de toolchains:

```sh
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
swiftly install latest
```

Há também imagens Docker oficiais (`swift:6.4`), úteis para experimentar sem instalar nada.

**Windows** — pelo gerenciador de pacotes:

```powershell
winget install --id Swift.Toolchain
```

Antes disso é preciso o Visual Studio 2022 Community com as ferramentas C++ e o Windows 11 SDK: o Swift usa o linker e as bibliotecas da Microsoft, não traz os seus. VS Code com a extensão oficial do Swift dá autocompletar, depuração e execução de testes.

### O teste de trinta minutos

Antes de escrever qualquer código de plataforma, vale provar que a base funciona:

```sh
git clone https://github.com/HayatoG/wakeupeer.git
cd wakeupeer/WakeUpeerCore
swift test --filter 'WakeUpeer(Domain|Persistence)Tests'
```

Os 83 testes devem passar sem alteração nenhuma. Se passarem, toda a lógica difícil — virada da meia-noite, sobreposição de perfis, fusos horários, horário de verão, feriados, agregação do relatório — já está funcionando na plataforma nova. O que resta é ligação com o sistema e interface.

Se não passarem, o problema está na base e é isso que se corrige primeiro. Veja [como verificar](#como-verificar) para as causas prováveis.

---

## O que já está pronto

Estes dois alvos compilam hoje em Linux e Windows, sem alteração:

| Alvo | Conteúdo |
|---|---|
| `WakeUpeerDomain` | Modelos, `ProfileResolver`, `ReportBuilder`, feriados brasileiros, as portas |
| `WakeUpeerPersistence` | `FileStateStore` (JSON + JSONL), migração de configuração, `FileWatcher` |

Junto vêm **83 testes** que valem em qualquer plataforma. Eles cobrem o que é difícil e não muda de sistema para sistema: virada da meia-noite, sobreposição de perfis, tolerância, quatro fusos horários, horário de verão, tabela de feriados, clipping do relatório, JSONL truncado.

O CI já roda esses testes em Linux (`.github/workflows/ci.yml`), então a base está verificada continuamente.

---

## O que precisa ser escrito

1. Um alvo `WakeUpeerPlatformLinux` ou `WakeUpeerPlatformWindows` implementando as oito portas.
2. Uma interface gráfica — bandeja do sistema, painel, preferências, relatório.
3. Um executável que monta as dependências, equivalente a `AppState.live()`.

A camada de UI é a parte cara. As portas são mecânicas; a interface é reescrita, porque SwiftUI não existe fora da Apple.

---

## Estrutura do novo alvo

Em `WakeUpeerCore/Package.swift`, acrescente o alvo condicionado à plataforma:

```swift
.target(
    name: "WakeUpeerPlatformLinux",
    dependencies: ["WakeUpeerDomain"]
),
```

E envolva os arquivos em `#if os(Linux)` — ou deixe o alvo fora das dependências do executável macOS, o que for mais limpo no seu caso. O importante é o domínio nunca depender da camada de plataforma; a seta aponta só para dentro.

```
WakeUpeerCore/Sources/
├── WakeUpeerDomain/           ← ninguém aqui importa plataforma
├── WakeUpeerPersistence/
├── WakeUpeerPlatformMac/
├── WakeUpeerPlatformLinux/    ← novo
└── WakeUpeerPlatformWindows/  ← novo
```

---

## As oito portas

Assinaturas completas em [`Ports.swift`](../WakeUpeerCore/Sources/WakeUpeerDomain/Ports.swift). Todas são `Sendable` e os métodos são `async`, o que evita problemas de isolamento no Swift 6.

### 1. `Clock`

```swift
var now: Date { get }
var calendar: Calendar { get }
```

O mais simples, e o único que pode ser copiado quase literal de [`SystemClock.swift`](../WakeUpeerCore/Sources/WakeUpeerPlatformMac/SystemClock.swift). Só garanta `firstWeekday = 2` — a semana começa na segunda no Brasil, e o relatório depende disso.

### 2. `AppLauncher`

```swift
func launch(_ item: ProfileItem) async -> LaunchOutcome
func runningApps() async -> [RunningApp]
func isRunning(bundleID: String) async -> Bool
```

O mais trabalhoso. Precisa abrir quatro tipos de item — aplicativo, endereço, arquivo e comando — e saber o que já está aberto.

**Regras de comportamento que o macOS já implementa e devem ser mantidas:**

- Um app já aberto **não é relançado**; no máximo é trazido para frente se o item pedir.
- Os itens abrem **em sequência, com pausa** (`config.launchDelayMilliseconds`, padrão 600 ms). Lançar tudo de uma vez trava o ambiente gráfico e faz apps pesados falharem em arranque frio.
- O caso `.shell` recebe **executável e argumentos separados**, nunca uma string para o shell. Isto é proposital: a configuração é um arquivo editável, e montar uma linha de comando a partir dela seria injeção na própria máquina.

### 3. `Notifier`

```swift
func requestAuthorization() async -> Bool
func present(_ prompt: Prompt) async
func postInfo(title: String, body: String) async
func postWeeklyReport(title: String, body: String) async
func withdrawPrompt(profileID: UUID, windowDay: String) async
```

O `Prompt` traz dois rótulos de ação. Se a plataforma não suportar botões na notificação, mostre a notificação simples — o painel já espelha a pergunta, então a decisão não se perde. Retornar `false` em `requestAuthorization` é aceitável e não quebra nada.

As respostas voltam pelo `AnswerSink`, que o app registra no notificador.

### 4. `HolidayProvider`

```swift
func lookup(day: Date) async -> HolidayLookup
```

**Já existe implementação portátil:** `BrazilianHolidayProvider` calcula os feriados nacionais sem tocar no sistema e funciona em qualquer plataforma. Use-a direto e só escreva um provider nativo se quiser ler o calendário do sistema — e então encadeie com `ChainedHolidayProvider`, mantendo a lista nacional como reserva.

Devolver `.unavailable` é seguro: o resolver trata como dia normal em vez de bloquear.

### 5. `StateStore`

**Já implementado e portátil.** `FileStateStore` recebe o diretório-raiz no construtor, justamente para cada plataforma passar o seu. Veja [ajustes necessários](#ajustes-necessários-no-código-existente).

### 6. `LoginItemManager`

```swift
func status() async -> LoginItemStatus
func setEnabled(_ enabled: Bool) async throws
func openSystemSettings() async
```

Registrar e remover o início automático. O estado `.requiresApproval` existe porque no macOS o usuário pode desativar por fora; se a plataforma não tiver esse conceito, nunca o retorne.

### 7. `ForegroundSampler`

```swift
func sample() async -> ForegroundSample?
```

Qual app está em primeiro plano e há quanto tempo o usuário está ocioso. Retornar `nil` desliga o rastreamento na prática, sem quebrar o resto.

### 8. `SystemEventSource`

```swift
func events() -> AsyncStream<SystemEvent>
```

Emite `.didLogin`, `.didWake(sleptFor:)`, `.willSleep`, `.screenLocked`, `.screenUnlocked`, `.willTerminate`.

**A duração do sono deve vir de relógio monotônico** (`ContinuousClock`), nunca da diferença entre dois `Date`. O relógio de parede salta quando o sistema sincroniza a hora, e um salto vira um sono que não houve — fazendo o app abrir seu ambiente de trabalho sem motivo.

Se não conseguir medir, emita `.didWake(sleptFor: 0)`: o resolver trata como sono curto e não dispara nada, que é o lado seguro.

**Só comece a consumir o stream depois de carregar o feriado e restaurar a pergunta pendente.** O `.didLogin` sai assim que o stream é aberto. No macOS o stream era aberto antes desses dois passos, e a avaliação rodava no meio deles: decidia sem saber do feriado e tinha o prompt sobrescrito pela restauração.

---

## Ajustes necessários no código existente

Duas coisas no código atual assumem macOS. Nenhuma impede o porte, mas ambas precisam de atenção.

### Diretório de dados — já resolvido

`FileStateStore.defaultRoot()` respeita a convenção de cada plataforma:

| Plataforma | Caminho |
|---|---|
| macOS | `~/Library/Application Support/WakeUpeer` |
| Linux | `$XDG_CONFIG_HOME/wakeupeer`, ou `~/.config/wakeupeer` |
| Windows | `%APPDATA%\WakeUpeer` |

O `FileStateStore` também aceita o diretório no construtor, então dá para ignorar o auxiliar e passar outro caminho se preferir.

### App sem janela principal

No macOS o `LSUIElement` tira o app do Dock e do alternador: só existe o ícone da barra, e reabrir o app pelo Finder não mostra nada. O equivalente em cada plataforma:

| Plataforma | Como |
|---|---|
| Linux | Não registrar janela de topo; `NoDisplay=true` no `.desktop` se não quiser lançador |
| Windows | Sem janela principal, só o ícone na área de notificação; subsistema `WINDOWS`, não `CONSOLE` |

A consequência vale para as três: **toda a interface precisa ser alcançável pelo ícone da bandeja**, porque não há outro caminho. Se a bandeja falhar em carregar, o app fica invisível e vivo — vale registrar em log o sucesso da criação do ícone e oferecer um comando de CLI que abra o painel.

### `bundleID` é um conceito da Apple

`LaunchItem.application(bundleID:displayName:path:)` e `TrackingEvent.bundleID` carregam um identificador que só o macOS chama assim.

**Não mude o nome do campo.** Renomear quebraria a configuração de todo mundo sem ganho real. Trate-o como "identificador estável do aplicativo" e preencha com o que faz sentido na plataforma:

| Plataforma | O que usar |
|---|---|
| macOS | `com.tinyspeck.slackmacgap` |
| Linux | Nome do `.desktop` (`slack.desktop`) ou do executável |
| Windows | AUMID, ou caminho normalizado do `.exe` |

O campo `path` já existe para o caminho absoluto, e o domínio nunca interpreta o conteúdo do `bundleID` — só compara igualdade.

---

## Linux

### Mapa de APIs

| Porta | Como implementar |
|---|---|
| `Clock` | `Calendar` do Foundation, igual ao macOS |
| `AppLauncher` | `xdg-open` para endereços e arquivos; `gio launch` ou `Process` com o `Exec` do `.desktop` para apps; `Process` direto para comandos |
| `runningApps` | Varrer `/proc/*/comm` e `/proc/*/cmdline`; ou `ps` se preferir simplicidade |
| `Notifier` | D-Bus `org.freedesktop.Notifications`. O método `Notify` aceita `actions`, e o sinal `ActionInvoked` devolve a resposta — dá para ter os dois botões |
| `HolidayProvider` | `BrazilianHolidayProvider`; opcionalmente ler um `.ics` assinado |
| `LoginItemManager` | Escrever um `.desktop` em `~/.config/autostart/`, ou uma unidade de usuário do systemd |
| `ForegroundSampler` | Depende do compositor — veja abaixo |
| `SystemEventSource` | D-Bus: `org.freedesktop.login1.Manager` emite `PrepareForSleep`; `org.freedesktop.ScreenSaver` avisa do bloqueio |

### O problema do app em foco

Esta é a única parte genuinamente difícil no Linux, e vale decidir cedo.

**No X11** funciona bem: `_NET_ACTIVE_WINDOW` via XCB ou Xlib dá a janela ativa, e `_NET_WM_PID` leva ao processo. O ocioso vem da extensão `XScreenSaver` (`XScreenSaverQueryInfo`).

**No Wayland não há API padrão** — é uma decisão de segurança do protocolo, não uma lacuna. Cada compositor resolve à sua maneira:

- **GNOME**: a interface D-Bus `org.gnome.Shell.Introspect` existe, mas exige que a extensão certa esteja ativa e pode não estar disponível.
- **KDE**: `org.kde.KWin` expõe informação de janelas.
- **wlroots** (Sway, Hyprland): protocolo `wlr-foreign-toplevel-management`, ou o IPC do próprio compositor (`swaymsg -t get_tree`).

**Recomendação honesta:** implemente X11 primeiro, detecte Wayland em tempo de execução (`XDG_SESSION_TYPE`) e, sem suporte, retorne `nil` no `sample()`. O rastreamento se desliga sozinho e o resto do app continua inteiro. Documente a limitação em vez de fingir que funciona.

O ocioso no Wayland tem saída melhor: `org.freedesktop.ScreenSaver.GetSessionIdleTime` ou o protocolo `ext-idle-notify-v1`.

### D-Bus sem dependências

Boa parte das portas do Linux passa por D-Bus. Há ligações Swift, mas para um app pessoal invocar `gdbus` ou `busctl` por `Process` evita uma dependência nativa inteira e é suficiente:

```swift
/// Notificação com dois botões, via D-Bus.
/// O retorno é o id da notificação, usado depois para retirá-la.
func notify(title: String, body: String, actions: [String]) throws -> UInt32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gdbus")
    process.arguments = [
        "call", "--session",
        "--dest", "org.freedesktop.Notifications",
        "--object-path", "/org/freedesktop/Notifications",
        "--method", "org.freedesktop.Notifications.Notify",
        "WakeUpeer", "0", "", title, body,
        "['abrir','Abrir agora','adiar','Agora não']",
        "{}", "0",
    ]
    // …ler a saída e extrair o id
}
```

Para **receber** a resposta é preciso escutar o sinal `ActionInvoked`, o que exige um processo vivo:

```sh
gdbus monitor --session --dest org.freedesktop.Notifications
```

Leia a saída linha a linha e converta em chamadas ao `AnswerSink`. É menos elegante que uma ligação nativa, mas não acrescenta dependência de compilação e funciona em qualquer distribuição.

### Suspensão e retomada

`org.freedesktop.login1` emite `PrepareForSleep` com um booleano: `true` antes de suspender, `false` ao retomar.

```sh
gdbus monitor --session=false --system \
  --dest org.freedesktop.login1 \
  --object-path /org/freedesktop/login1
```

**A escolha do relógio importa mais no Linux que no macOS.** `ContinuousClock` do Swift mapeia para `CLOCK_BOOTTIME`, que conta o tempo suspenso — é o que este app precisa. O primo `SuspendingClock` mapeia para `CLOCK_MONOTONIC`, que **para durante a suspensão**: usá-lo faria uma noite inteira aparecer como poucos segundos.

Descendo ao POSIX, quando quiser controle explícito:

```swift
var ts = timespec()
clock_gettime(CLOCK_BOOTTIME, &ts)   // conta suspensão
// clock_gettime(CLOCK_MONOTONIC, &ts) — NÃO conta
```

No macOS os dois se comportam quase igual para este caso, então um erro aqui só aparece no Linux. Veja [armadilhas](#armadilhas).

### Início automático

Um arquivo `.desktop` em `~/.config/autostart/` é o caminho mais compatível entre ambientes:

```ini
[Desktop Entry]
Type=Application
Name=WakeUpeer
Exec=/usr/local/bin/wakeupeer daemon
X-GNOME-Autostart-enabled=true
```

Uma unidade de usuário do systemd (`systemctl --user enable wakeupeer`) dá reinício automático e registro de log, ao custo de depender do systemd. Para um daemon que deve sobreviver a falhas, compensa.

### Interface

Sem SwiftUI, as opções realistas:

| Abordagem | Prós | Contras |
|---|---|---|
| **CLI + daemon** | Simples, útil desde cedo | Sem painel |
| **GTK4 via gir2swift** | Nativo, bandeja funciona | Ligações Swift imaturas |
| **Qt via ligação C** | Maduro, bandeja consistente | Interoperar C++ com Swift é trabalhoso |
| **Servidor local + navegador** | Reaproveita conceitos da UI atual | Não é bandeja de verdade |

Para um primeiro porte útil, **CLI mais daemon** entrega valor rápido: o daemon avalia os perfis e as notificações D-Bus fazem a pergunta; a CLI mostra estado e dispara perfis. A bandeja vem depois, se vier.

Vale saber que o ícone de bandeja está em situação parecida com a do app em foco: o GNOME removeu o suporte nativo e exige extensão, enquanto KDE e XFCE mantêm via `StatusNotifierItem`. Mais um motivo para não começar por aí.

---

## Windows

### Mapa de APIs

| Porta | Como implementar |
|---|---|
| `Clock` | `Calendar` do Foundation |
| `AppLauncher` | `ShellExecuteEx` para apps, arquivos e endereços; `CreateProcess` para comandos |
| `runningApps` | `EnumProcesses` + `QueryFullProcessImageName`; ou `EnumWindows` para janelas visíveis |
| `Notifier` | Toast do WinRT (`ToastNotificationManager`), que suporta botões de ação |
| `HolidayProvider` | `BrazilianHolidayProvider` |
| `LoginItemManager` | Chave `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, ou uma tarefa no Agendador |
| `ForegroundSampler` | `GetForegroundWindow` + `GetWindowThreadProcessId`; ocioso por `GetLastInputInfo` |
| `SystemEventSource` | `WM_POWERBROADCAST` para suspensão e retomada; `WTSRegisterSessionNotification` para bloqueio |

O Windows é, ironicamente, **mais fácil que o Linux** neste app: `GetForegroundWindow` e `GetLastInputInfo` são APIs estáveis, documentadas e sem ambiguidade, enquanto no Linux o mesmo depende do compositor — e no Wayland sequer existe caminho padrão.

### Interoperação com Win32

Swift importa as APIs do sistema por `WinSDK`:

```swift
import WinSDK
import Foundation

/// Qual processo está em primeiro plano.
func foregroundProcessID() -> DWORD? {
    let window = GetForegroundWindow()
    guard window != nil else { return nil }
    var pid: DWORD = 0
    GetWindowThreadProcessId(window, &pid)
    return pid == 0 ? nil : pid
}

/// Segundos desde a última entrada do usuário — o equivalente ao
/// CGEventSource do macOS, e sem exigir permissão nenhuma.
func idleSeconds() -> TimeInterval {
    var info = LASTINPUTINFO()
    info.cbSize = UInt32(MemoryLayout<LASTINPUTINFO>.size)
    guard GetLastInputInfo(&info) else { return 0 }
    // GetTickCount64 dá o tempo desde o boot: é monotônico, o que serve
    // também para medir suspensão sem depender do relógio de parede.
    return TimeInterval(GetTickCount64() - UInt64(info.dwTime)) / 1000
}
```

Duas asperezas previsíveis:

**Strings largas.** A API do Windows usa UTF-16. Converter exige cuidado nas duas direções:

```swift
extension String {
    /// Para passar a uma API que espera LPCWSTR.
    var wide: [WCHAR] { Array(utf16) + [0] }

    /// Para ler o que uma API devolveu.
    init(fromWide buffer: [WCHAR]) {
        self = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }
}
```

**Tipos opacos.** `HANDLE`, `HWND` e afins chegam como ponteiros opcionais; verifique antes de usar. Encapsule cada chamada Win32 numa função Swift pequena, como nos exemplos acima, em vez de espalhar interoperação pela lógica — isso mantém a parte testável separada da parte que só roda no Windows.

### Identificar o aplicativo

Onde o macOS tem `bundleIdentifier`, o Windows oferece o caminho do executável:

```swift
func executablePath(of pid: DWORD) -> String? {
    guard let process = OpenProcess(
        DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
    defer { CloseHandle(process) }

    var size = DWORD(MAX_PATH)
    var buffer = [WCHAR](repeating: 0, count: Int(size))
    guard QueryFullProcessImageNameW(process, 0, &buffer, &size) else { return nil }
    return String(fromWide: buffer)
}
```

Use o caminho normalizado em minúsculas como `bundleID` — estável entre execuções, que é tudo o que o domínio exige. Para apps da Loja, o AUMID é mais correto, mas obtê-lo dá bem mais trabalho e só vale se você usar esses apps nos perfis.

### Interface

**Recomendação: não escreva a interface em Swift.** Interoperar Swift com WinRT é possível mas custoso, e a UI é justamente a parte que não se beneficia de compartilhar código com o macOS.

O caminho mais direto é separar em dois processos:

```
wakeupeer-core.exe   Swift — domínio, portas, decisão, rastreamento
        ↕            JSON por stdin/stdout ou named pipe
WakeUpeer.exe        C# + WinUI 3 — bandeja, painel, preferências
```

Cada lado faz o que faz bem, e o protocolo entre eles é pequeno: estado atual, disparar perfil, responder pergunta, pedir relatório. A alternativa monolítica seria Win32 puro pelo Swift — viável para uma bandeja simples com `Shell_NotifyIcon`, desconfortável para o painel e o relatório.

Se quiser começar sem interface nenhuma, veja a [ordem de implementação](#ordem-de-implementação): na etapa 3 o porte já é utilizável por linha de comando.

### Início automático

Duas opções, com trocas diferentes:

| Como | Prós | Contras |
|---|---|---|
| `HKCU\…\CurrentVersion\Run` | Simples, sem privilégio de administrador | Sem controle de atraso ou condições |
| Agendador de Tarefas | Gatilho no logon com atraso, sobrevive melhor a atualizações | API mais pesada, ou depende do `schtasks.exe` |

Para este app o registro basta. O `LoginItemStatus.requiresApproval` não tem equivalente no Windows — nunca o retorne; use `.enabled` ou `.notRegistered`.

### Suspensão e retomada

`WM_POWERBROADCAST` chega a uma janela, então é preciso uma janela — ainda que invisível, criada só para receber mensagens (*message-only window*, com `HWND_MESSAGE` como pai).

```
PBT_APMSUSPEND        → .willSleep
PBT_APMRESUMEAUTOMATIC → .didWake
```

**Meça a suspensão com `GetTickCount64`**, que conta desde o boot e não é afetado por ajuste de hora. A diferença entre dois `Date` daria uma suspensão fantasma sempre que o Windows sincronizasse o relógio — e uma suspensão fantasma faz o app abrir seu ambiente de trabalho sem motivo.

Para bloqueio e desbloqueio de sessão, `WTSRegisterSessionNotification` entrega `WTS_SESSION_LOCK` e `WTS_SESSION_UNLOCK` à mesma janela.

---

## Ordem de implementação

Cada etapa entrega algo funcional; nada exige a etapa seguinte para valer a pena.

**1. Provar a base.** `swift build --target WakeUpeerDomain` e `swift test` na plataforma nova. Deve passar sem escrever uma linha. Se não passar, o problema está na base e é isso que se corrige primeiro.

**2. Executável mínimo.** Um `main.swift` que carrega a configuração, chama `ProfileResolver.resolve` e imprime o resultado. Já dá para validar que a decisão funciona ali.

**3. `AppLauncher`.** Com ele, um comando `wakeupeer launch Trabalho` abre o ambiente. **Neste ponto o porte já é útil** e pode ser usado todo dia.

**4. `SystemEventSource` e `LoginItemManager`.** A automação começa: login e despertar disparam a avaliação.

**5. `Notifier`.** A pergunta sai do terminal e vira notificação do sistema.

**6. `ForegroundSampler`.** Rastreamento e relatório passam a funcionar.

**7. Interface gráfica.** Bandeja, painel, preferências.

---

## Como verificar

O porte está correto quando estes testes passam na plataforma nova:

```sh
cd WakeUpeerCore
swift test --filter 'WakeUpeer(Domain|Persistence)Tests'
```

Os 87 testes não dependem de plataforma. Se um falhar em Linux e passar em macOS, é quase certo que a causa está numa das três fontes abaixo, não na sua implementação:

- **Fuso horário** — o domínio nunca usa `Calendar.current`; se algo usar, o comportamento muda com a máquina.
- **Ordenação de dicionário** — a iteração não tem ordem garantida e varia entre plataformas; o resolver desempata por UUID justamente por isso.
- **Precisão de datas** — `Date` é ponto flutuante, e comparar `TimeInterval` com `Int` sem conversão explícita falha.

Para as portas, vale um teste manual roteirizado:

| Cenário | Esperado |
|---|---|
| Disparar perfil com tudo fechado | Todos os itens abrem, em ordem, com pausa |
| Disparar com um app já aberto | Esse app não é relançado |
| Item apontando para app desinstalado | Falha registrada e visível, sem travar os outros |
| Suspender e retomar antes do limite | Nada acontece |
| Suspender além do limite | A pergunta aparece |
| Retomar várias vezes no mesmo dia | Uma pergunta só |
| Ignorar a pergunta da manhã e reiniciar na janela do perfil seguinte | A pergunta é a do perfil seguinte; a antiga some do `fire-log.json` |
| Disparar na mão um perfil com pergunta aberta | A pergunta e a notificação somem |
| Ajustar o relógio do sistema para frente | Nenhum disparo (prova o relógio monotônico) |

O último é o mais importante e o mais esquecido.

---

## Armadilhas

**Medir sono com `Date`.** O erro mais provável do porte inteiro. Sincronização de hora salta o relógio, e um salto de horas é indistinguível de uma noite de sono. Use um relógio monotônico.

**Escolher o relógio monotônico errado.** Swift tem dois, e os nomes são o oposto do que a intuição sugere:

| Relógio | Durante a suspensão | Linux |
|---|---|---|
| `ContinuousClock` | **continua contando** | `CLOCK_BOOTTIME` |
| `SuspendingClock` | **para junto** | `CLOCK_MONOTONIC` |

Para medir quanto tempo a máquina ficou suspensa, o certo é `ContinuousClock` — o nome descreve o relógio, não o sistema. Usar `SuspendingClock` faria uma noite inteira aparecer como poucos segundos, e o perfil da manhã nunca seria oferecido.

A armadilha é que **no macOS os dois se comportam quase igual** para este caso, então um erro aqui passa despercebido até o porte para Linux. Se descer ao POSIX, o par é `CLOCK_BOOTTIME` (conta suspensão) contra `CLOCK_MONOTONIC` (não conta); no Windows, `GetTickCount64` já inclui o tempo suspenso.

**Lançar apps em paralelo.** Trava o ambiente gráfico e faz apps pesados falharem em arranque frio. Sequencial, com pausa.

**Montar linha de comando por string.** O `.shell` guarda executável e argumentos separados de propósito. Concatenar e passar ao shell transforma um arquivo de configuração editável num vetor de execução arbitrária.

**Inflar o tempo ocioso.** Ao detectar inatividade, o fim da sessão precisa ser retroagido para quando ela começou. Sem isso, cada transição soma o período inteiro de ocioso como uso.

**Assumir que o dia da janela é o dia do relógio.** Numa janela que atravessa a meia-noite, o dia de referência é o do **início**. Confundir os dois faz o perfil disparar duas vezes. Os testes cobrem isso — confie neles.

**Usar `Calendar.current` no domínio.** Quebra os testes de fuso e faz o comportamento depender da máquina. O calendário é sempre injetado.

**Restaurar qualquer pergunta pendente do dia.** Outro bug real do macOS: ao iniciar, o app restaurava a primeira pendência com a data de hoje, sem checar se o perfil ainda valia. Uma pergunta do Trabalho ignorada de manhã reaparecia às 17h13, quando o perfil da vez já era outro. A regra está no domínio — `ProfileResolver.pendingToRestore` só devolve a pendência do perfil que venceria agora — e o porte deve usá-la em vez de ler `fireLog.pending` direto. Mantenha no máximo uma pergunta aberta: a nova aposenta as anteriores, e o disparo manual encerra a do próprio perfil.

**Deixar o toolkit persistir geometria de janela sem controle.** No macOS o `HSplitView` do SwiftUI salva a posição das divisórias sob uma chave derivada do nome da janela, que o código não escolhe nem consegue desligar. Ao renomear ou reestruturar a janela, a geometria antiga é restaurada sobre a nova e o layout abre quebrado — no caso real, subviews de 708 pt numa janela de 640, com o conteúdo espremido no rodapé. Onde a divisória não precisa ser arrastável, use um contêiner comum com largura fixa; onde precisar, escolha o nome de autosave explicitamente e versione-o.

**Bloquear na autorização de notificações.** No macOS isso já causou um bug real: o pedido de permissão bloqueia até o usuário responder, e como era a primeira chamada do arranque, o rastreamento nunca começava. Peça autorização em paralelo, nunca no caminho crítico.

---

## Referências no código

| O que | Onde |
|---|---|
| Os protocolos | [`Ports.swift`](../WakeUpeerCore/Sources/WakeUpeerDomain/Ports.swift) |
| Motor de decisão | [`ProfileResolver.swift`](../WakeUpeerCore/Sources/WakeUpeerDomain/ProfileResolver.swift) |
| Modelos e configuração | [`Models.swift`](../WakeUpeerCore/Sources/WakeUpeerDomain/Models.swift) |
| Feriados portáteis | [`BrazilianHolidays.swift`](../WakeUpeerCore/Sources/WakeUpeerDomain/BrazilianHolidays.swift) |
| Persistência portátil | [`FileStateStore.swift`](../WakeUpeerCore/Sources/WakeUpeerPersistence/FileStateStore.swift) |
| Exemplo de porta completa | [`WakeUpeerPlatformMac/`](../WakeUpeerCore/Sources/WakeUpeerPlatformMac/) |
| Montagem das dependências | `AppState.live()` em [`AppState.swift`](../WakeUpeerApp/AppState.swift) |
