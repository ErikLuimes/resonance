import SwiftUI

/// The keyboard help, opened with ?: every shortcut on a glass panel over a
/// dimmed window, with one line for what the selected one does. The keys keep
/// working, so one can be tried from here. `AppKeys` handles them, and moves
/// the selection.
struct KeyboardHelpOverlay: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(.rect)
                .onTapGesture { store.isShowingKeyHelp = false }
                .accessibilityHidden(true)
            KeyboardHelpPanel()
                .padding(24)
        }
    }
}

struct KeyboardHelpPanel: View {
    @Environment(PlayerStore.self) private var store
    @AppStorage(Pref.keyScheme) private var scheme = KeyScheme.normal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Picker("Key set", selection: $scheme) {
                    ForEach(KeyScheme.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .fixedSize()
                .help("Press Tab to change the key set")
            }

            HStack(alignment: .top, spacing: 22) {
                ForEach(KeyAction.columns, id: \.title) { column in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(column.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                        ForEach(column.actions, id: \.self) { action in
                            KeyHelpRow(action: action, scheme: scheme)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            HStack(spacing: 16) {
                Text(store.keyHelpSelection.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
                AccentLink(String(localized: "Open Resonance Help")) { AppKeys.activate(.help) }
                    .fixedSize()
            }
            .font(.callout)
        }
        .padding(18)
        .frame(width: 720)
        // Tinted with the window's color, so the small text stays readable
        // over a busy list.
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.7)), in: .rect(cornerRadius: 22))
        // Clicks on the panel don't reach the dimming behind it.
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture {}
        .accessibilityAddTraits(.isModal)
    }
}

private struct KeyHelpRow: View {
    @Environment(PlayerStore.self) private var store
    let action: KeyAction
    let scheme: KeyScheme

    private var isSelected: Bool { store.keyHelpSelection == action }

    var body: some View {
        HStack(spacing: 6) {
            title
                .lineLimit(1)
            Spacer(minLength: 4)
            Keycap(keys: action.binding(in: scheme).label)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.22))
            }
        }
        .contentShape(.rect)
        .onHover { if $0 { store.keyHelpSelection = action } }
        .onTapGesture { AppKeys.activate(action) }
        .accessibilityElement(children: .combine)
        .accessibilityHint(action.summary)
    }

    /// What it does right now, where that changes.
    @ViewBuilder private var title: some View {
        switch action {
        case .playPause:
            Text(store.isPlaying ? "Pause" : "Play")
        case .shuffle:
            HStack(spacing: 4) {
                Text(action.title)
                Text(store.shuffle ? "On" : "Off").foregroundStyle(.tint)
            }
        default:
            Text(action.title)
        }
    }
}
