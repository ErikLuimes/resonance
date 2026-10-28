import SwiftUI
import PhosphorCore

struct PlaybackCommands: Commands {
    let store: PlayerStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files or Folders…") { store.isImporting = true }
                .keyboardShortcut("o")
        }

        CommandMenu("Playback") {
            // No Space shortcut here: a plain-key menu shortcut would swallow
            // spaces typed into the search field. The playlist handles Space.
            Button(store.isPlaying ? "Pause" : "Play") { store.playPause() }
            Button("Stop") { store.stop() }
                .keyboardShortcut(".")
                .disabled(store.state == .stopped)

            Divider()

            Button("Next Track") { store.next() }
                .keyboardShortcut(.rightArrow)
            Button("Previous Track") { store.previous() }
                .keyboardShortcut(.leftArrow)
            Button("Next Subtune") { store.nextSubtune() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!store.hasSubtunes)
            Button("Previous Subtune") { store.previousSubtune() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!store.hasSubtunes)

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
