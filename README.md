# WakeUpeer

App de barra de menu que abre o ambiente certo conforme o dia e a hora.

Ao fazer login ou acordar o Mac do sono, o WakeUpeer identifica qual perfil se aplica — trabalho, noite de semana, fim de semana, madrugada — dá uma saudação e **pergunta** se deve abrir os apps daquele contexto. Nada abre sem confirmação.

Em feriados de dia útil a pergunta muda: *"Hoje é feriado: Independência do Brasil. Vai trabalhar hoje?"*

De quebra, registra quanto tempo cada app fica em primeiro plano e monta um relatório semanal.

---

## Sumário

- [Funcionalidades](#funcionalidades)
- [Requisitos](#requisitos)
- [Instalação](#instalação)
- [Uso](#uso)
- [Configuração](#configuração)
- [Arquitetura](#arquitetura)
- [O motor de decisão](#o-motor-de-decisão)
- [Feriados](#feriados)
- [Rastreamento de uso](#rastreamento-de-uso)
- [Onde ficam os dados](#onde-ficam-os-dados)
- [Privacidade](#privacidade)
- [Testes](#testes)
- [Solução de problemas](#solução-de-problemas)
- [Portar para Linux e Windows](#portar-para-linux-e-windows)

---

## Funcionalidades

**Perfis por horário.** Cada perfil define dias da semana, uma janela de horário e o que abrir — apps, endereços, arquivos ou comandos. Janelas podem atravessar a meia-noite.

**Confirmação sempre.** Um perfil nunca abre sozinho. A notificação traz "Abrir agora" e "Agora não"; o painel espelha a mesma pergunta, então descartar a notificação não perde a decisão.

**Feriados.** Feriados nacionais brasileiros calculados localmente, incluindo os móveis. O calendário do macOS entra por cima para feriados municipais e datas pessoais.

**Despertar inteligente.** Abrir a tampa para ver a hora não dispara nada — só um sono acima do limite configurado conta.

**Tempo de uso.** Quanto cada app ficou em primeiro plano hoje, visível no painel, e um relatório semanal com gráficos e exportação CSV.

**Painel e menu.** Clique esquerdo abre o painel com o que está rodando; clique direito abre um menu para disparar qualquer perfil direto, com atalhos ⌘1–⌘9.

---

## Requisitos

| | |
|---|---|
| Sistema | macOS 14 (Sonoma) ou superior |
| Build | Xcode 16+ · Swift 6 |
| Permissões | Notificações (opcional) · Calendário (opcional) |

Nenhuma permissão é obrigatória. Sem notificações, o painel continua sendo o canal da pergunta. Sem calendário, os feriados nacionais continuam sendo detectados.

A de Calendário só é pedida quando você escolhe um calendário na aba Feriados. Com `holidayCalendarIDs` vazio — o padrão — o app usa a tabela embutida e nunca toca no EventKit, então o diálogo não aparece.

---

## Instalação

```sh
git clone https://github.com/HayatoG/wakeupeer.git
cd wakeupeer

xcodebuild -project WakeUpeer.xcodeproj -scheme WakeUpeer \
  -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```

Copie o `.app` gerado para `/Applications`:

```sh
cp -R ~/Library/Developer/Xcode/DerivedData/WakeUpeer-*/Build/Products/Release/WakeUpeer.app /Applications/
xattr -dr com.apple.quarantine /Applications/WakeUpeer.app
open /Applications/WakeUpeer.app
```

> **O app precisa ficar em `/Applications`.** O `SMAppService` vincula o registro de início automático ao caminho do binário; movê-lo quebra o vínculo em silêncio.

> **Instale o build Release, não o Debug.** O bundle de Debug carrega `WakeUpeer.debug.dylib` e `__preview.dylib` e embute um `LC_RPATH` para o diretório de build, que some quando a pasta é limpa. Se `Contents/MacOS/` tiver mais que o binário `WakeUpeer`, você copiou o bundle errado.

### Assinatura durante o desenvolvimento

A assinatura ad-hoc (`-`) muda a cada build, e o macOS trata cada build como um app diferente: a permissão de Calendário é pedida de novo toda vez. Um certificado autoassinado persistente resolve.

Em **Acesso às Chaves → Assistente de Certificado → Criar Certificado**: nome `WakeUpeer Dev`, tipo **Assinatura de Código**, autoassinado. Depois:

```sh
codesign --force --deep --sign "WakeUpeer Dev" /Applications/WakeUpeer.app
```

---

## Uso

| Ação | Como |
|---|---|
| Ver o que está rodando | Clique esquerdo no ícone |
| Disparar um perfil agora | Clique direito → nome do perfil, ou ⌘1–⌘9 |
| Responder a pergunta pendente | Botões na notificação, no painel ou no menu de contexto |
| Abrir um app só | Passe o mouse sobre o item fechado e clique na seta |
| Relatório | Clique direito → Relatório (⌘R) |
| Preferências | Clique direito → Preferências (⌘,) |

O ícone muda conforme o contexto: símbolo do perfil ativo, período do dia quando não há perfil, um sino quando há pergunta pendente, e pulsa enquanto os apps abrem.

O WakeUpeer é `LSUIElement`: não tem ícone no Dock nem janela principal. Abrir pelo Launchpad ou pelo Finder com ele já rodando não mostra nada — tudo passa pelo ícone da barra de menus.

---

## Configuração

Quatro abas em Preferências:

**Geral** — início automático, limite de sono para o despertar contar, pausa entre lançamentos, política de feriado.

**Perfis** — criar, duplicar, apagar e reordenar. Para cada um: nome, ícone, dias da semana, janela de horário, tolerância, prioridade, e a lista do que abrir.

**Feriados** — permissão de calendário, quais calendários consultar, e os próximos feriados nacionais.

**Uso** — ligar ou desligar o rastreamento, limite de ocioso, retenção, resumo semanal, apagar histórico.

### Editando o arquivo direto

O `config.json` é legível e o app o observa: salvar no editor aplica as mudanças sem reiniciar.

```jsonc
{
  "schemaVersion": 1,
  "profiles": [
    {
      "id": "…",
      "name": "Trabalho",
      "isEnabled": true,
      "weekdays": [2, 3, 4, 5, 6],        // domingo = 1
      "window": { "startMinutes": 480, "endMinutes": 1020 },
      "skipOnHoliday": true,               // pergunta antes em feriado
      "priority": 10,                      // maior vence na sobreposição
      "graceMinutes": 90,                  // tolerância após o fim
      "dedupeScope": "oncePerDay",
      "symbolName": "briefcase",
      "items": [
        {
          "item": { "application": {
            "bundleID": "com.tinyspeck.slackmacgap",
            "displayName": "Slack"
          }},
          "isEnabled": true,
          "bringToFront": false
        }
      ]
    }
  ],
  "wakeThresholdHours": 4,
  "launchDelayMilliseconds": 600
}
```

Um perfil malformado é ignorado sozinho, sem levar os outros junto, e o aviso aparece em Preferências → Geral.

---

## Arquitetura

Três camadas, separadas para que portar a outra plataforma seja implementar protocolos, não reescrever regras.

```
WakeUpeerCore/
├── WakeUpeerDomain/       só Foundation — compila em Linux e Windows
├── WakeUpeerPersistence/  só Foundation — JSON e JSONL
└── WakeUpeerPlatformMac/  AppKit · EventKit · UserNotifications · ServiceManagement
WakeUpeerApp/              SwiftUI + AppKit — barra, painel, preferências, relatório
```

`WakeUpeerDomain` não conhece a Apple. Tudo que toca o sistema entra por protocolo:

| Porta | Responsabilidade |
|---|---|
| `Clock` | Hora e calendário, com fuso injetado |
| `AppLauncher` | Abrir itens, listar o que roda |
| `Notifier` | Perguntar e informar |
| `HolidayProvider` | Saber se o dia é feriado |
| `StateStore` | Ler e gravar configuração e histórico |
| `LoginItemManager` | Início automático |
| `ForegroundSampler` | Qual app está em foco |
| `SystemEventSource` | Login, sono, despertar, bloqueio |

O CI compila o domínio em Linux justamente para que um `import AppKit` acidental quebre o build em vez de virar dívida descoberta tarde.

---

## O motor de decisão

`ProfileResolver.resolve` é uma função pura: recebe data, perfis, estado de feriado e histórico, devolve qual perfil disparar. Sem I/O, sem relógio global — por isso os casos difíceis são testáveis.

```swift
func resolve(_ input: ResolutionInput) -> Resolution
// .fire(perfil, windowDay:) | .askHolidayConfirmation(…) | .skip(reason:)
```

Os casos que costumam dar errado, e como são tratados:

**Janela que atravessa a meia-noite.** Um perfil de segunda 22:00–02:00 continua ativo à 01:00 de terça, e o dia de referência do histórico é a *segunda*. Usar a data do relógio faria o perfil disparar de novo depois da meia-noite.

**Sobreposição.** Um perfil por disparo — abrir dois ambientes de uma vez é pior que escolher errado. A ordem de desempate: dentro da janela ganha de tolerância → maior prioridade → janela mais estreita → começou mais recentemente → UUID. O último critério garante que o resultado seja o mesmo em toda execução.

**Tolerância.** Ligar o Mac às 9h15 com janela 08:00–09:00 e 90 min de tolerância ainda oferece o perfil.

**Despertar curto.** Abrir a tampa para ver a hora não dispara nada. A duração do sono vem de relógio monotônico, porque `Date` salta quando o sistema sincroniza a hora e inventaria sonos que não houve.

**Feriado.** Em dia útil, pergunta. No fim de semana, silêncio — perguntar seria ruído. Sem permissão de calendário, comporta-se como dia normal: falta de acesso nunca bloqueia o usuário.

**Pergunta que envelheceu.** Só existe uma pergunta aberta por vez, e ela precisa ser a do perfil que venceria *agora*. Ao reiniciar, `ProfileResolver.pendingToRestore` devolve a pergunta pendente apenas se ela for a do vencedor atual; as outras saem do `fire-log.json` e têm a notificação recolhida. Sem isso, uma pergunta do Trabalho ignorada às 9h voltava às 17h13 no lugar da Noite de semana. Pelo mesmo motivo, uma pergunta nova aposenta as anteriores, e disparar um perfil na mão encerra a pergunta que estivesse aberta para ele.

---

## Feriados

Os feriados nacionais são calculados localmente. Os móveis derivam da Páscoa pelo algoritmo de Meeus/Jones/Butcher:

| Feriado | Deslocamento |
|---|---|
| Carnaval | −48 e −47 dias |
| Sexta-feira Santa | −2 dias |
| Corpus Christi | +60 dias |

Mais os fixos e Consciência Negra, nacional desde 2024. Conferido contra a tabela litúrgica de 2020 a 2035.

O EventKit fica **na frente** dessa lista, não no lugar dela, acrescentando feriados municipais, estaduais e datas pessoais. Negar o acesso degrada para a tabela nacional.

---

## Rastreamento de uso

Grava **intervalos, não amostras**. Uma sessão em memória só vira um evento quando o app em foco muda, o usuário fica ocioso, a máquina dorme ou o dia vira — cerca de 300 registros por dia em vez de 5.800 de uma amostragem a cada 15 s.

Detalhes que mudam o resultado:

- **Ocioso** vem de `CGEventSource`, que não exige permissão de Acessibilidade. Ao detectar inatividade, o fim da sessão é retroagido para quando ela de fato começou — sem isso cada transição somaria minutos que não existiram.
- **Sono abrupto** (queda de bateria) não emite notificação. É detectado por salto do relógio monotônico e classificado como suspensão, não como uso.
- **Tela bloqueada** conta separado de ocioso.
- **Títulos de janela nunca são lidos.**

---

## Onde ficam os dados

```
~/Library/Application Support/WakeUpeer/
├── config.json              perfis e preferências
├── fire-log.json            disparos e perguntas pendentes
├── tracking/2026-09.jsonl   uso por mês, append-only
└── cache/
```

JSONL mensal porque acrescentar é barato, o relatório semanal lê no máximo dois arquivos, e a purga por retenção é apagar arquivo. Cerca de 2 MB por ano.

Uma versão futura do formato é carregada com aviso em vez de descartada, e migrar guarda `config.backup-vN.json` antes de reescrever.

---

## Privacidade

Nada sai da máquina. O app não faz requisições de rede — não há telemetria, nem atualização automática, nem sincronização.

O que ele registra fica em `~/Library/Application Support/WakeUpeer/`, em texto legível, e some quando você apaga a pasta. O botão em Preferências → Uso apaga o histórico a qualquer momento.

O rastreamento guarda identificador e nome do app, não o que você faz nele. Títulos de janela — que revelariam repositório, site ou documento — não são lidos, e por isso o app não pede permissão de Acessibilidade nem de Gravação de Tela.

---

## Testes

```sh
cd WakeUpeerCore && swift test
```

87 testes, só no domínio e na persistência — a UI não é testada automaticamente.

| Área | O que cobre |
|---|---|
| `ProfileResolver` | Bordas da janela, virada da meia-noite, sobreposição, tolerância, despertar, feriado, restauração de pergunta pendente |
| Fusos | Suíte inteira em São Paulo, UTC, Kiritimati (UTC+14) e Nova York |
| Horário de verão | A hora que não existe e a que acontece duas vezes |
| Feriados | Tabela de 2020 a 2035 contra fonte oficial |
| `ReportBuilder` | Clipping nas bordas, divisão na meia-noite, soma das partes |
| Persistência | Migração, JSONL truncado por queda de energia, fire-log corrompido, purga |

---

## Solução de problemas

**O app não pergunta nada de manhã.**
Verifique Preferências → Geral se o início automático está ativo e se o app está em `/Applications`. Se você só fecha a tampa, o sono precisa passar do limite configurado.

**A pergunta é de um perfil que já passou.**
Corrigido: acontecia ao reiniciar com uma pergunta antiga ainda sem resposta — ela era restaurada por cima da pergunta do perfil da vez. Se ainda vir isso, confira a chave `pending` em `fire-log.json`: deve haver no máximo uma entrada, a do perfil atual.

**Clico no app em Aplicativos e nada acontece.**
É o comportamento esperado. Ele vive na barra de menus, sem Dock nem janela; se já estiver rodando, abrir de novo não tem efeito visível. Procure o ícone na barra — `pgrep -x WakeUpeer` confirma que está ativo.

**As notificações não aparecem.**
Ajustes do Sistema → Notificações → WakeUpeer. O app precisa estar assinado; rodar por `swift run` não funciona. O painel continua mostrando a pergunta de qualquer forma.

**A permissão de Calendário é pedida a cada build.**
Assinatura ad-hoc muda a cada compilação. Use um certificado autoassinado persistente (veja [Instalação](#assinatura-durante-o-desenvolvimento)).

**A tela de Perfis abre com o conteúdo espremido no rodapé.**
Corrigido: o `HSplitView` guardava a posição das divisórias em disco, sob um nome próprio do AppKit, e restaurava a geometria de uma versão anterior da janela — subviews somando 708 pt numa janela de 640. A lista passou a ter largura fixa num `HStack`, e o app apaga as chaves órfãs no arranque. Para limpar à mão:

```sh
defaults delete com.guilherme.WakeUpeer "NSSplitView Subview Frames preferences, SidebarNavigationSplitView"
```

**Um app não abre ao disparar o perfil.**
O painel mostra a falha com o motivo. Normalmente é um app desinstalado ou movido — reabra o item nas Preferências.

**O início automático desliga sozinho.**
Ajustes do Sistema → Geral → Itens de Início. Se você desativou por lá, só por lá dá para reativar; o app detecta e mostra um botão que abre a tela certa.

---

## Portar para Linux e Windows

O domínio já está pronto: é implementar as portas em um novo alvo. O guia completo, com as APIs equivalentes de cada plataforma e as armadilhas conhecidas, está em **[docs/PORTING.md](docs/PORTING.md)**.

---

## Licença

Uso pessoal. Sem licença definida.
