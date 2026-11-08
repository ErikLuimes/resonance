import AppKit
import PhosphorCore
import SwiftUI

// MARK: Sharing a tune

/// Share…: a popover with the tune's link, Copy Link, Messages, Mail and
/// the system's share menu. Not shown when sharing is off (no share server
/// in this build).
struct ShareButton: View {
    let path: String
    /// nil: the tune's start song.
    var subtune: Int?

    @State private var showing = false

    var body: some View {
        if SharedTuneLink.shareBase != nil {
            Button("Share…", systemImage: "square.and.arrow.up") { showing = true }
                .help("Share a link to this tune")
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    SharePopover(path: path, subtune: subtune) { showing = false }
                }
        }
    }
}

private struct SharePopover: View {
    let path: String
    let subtune: Int?
    let done: () -> Void

    @Environment(PlayerStore.self) private var store
    @State private var share: PreparedShare?
    @State private var looked = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let share {
                VStack(alignment: .leading, spacing: 2) {
                    Text(share.title).font(.headline).lineLimit(1)
                    Text(subtitle(share)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(share.url.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                Text("People with Resonance open it straight in the app; others see the tune's card and a download link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy Link") {
                        ShareActions.copy(share)
                        copied = true
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Messages") { ShareActions.perform(.composeMessage, share); done() }
                    Button("Mail") { ShareActions.perform(.composeEmail, share); done() }
                    ShareLink("More…", item: share.url, subject: Text(share.subject), message: Text(share.subject))
                }
            } else if looked {
                Text("Only tunes from HVSC can be shared.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380)
        .task {
            share = await store.prepareShare(path: path, subtune: subtune)
            looked = true
        }
    }

    private func subtitle(_ share: PreparedShare) -> String {
        [share.author, subtune.map { String(localized: "subtune \($0)") }].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// Share, for context menus: the same actions as the popover's, the link
/// made when one is picked.
struct ShareMenu: View {
    let path: String

    @Environment(PlayerStore.self) private var store

    var body: some View {
        if SharedTuneLink.shareBase != nil {
            Menu("Share") {
                Button("Copy Link") { run { ShareActions.copy($0) } }
                Button("Messages") { run { ShareActions.perform(.composeMessage, $0) } }
                Button("Mail") { run { ShareActions.perform(.composeEmail, $0) } }
            }
        }
    }

    private func run(_ action: @escaping (PreparedShare) -> Void) {
        Task {
            if let share = await store.prepareShare(path: path) {
                action(share)
            } else {
                NSSound.beep()
            }
        }
    }
}

enum ShareActions {
    static func copy(_ share: PreparedShare) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([share.url as NSURL])
        pasteboard.setString(share.url.absoluteString, forType: .string)
    }

    /// Messages or Mail, with the link (and for Mail a subject).
    static func perform(_ name: NSSharingService.Name, _ share: PreparedShare) {
        guard let service = NSSharingService(named: name) else { return }
        service.subject = share.subject
        service.perform(withItems: name == .composeEmail ? [share.subject, share.url] : [share.url])
    }
}

// MARK: Opening a shared tune

/// The sheet a shared link opens: the tune, found in this collection or
/// not, and the one thing to do about it (Play, Update to HVSC 85, Check
/// for Update, Download HVSC).
struct SharedTuneSheet: View {
    let link: SharedTuneLink

    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: SharedTuneOutcome?
    @State private var match: SharedTuneMatch?
    @State private var tune: HvscTuneItem?
    @State private var checking = false
    /// Waiting for an update or download to finish, then looking again.
    @State private var downloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shared Tune")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(2)
                if let author { Text(author).font(.title3).foregroundStyle(.secondary).lineLimit(1) }
                Text(origin).font(.callout).foregroundStyle(.secondary)
            }
            if downloading {
                downloadProgress
            } else if let outcome {
                message(outcome)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(outcome)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(22)
        .frame(width: 440, alignment: .leading)
        .task { await look() }
        .onChange(of: store.hvscSync?.running) { _, running in
            guard downloading, running == false else { return }
            downloading = false
            Task { await look() }
        }
    }

    // MARK: Text

    private var title: String { tune?.title ?? link.title ?? String(localized: "A shared tune") }
    private var author: String? { tune?.author ?? link.author }

    private var origin: String {
        var parts = [link.hvsc.map { String(localized: "Shared from HVSC \(String($0))") } ?? String(localized: "Shared from HVSC")]
        if let subtune = link.subtune { parts.append(String(localized: "subtune \(subtune)")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func message(_ outcome: SharedTuneOutcome) -> some View {
        switch outcome {
        case .play(_, let sameFile, let offer):
            VStack(alignment: .leading, spacing: 6) {
                if !sameFile {
                    Text("Your collection has another version of this file; it may sound a little different.")
                        .foregroundStyle(.secondary)
                }
                if let offer {
                    HStack(spacing: 4) {
                        Text("You have HVSC \(installed).")
                            .foregroundStyle(.secondary)
                        Button("Update to HVSC \(offer)") { update() }
                            .buttonStyle(.link)
                    }
                }
            }
        case .update(let to):
            Text("This tune isn't in your HVSC \(installed). HVSC \(to) should have it.")
        case .checkForUpdate(let sender):
            Text("This tune is from HVSC \(sender), newer than your HVSC \(installed) and than the newest release Resonance has seen.")
        case .download:
            Text("Resonance plays tunes from HVSC, the High Voltage SID Collection. Download it (it's free) to play this tune.")
        case .notFound:
            Text("This tune isn't in your collection, and there's no newer HVSC release to get it from.")
        }
    }

    private var installed: String {
        match?.installedHvsc.map(String.init) ?? store.installedHvsc.map(String.init) ?? "?"
    }

    // MARK: Actions

    @ViewBuilder
    private func buttons(_ outcome: SharedTuneOutcome) -> some View {
        HStack {
            if case .play(let path, _, _) = outcome {
                Button("Show in Library") {
                    library.reveal(tunePath: path)
                    store.isShowingNowPlaying = false
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            switch outcome {
            case .play(let path, _, _):
                Button("Play") {
                    store.playShared(path: path, subtune: link.subtune)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            case .update(let to):
                Button("Update to HVSC \(to)") { update() }
                    .keyboardShortcut(.defaultAction)
            case .checkForUpdate:
                Button(checking ? String(localized: "Checking…") : String(localized: "Check for Update")) {
                    Task {
                        checking = true
                        await store.checkHvscUpdate()
                        checking = false
                        await look()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checking)
            case .download:
                Button("Download HVSC") { update() }
                    .keyboardShortcut(.defaultAction)
            case .notFound:
                EmptyView()
            }
        }
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sync = store.hvscSync, sync.running {
                let total = sync.filesTotal > 0 ? Double(sync.filesTotal) : Double(sync.bytesTotal)
                let done = sync.filesTotal > 0 ? Double(sync.filesDone) : Double(sync.bytesDone)
                if total > 0 {
                    ProgressView(value: min(done, total), total: total)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(sync.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let error = store.hvscSyncError ?? store.hvscSync?.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("The download carries on if you close this; open the link again when it's done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Download the newest release (or the collection), then look again.
    private func update() {
        store.startHvscSync()
        downloading = true
    }

    private func look() async {
        // The mirror's newest release decides between Update and Check.
        if store.latestHvsc == nil, store.hasCollection {
            await store.checkHvscUpdate()
        }
        let (outcome, match) = await store.resolve(link)
        self.match = match
        if let path = match.path {
            tune = await store.core.tunesFromFiles(paths: [path]).first
        }
        self.outcome = outcome
    }
}
