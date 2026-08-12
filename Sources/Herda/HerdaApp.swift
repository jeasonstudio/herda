import HerdaKit
import SwiftUI

@main
struct HerdaApp: App {
    /// Owned here rather than in `ContentView` because the menu commands need the
    /// same instance. Panes are created and destroyed from the menu bar now that
    /// herdr's own keybindings are not in the picture.
    @StateObject private var session = TerminalSession()

    var body: some Scene {
        // No titlebar: the theme's own background runs to the top edge, and the
        // sidebar keeps the top-left clear for the traffic lights.
        WindowGroup("Herda") {
            ContentView(session: session)
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            EditCommands(session: session)
            PaneCommands(session: session)
        }
    }
}

/// Copy, Paste and Select All, in the Edit menu where a Mac user looks for them.
///
/// Replacing the pasteboard group rather than handling these in `keyDown`: a menu
/// key equivalent is dispatched before the view sees the key, so doing both would
/// either fire twice or shadow the menu item — and an item that exists but does
/// nothing is worse than no item.
struct EditCommands: Commands {
    @ObservedObject var session: TerminalSession

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") { session.copySelection() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!session.hasSelection)
            Button("Paste") { session.pasteIntoFocused() }
                .keyboardShortcut("v", modifiers: .command)
            Divider()
            Button("Select All") { session.selectAllInFocused() }
                .keyboardShortcut("a", modifiers: .command)
        }
    }
}

/// The pane menu.
///
/// This is the only way to change the layout. With no app render connection there
/// is no prefix key and no herdr keybinding layer, so anything not here cannot be
/// done at all — which is also why every item carries a shortcut, per the macOS
/// rule that whatever is reachable by mouse needs a keyboard equivalent.
struct PaneCommands: Commands {
    @ObservedObject var session: TerminalSession

    var body: some Commands {
        CommandMenu("Pane") {
            Button("Split Right") { session.splitFocused(.right) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { session.splitFocused(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            // Cmd+W on the pane rather than the window, which is what terminal
            // apps do — Terminal.app and iTerm both put close-tab here and move
            // close-window to Cmd+Shift+W.
            Button("Close Pane") { session.closeFocused() }
                .keyboardShortcut("w", modifiers: .command)
            Button(session.tree.zoomedPaneId == nil ? "Zoom Pane" : "Unzoom Pane") {
                session.toggleZoomFocused()
            }
            .keyboardShortcut(.return, modifiers: [.command, .control])

            Divider()

            Button("Focus Left") { session.focusNeighbour(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Right") { session.focusNeighbour(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Up") { session.focusNeighbour(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Down") { session.focusNeighbour(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
