# CLAUDE.md

Guia para o Claude Code trabalhar neste repositório.

## Visão geral

Aplicação nativa para **macOS** cujo objetivo é gerenciar e se conectar a servidores remotos via **SSH**. O usuário cadastra servidores, organiza-os em uma hierarquia (workspaces e diretórios) e abre sessões de terminal em abas.

Estado atual: a funcionalidade descrita abaixo está implementada (spec em `.scratch/ssh-companion-core/spec.md`). Dependências SPM: SwiftTerm (emulador) e libsql-swift (persistência).

## Stack

- **Linguagem:** Swift
- **UI:** SwiftUI (macOS)
- **Concorrência:** Swift `async`/`await`. Não usar Combine.
- **Testes:** framework `Testing` para unitários; `XCUIAutomation` para testes de UI.
- **Targets:** `SSHCompanion` (app), `SSHCompanionTests` (unitários), `SSHCompanionUITests` (UI). Projeto `SSHCompanion.xcodeproj`, com grupos sincronizados: arquivos novos dentro das pastas dos targets entram automaticamente.

## Layout da interface

A janela principal tem três regiões:

### 1. Toolbar (topo)

Três ações, nesta ordem:

| Ação       | Ícone (SF Symbol) | Comportamento                                                                                |
| ---------- | ----------------- | -------------------------------------------------------------------------------------------- |
| Adicionar  | `plus`            | Cria um novo item (workspace, diretório ou servidor) no contexto da seleção atual na árvore. |
| Editar     | `pencil`          | Abre a edição do item selecionado na árvore.                                                 |
| Recarregar | `arrow.clockwise` | Recarrega a lista de servidores a partir da fonte de dados.                                  |

### 2. Sidebar (lateral esquerda)

Uma **tree view** (`List` com `OutlineGroup` ou `children:`) exibindo os servidores configurados. A hierarquia é fixa:

```
Workspace
└── Diretório
    └── Diretório (aninhamento livre)
        └── Server
```

Regras:

- **Workspace** é sempre o nó raiz. Contém diretórios e/ou servidores.
- **Diretório** pode conter outros diretórios e servidores, em qualquer profundidade.
- **Server** é sempre folha. Não contém filhos.
- Selecionar um servidor e ativá-lo (duplo clique ou Enter) abre uma nova aba de terminal conectada a ele.

### 3. Área central (terminal)

Um `TabView` (ou controle de abas customizado) em que cada aba representa uma **sessão SSH ativa** com um servidor. Cada aba exibe um emulador de terminal conectado à sessão. Fechar a aba encerra a conexão.

## Modelo de dados (direção)

Tipos esperados no domínio. Nomes podem ser ajustados, mas a hierarquia deve ser respeitada:

- `Workspace` — `id`, `name`, `children: [TreeItem]`
- `Directory` — `id`, `name`, `children: [TreeItem]`
- `Server` — `id`, `name`, `host`, `port` (padrão 22), `username`, método de autenticação (senha ou chave)
- `TreeItem` — enum ou protocolo que unifica `Directory` e `Server` para uso na árvore.

Credenciais sensíveis (senhas, passphrases) devem ser guardadas no **Keychain**, nunca em arquivo de configuração em texto puro.

## Estrutura de pastas sugerida

```
SSHCompanion/
├── SSHCompanionApp.swift  # @main, cena principal e menu "Sessão"
├── Models/                # Workspace, Directory, Server, TreeItem, TreeSelection
├── Services/
│   ├── Persistence/       # ServerRepository (protocolo), InMemory e LibSQL
│   ├── Keychain/          # CredentialStore (protocolo), InMemory e Keychain
│   └── SSH/               # SSHConnector (protocolo), PromptResponder, ProcessSSHConnector (PTY)
├── State/                 # ServerStore, SessionManager, ItemFormModel, AppEnvironment
├── Views/
│   ├── ContentView.swift  # NavigationSplitView: sidebar + área central
│   ├── Sidebar/           # Tree view dos servidores
│   ├── Terminal/          # Abas e emulador de terminal (SwiftTerm)
│   ├── Toolbar/           # Ações Adicionar / Editar / Recarregar
│   └── Forms/             # Formulário de criar/editar
└── Assets.xcassets
```

## Convenções de código

- **Nomes:** `PascalCase` para tipos, `camelCase` para propriedades e métodos.
- **Estado SwiftUI:** `@State private var` para estado local; `let` para constantes.
- **Views:** conformar a `View`, UI definida em `body`.
- **Formatação:** indentação de 4 espaços, métodos claramente separados.
- **Imports:** simples e no topo do arquivo (`SwiftUI`, `Foundation`, etc.).
- **Tipos:** usar o sistema de tipos do Swift; evitar force unwrap (`!`).
- **Arquitetura:** padrões SwiftUI com separação clara de responsabilidades (models, services, views). Preferir `@Observable` para estado compartilhado.
- **Comentários:** apenas para lógica complexa ou não óbvia.
- **Idioma:** textos de UI em português; identificadores de código em inglês.

## Escopo das alterações

Limitar as mudanças ao que foi pedido. Ao adicionar uma feature, não refatorar ou alterar partes não relacionadas do projeto.

## Como validar

Usar as ferramentas do servidor MCP `xcode-tools` em vez de linha de comando:

- `BuildProject` — build completo. Usar para confirmar que o projeto compila.
- `XcodeRefreshCodeIssuesInFile` — diagnósticos rápidos de um arquivo Swift. Usar após cada edição antes de um build completo.
- `RunCodeSnippet` — executar trechos de código no contexto de um arquivo para experimentar ideias.
- `RunProject` / `DeviceInteraction*` — rodar o app e verificar a interface.
- `DocumentationSearch` — consultar documentação atualizada da Apple antes de usar APIs de SwiftUI que possam ter mudado (ex.: toolbars, `NavigationSplitView`, Liquid Glass).

Arquivos do projeto devem ser lidos e escritos com `XcodeRead` / `XcodeWrite` para que novos arquivos sejam adicionados automaticamente ao target.

## Decisões tomadas (2026-10-30)

- **SSH:** binário `/usr/bin/ssh` lançado em um pseudo-terminal (`forkpty` via helper do SwiftTerm). Honra `~/.ssh/config` e ssh-agent. Senha/passphrase são injetadas por detecção de prompt (`PromptResponder`).
- **Emulador de terminal:** SwiftTerm, embrulhado em `NSViewRepresentable`.
- **Persistência:** libSQL (`libsql-swift`) em `~/Library/Application Support/SSHCompanion/config.db`. Segredos no Keychain.
- **App Sandbox desativado:** o `ssh` precisa ler `~/.ssh` e abrir conexões de rede.
- **Seams de teste:** `ServerStore` (repositório e Keychain injetados) e `SessionManager` (`SSHConnector` injetado). Na linha de comando, o build exige `-skipPackagePluginValidation` por causa do build plugin do SwiftTerm. O argumento `--ui-testing` troca as dependências por versões em memória.

## Tabelas em Markdown

Sempre usar pipes no início e no fim de cada linha (`| Nome | Idade |`).
