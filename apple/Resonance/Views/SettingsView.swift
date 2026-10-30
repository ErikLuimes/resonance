import SwiftUI
import PhosphorCore

struct SettingsView: View {
    @Environment(PlayerStore.self) private var store
    @State private var choosingHvscFolder = false

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

            Section {
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
            } header: {
                Text("Playback")
            } footer: {
                Text("The default length is used for tunes missing from the Songlengths database. 0 means play until silence.")
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
                LabeledContent("Collection folder") {
                    Text(store.hvscRoot.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                        .foregroundStyle(store.hvscRoot == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { choosingHvscFolder = true }
                    Button("Use Phosphor's") { store.usePhosphorHvscRoot() }
                }
            } header: {
                Text("HVSC")
            } footer: {
                Text("The folder that holds MUSICIANS, GAMES and DEMOS.")
            }

            Section {
                Button("Import Settings from Phosphor") { store.importPhosphorSettings() }
            } footer: {
                Text("Song lengths and your HVSC collection are read from Phosphor's data folder, so both apps share them.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingHvscFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.hvscRoot = url.path
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
        .environment(PlayerStore.preview)
}
