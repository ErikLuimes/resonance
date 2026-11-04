import SwiftUI

/// Resonance Help: the topics in a sidebar, grouped, and the chosen one's
/// article beside them. The search field keeps the topics that have every
/// word typed. Opened from Help → Resonance Help (⌘?).
struct HelpView: View {
    static let windowID = "help"

    @State private var selection: HelpTopic.ID? = .gettingStarted
    @State private var search = ""

    private var shown: [HelpTopic] { HelpTopic.all.filter { $0.matches(search) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(HelpTopic.Group.allCases, id: \.self) { group in
                    let topics = shown.filter { $0.group == group }
                    if !topics.isEmpty {
                        Section(group.rawValue) {
                            ForEach(topics) { topic in
                                Label(topic.title, systemImage: topic.symbol)
                                    .tag(topic.id)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if let selection {
                HelpArticle(topic: .topic(selection)) { link in
                    // A related topic shows even when the search left it out.
                    search = ""
                    self.selection = link
                }
            }
        }
        // Constant, like the main window's toolbar.
        .searchable(text: $search, placement: .sidebar, prompt: "Search Help")
        // A search that leaves the shown topic out moves to its first match.
        .onChange(of: search) {
            if let first = shown.first, !shown.contains(where: { $0.id == selection }) {
                selection = first.id
            }
        }
    }
}

/// One topic: its title, then its blocks, then the topics related to it.
private struct HelpArticle: View {
    let topic: HelpTopic
    let open: (HelpTopic.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .padding(.bottom, 6)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block, open: open)
                }
                if !topic.related.isEmpty {
                    Divider()
                        .padding(.top, 10)
                    HStack(spacing: 14) {
                        Text("Related")
                            .foregroundStyle(.secondary)
                        ForEach(topic.related, id: \.self) { id in
                            AccentLink(HelpTopic.topic(id).title) { open(id) }
                        }
                    }
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Each topic starts at its top.
        .id(topic.id)
    }

    /// The topic's symbol on the HVSC collection row's gradient, its title
    /// and what it's about.
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: topic.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 155 / 255, green: 107 / 255, blue: 1.0),
                            Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255),
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    in: .rect(cornerRadius: 11)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .font(.title2.weight(.bold))
                Text(topic.summary)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock
    let open: (HelpTopic.ID) -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)
        case .paragraph(let text):
            Text(markdown(text))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(marker: "•", item)
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    row(marker: "\(index + 1).", item)
                }
            }
        case .note(let title, let text, let link):
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                Text(markdown(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    linkButton(link)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        case .shortcuts(let shortcuts):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                ForEach(shortcuts, id: \.self) { shortcut in
                    GridRow {
                        Keycap(keys: shortcut.keys)
                            .gridColumnAlignment(.trailing)
                        Text(shortcut.action)
                    }
                }
            }
            .padding(.vertical, 4)
        case .link(let link):
            linkButton(link)
        }
    }

    private func row(marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 14, alignment: .trailing)
            Text(markdown(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linkButton(_ link: HelpLink) -> some View {
        AccentLink(link.title) {
            switch link {
            case .settings(let tab):
                // Settings shows the tab it remembers.
                UserDefaults.standard.set(tab.rawValue, forKey: Pref.settingsTab)
                openSettings()
            case .topic(let id):
                open(id)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// A shortcut's keys, set like a key on the keyboard.
private struct Keycap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: 26)
            .background(.fill.tertiary, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

/// The Help menu: Resonance Help, and the website and issue tracker.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            HelpButton()
            Divider()
            Link("Resonance Website", destination: URL(string: "https://erikluimes.github.io/resonance/")!)
            Link("Report a Problem", destination: URL(string: "https://github.com/ErikLuimes/resonance/issues")!)
        }
    }

    private struct HelpButton: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Resonance Help") { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

#Preview {
    HelpView()
        .frame(width: 860, height: 600)
}
