import SwiftUI
import PhosphorCore

/// The Playback menu and the other playback commands. None is ever
/// disabled: SwiftUI only refreshes a menu item's enabled state when the
/// menu opens, so a shortcut kept the state from launch (Stop and the
/// subtune keys stayed off while music played; Surprise Me would stay off
/// after the first download). Each action does nothing when it doesn't
/// apply instead. Titles that follow the player are views of their own,
/// which refresh as the menu opens.
struct PlaybackCommands: Commands {
    let store: PlayerStore
    let library: LibraryStore

    var body: some Commands {
        // ⇧⌘F: ⌃⌘F is the system's Enter Full Screen.
        CommandGroup(before: .sidebar) {
            NowPlayingItem(store: store)
        }

        CommandGroup(replacing: .newItem) {
            Button("Add Files or Folders…") { store.isImporting = true }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .textEditing) {
            Button("Search") { store.focusSearch() }
                .keyboardShortcut("f")
        }

        CommandMenu("Playback") {
            // No Space shortcut here: a plain-key menu shortcut would swallow
            // spaces typed into the search field. SpaceKey handles Space.
            TransportItems(store: store)

            Divider()

            Button("Next Track") { store.next() }
                .keyboardShortcut(.rightArrow)
            Button("Previous Track") { store.previous() }
                .keyboardShortcut(.leftArrow)
            SubtuneItems(store: store)

            Divider()

            CollectionItems(library: library)

            Divider()

            Button("Volume Up") { store.nudgeVolume(by: 0.1) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { store.nudgeVolume(by: -0.1) }
                .keyboardShortcut(.downArrow)

            Divider()

            Toggle("Shuffle", isOn: Bindable(store).shuffle)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Repeat", selection: Bindable(store).repeatMode) {
                ForEach(Repeat.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }
}

private struct NowPlayingItem: View {
    let store: PlayerStore

    var body: some View {
        Button(store.isShowingNowPlaying ? "Hide Now Playing" : "Show Now Playing") {
            store.toggleNowPlaying()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

private struct TransportItems: View {
    let store: PlayerStore

    var body: some View {
        Button(store.isPlaying ? "Pause" : "Play") { store.playPause() }
        Button("Stop") { store.stop() }
            .keyboardShortcut(".")
    }
}

private struct SubtuneItems: View {
    let store: PlayerStore

    var body: some View {
        Button("Next Subtune") { store.nextSubtune() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        Button("Previous Subtune") { store.previousSubtune() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
    }
}

private struct CollectionItems: View {
    let library: LibraryStore

    var body: some View {
        Button("Surprise Me") {
            guard library.hasRoot else { return }
            Task { await library.surpriseMe() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Shuffle Collection") {
            guard library.hasRoot else { return }
            Task { await library.shuffleCollection() }
        }
    }
}
