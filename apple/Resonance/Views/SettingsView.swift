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

            ThemeSettings()

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
                if !store.hasCollection, let sync = store.hvscSync, sync.running {
                    ProgressView {
                        Text(sync.current)
                            .lineLimit(1)
                    }
                } else if !store.hasCollection, store.hvscSync?.running != true {
                    Button {
                        store.startHvscSync()
                    } label: {
                        Label("Download Collection…", systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                Text("HVSC")
            } footer: {
                if store.hasCollection {
                    Text("The folder that holds MUSICIANS, GAMES and DEMOS.")
                } else {
                    Text("The folder that holds MUSICIANS, GAMES and DEMOS. With nothing in it yet, download the collection into it — by default the folder Phosphor uses.")
                }
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

/// The visualizers' colour theme: a preset or your own colours, and whether
/// its badge shows.
private struct ThemeSettings: View {
    @Environment(\.voiceTheme) private var theme
    @AppStorage(Pref.theme) private var themeID = VoiceTheme.resonance.id
    @AppStorage(Pref.customTheme) private var customData = Data()
    @AppStorage(Pref.themeBadge) private var showsBadge = true

    var body: some View {
        Section {
            Picker("Theme", selection: $themeID) {
                ForEach(VoiceTheme.presets + [VoiceTheme.custom(from: customData)]) { theme in
                    row(theme).tag(theme.id)
                }
            }
            .pickerStyle(.radioGroup)

            if themeID == VoiceTheme.customID {
                ColorPicker("Voice 1", selection: customColor(\.voices[0]), supportsOpacity: false)
                ColorPicker("Voice 2", selection: customColor(\.voices[1]), supportsOpacity: false)
                ColorPicker("Voice 3", selection: customColor(\.voices[2]), supportsOpacity: false)
                ColorPicker("Background", selection: customColor(\.background), supportsOpacity: false)
            }

            Toggle("Show theme badge", isOn: $showsBadge)
            if showsBadge {
                LabeledContent("Badge") {
                    ThemeBadgeView()
                        .frame(width: 220, height: 20)
                        .padding(6)
                        .background(theme.background.color, in: .rect(cornerRadius: 6))
                }
            }
        } header: {
            Text("Theme")
        } footer: {
            Text("Colours the three voices in every visualizer. Buttons and links keep the system accent colour.")
        }
    }

    private func row(_ theme: VoiceTheme) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(theme.voice(i)).frame(width: 10, height: 10)
                }
            }
            Text(theme.name)
            Text(theme.summary)
                .foregroundStyle(.secondary)
        }
    }

    private func customColor(_ keyPath: WritableKeyPath<VoiceTheme, RGB>) -> Binding<Color> {
        Binding {
            VoiceTheme.custom(from: customData)[keyPath: keyPath].color
        } set: { color in
            var custom = VoiceTheme.custom(from: customData)
            custom[keyPath: keyPath] = RGB(color)
            customData = custom.encoded
        }
    }
}

#Preview {
    SettingsView()
        .environment(PlayerStore.preview)
}
