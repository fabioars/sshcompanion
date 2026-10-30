import SwiftUI

struct MainToolbar: ToolbarContent {
    let canEdit: Bool
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onReload: () -> Void
    let inspectorShown: Bool
    let onToggleInspector: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: onAdd) {
                Label("Adicionar", systemImage: "plus")
            }
            .help("Adicionar workspace, diretório ou servidor")
            .accessibilityIdentifier("toolbar.add")

            Button(action: onEdit) {
                Label("Editar", systemImage: "pencil")
            }
            .help("Editar o item selecionado")
            .disabled(!canEdit)
            .accessibilityIdentifier("toolbar.edit")

            Button(action: onReload) {
                Label("Recarregar", systemImage: "arrow.clockwise")
            }
            .help("Recarregar a lista de servidores")
            .accessibilityIdentifier("toolbar.reload")
        }
        // Separado das ações principais: fica na extremidade direita, no espaço do inspector.
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button(action: onToggleInspector) {
                Label("Painel lateral", systemImage: "sidebar.trailing")
            }
            .help(inspectorShown ? "Ocultar histórico e anotações" : "Mostrar histórico e anotações")
            .accessibilityIdentifier("toolbar.inspector")
        }
    }
}
