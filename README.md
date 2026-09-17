# WakeUpeer

App de barra de menu que abre o ambiente certo conforme o dia e a hora.

Ao fazer login ou acordar o Mac do sono, o WakeUpeer identifica qual perfil se aplica — trabalho, noite de semana, fim de semana, madrugada — dá uma saudação e **pergunta** se deve abrir os apps daquele contexto. Nada abre sem confirmação.

Em feriados de dia útil, a pergunta muda: *"Hoje é feriado: Independência do Brasil. Vai trabalhar hoje?"*

## Requisitos

macOS 14+ · Xcode 16+ · Swift 6

## Compilar e instalar

```sh
xcodebuild -project WakeUpeer.xcodeproj -scheme WakeUpeer \
  -configuration Release CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```

Copie o `.app` para `/Applications` — fora de lá o início automático não se mantém, porque o `SMAppService` perde o vínculo quando o binário muda de lugar.

### Assinatura durante o desenvolvimento

A assinatura ad-hoc muda a cada build, e o macOS trata cada build como um app diferente: ele volta a pedir a permissão de Calendário toda vez. Um certificado autoassinado persistente resolve.

Em *Acesso às Chaves → Assistente de Certificado → Criar Certificado*: nome `WakeUpeer Dev`, tipo **Assinatura de Código**, autoassinado. Depois:

```sh
codesign --force --deep --sign "WakeUpeer Dev" /Applications/WakeUpeer.app
```

## Arquitetura

Três camadas, separadas para que portar a Linux ou Windows seja implementar protocolos, não reescrever regras.

```
WakeUpeerCore/
├── WakeUpeerDomain/       só Foundation — compila em qualquer plataforma
├── WakeUpeerPersistence/  só Foundation — JSON e JSONL
└── WakeUpeerPlatformMac/  AppKit, EventKit, UserNotifications, ServiceManagement
WakeUpeerApp/              SwiftUI — MenuBarExtra, preferências, relatório
```

`WakeUpeerDomain` não conhece a Apple. Tudo que toca o sistema entra por protocolo — `AppLauncher`, `Notifier`, `HolidayProvider`, `StateStore`, `Clock`, `LoginItemManager`, `ForegroundSampler`, `SystemEventSource`. O CI compila o domínio em Linux justamente para que um `import AppKit` acidental quebre o build em vez de virar dívida.

### O motor de decisão

`ProfileResolver.resolve` é uma função pura: recebe data, perfis, estado de feriado e histórico, devolve qual perfil disparar. Sem I/O, sem relógio global — por isso os casos difíceis são testáveis.

Os que costumam dar errado, e como são tratados:

- **Janela que atravessa a meia-noite.** Um perfil de segunda 22:00–02:00 continua ativo à 01:00 de terça, e o dia de referência do histórico é a segunda. Usar a data do relógio faria o perfil disparar duas vezes.
- **Sobreposição.** Um perfil por disparo. A ordem é: dentro da janela ganha de tolerância, depois prioridade, depois janela mais estreita, depois quem começou mais recentemente, e por fim o UUID — para o resultado ser o mesmo em toda execução.
- **Tolerância.** Ligar o Mac às 9h15 com uma janela 08:00–09:00 e 90 min de tolerância ainda oferece o perfil.
- **Despertar curto.** Abrir a tampa para ver a hora não dispara nada. A duração do sono é medida com relógio monotônico, porque `Date` salta quando o sistema sincroniza a hora.
- **Feriado.** Em dia útil, pergunta. No fim de semana, silêncio — perguntar seria ruído. Sem permissão de calendário, comporta-se como dia normal: falta de acesso nunca bloqueia o usuário.

### Feriados

Os feriados nacionais são calculados localmente, com os móveis derivados da Páscoa pelo algoritmo de Meeus. Funciona sem permissão nenhuma e já roda em Linux.

O EventKit fica **na frente** dessa lista, não no lugar dela, para acrescentar feriados municipais, estaduais e datas pessoais. Negar o acesso degrada para a tabela nacional.

### Rastreamento de uso

Grava intervalos, não amostras. Uma sessão em memória só vira um evento quando o app em foco muda, o usuário fica ocioso, a máquina dorme ou o dia vira — cerca de 300 registros por dia em vez de 5.800.

O ocioso vem de `CGEventSource`, que não exige permissão de Acessibilidade. Ao detectar inatividade, o fim da sessão é retroagido para quando ela começou, senão cada transição somaria minutos que não existiram. Títulos de janela nunca são lidos.

## Dados

```
~/Library/Application Support/WakeUpeer/
├── config.json              perfis e preferências, editável à mão
├── fire-log.json            histórico de disparos e perguntas pendentes
├── tracking/2026-09.jsonl   uso por mês, append-only
└── cache/
```

O `config.json` é observado: editá-lo em um editor aplica as mudanças sem reiniciar. Uma versão futura do formato é carregada com aviso em vez de descartada, e um perfil malformado é ignorado sozinho sem levar os outros junto.

## Testes

```sh
cd WakeUpeerCore && swift test
```

83 testes, só no domínio e na persistência. Cobrem a virada da meia-noite, quatro fusos horários, as horas inexistente e duplicada do horário de verão, a tabela de feriados de 2020 a 2035, JSONL truncado por queda de energia e migração de configuração.

## Portar para outra plataforma

Implementar os protocolos de `WakeUpeerDomain` em um novo alvo. No Linux seria `xdg-open` para lançar, `/proc` para os processos, um serviço de usuário do systemd para o início automático e libnotify para as notificações. O domínio não muda.
