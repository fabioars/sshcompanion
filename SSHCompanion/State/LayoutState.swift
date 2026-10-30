import Observation

/// Estado de layout da janela que precisa ser alcançado tanto pelo menu quanto pela toolbox.
@Observable
final class LayoutState {
    /// Modo foco: esconde a sidebar e a info bar, deixando só abas e terminal.
    var isFocusMode = false
}
