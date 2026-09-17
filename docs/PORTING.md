# Portar o WakeUpeer para Linux e Windows

O domínio foi escrito para isto: toda a lógica — qual perfil dispara, quando é feriado, como agregar o relatório — vive em `WakeUpeerDomain`, que importa apenas `Foundation`. Portar é implementar oito protocolos e escrever uma interface.

Este guia diz exatamente o que implementar, com qual API de cada plataforma, e onde estão as armadilhas.

---

## Sumário

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

### Interface

Sem SwiftUI, as opções realistas:

| Abordagem | Prós | Contras |
|---|---|---|
| **GTK4 via gir2swift** | Nativo, bandeja funciona | Ligações Swift imaturas |
| **Qt via ligação C** | Maduro, bandeja consistente | Interoperar C++ com Swift é trabalhoso |
| **Servidor local + navegador** | Reaproveita conceitos da UI atual | Não é bandeja de verdade |
| **Só CLI + daemon** | Simples, rápido de ter | Sem painel |

Para um primeiro porte útil, **CLI mais daemon** entrega valor rápido: o daemon roda o `Orchestrator` e as notificações D-Bus fazem a pergunta; a CLI mostra estado e dispara perfis. A bandeja vem depois.

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

O Windows é, ironicamente, **mais fácil que o Linux** neste app: `GetForegroundWindow` e `GetLastInputInfo` são APIs estáveis e sem ambiguidade, enquanto no Linux o mesmo depende do compositor.

### Interface

- **WinUI 3** é o caminho nativo, com ícone de bandeja pelo `Shell_NotifyIcon` clássico.
- Interoperar Swift com WinRT dá trabalho; avalie um executável auxiliar em C# só para a interface, conversando com o núcleo Swift por um protocolo simples (stdin/stdout em JSON, ou um named pipe).

### Interoperação com Win32

Swift no Windows importa as APIs do sistema:

```swift
import WinSDK

let hwnd = GetForegroundWindow()
var pid: DWORD = 0
GetWindowThreadProcessId(hwnd, &pid)
```

Funciona, mas as conversões de tipo (`LPWSTR`, `HANDLE`, wide strings) são verbosas. Encapsule cada API numa função Swift pequena e testável, em vez de espalhar chamadas Win32 pela lógica.

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

Os 83 testes não dependem de plataforma. Se um falhar em Linux e passar em macOS, é quase certo que a causa está numa das três fontes abaixo, não na sua implementação:

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
| Ajustar o relógio do sistema para frente | Nenhum disparo (prova o relógio monotônico) |

O último é o mais importante e o mais esquecido.

---

## Armadilhas

**Medir sono com `Date`.** O erro mais provável do porte inteiro. Sincronização de hora salta o relógio, e um salto de horas é indistinguível de uma noite de sono. Use `ContinuousClock`.

**Lançar apps em paralelo.** Trava o ambiente gráfico e faz apps pesados falharem em arranque frio. Sequencial, com pausa.

**Montar linha de comando por string.** O `.shell` guarda executável e argumentos separados de propósito. Concatenar e passar ao shell transforma um arquivo de configuração editável num vetor de execução arbitrária.

**Inflar o tempo ocioso.** Ao detectar inatividade, o fim da sessão precisa ser retroagido para quando ela começou. Sem isso, cada transição soma o período inteiro de ocioso como uso.

**Assumir que o dia da janela é o dia do relógio.** Numa janela que atravessa a meia-noite, o dia de referência é o do **início**. Confundir os dois faz o perfil disparar duas vezes. Os testes cobrem isso — confie neles.

**Usar `Calendar.current` no domínio.** Quebra os testes de fuso e faz o comportamento depender da máquina. O calendário é sempre injetado.

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
