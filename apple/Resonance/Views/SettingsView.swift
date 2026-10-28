import SwiftUI
import PhosphorCore

struct SettingsView: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Engine", selection: $store.engine) {
                    ForEach(Engine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
            } footer: {
                Text("SIDLite picks the chip model from each tune's header. Changing the engine restarts the current tune.")
            }

            Section("Playback") {
                Toggle("Skip RSID tunes", isOn: $store.options.skipRsid)
                LabeledContent("Default song length") {
                    HStack {
                        TextField("Seconds", value: $store.options.defaultSongLengthSecs, format: .number)
                            .labelsHidden()
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("seconds")
                    }
                }
                Text("Used for tunes missing from the Songlengths database. 0 means play until silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stereo") {
                Toggle("Play 2SID tunes in mirrored stereo", isOn: $store.options.forceStereo2sid)
                Picker("Widen mono tunes", selection: $store.options.pseudoStereo) {
                    Text("Off").tag(PseudoStereo?.none)
                    ForEach(PseudoStereo.allCases, id: \.self) { strength in
                        Text(strength.displayName).tag(Optional(strength))
                    }
                }
            }

            Section {
                Button("Import Settings from Phosphor") { store.importPhosphorSettings() }
            } footer: {
                Text("Song lengths and your HVSC collection are read from Phosphor's data folder, so both apps share them.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
        .environment(PlayerStore.preview)
}
