import Foundation
import PhosphorCore

/// Shared tune links on their way to the terminal app. While Resonance runs
/// headless there's no window to ask in, so a link waits here. The control
/// socket only answers questions, so nothing is pushed: the terminal app
/// finds the link in its next `status` answer, asks what to do with it, and
/// says so with `link.answer`.
final class TerminalLinks {
    static let shared = TerminalLinks()

    /// What the terminal app shows.
    struct Offer: Encodable, Equatable {
        let id: Int
        let title: String
        let author: String
        /// Why this collection can't play it, if it can't.
        let problem: String?
    }

    struct Waiting {
        let link: SharedTuneLink
        /// The tune in this collection, if it's there.
        let path: String?
        let offer: Offer
    }

    /// The terminal app asks for `status` twice a second (STATUS_EVERY in
    /// cli/src/tui.rs) and waits for each answer; four in a row missing
    /// means it has gone.
    private let gone: Duration

    init(gone: Duration = .seconds(2)) {
        self.gone = gone
    }

    private(set) var waiting: Waiting?
    /// On a clock that stops while the Mac sleeps, so waking up doesn't
    /// look like the terminal app having gone.
    private var lastAsked: SuspendingClock.Instant?
    private var nextID = 1

    /// A terminal app that shows links is open.
    var isWatched: Bool {
        lastAsked.map { .now - $0 < gone } ?? false
    }

    /// A terminal app was open, and no longer is: it didn't get to say so
    /// (its window was closed, or it was killed).
    var hasGone: Bool {
        lastAsked != nil && !isWatched
    }

    /// The terminal app asked for `status`, links and all.
    func asked() {
        lastAsked = .now
    }

    /// Hold `link` for the terminal app. If that closes before answering,
    /// `unanswered` gets the link, for the app to ask about itself. A link
    /// that arrives while another waits takes its place.
    func offer(_ link: SharedTuneLink, player: PlayerStore, unanswered: @escaping (SharedTuneLink) -> Void) async {
        let (outcome, _) = await player.resolve(link)
        var path: String?
        if case .play(let found, _, _) = outcome { path = found }
        var item: HvscTuneItem?
        if let path { item = await player.core.tunesFromFiles(paths: [path]).first }
        let id = nextID
        nextID += 1
        waiting = Waiting(link: link, path: path, offer: Offer(
            id: id,
            title: item?.title ?? link.title ?? "A shared tune",
            author: item?.author ?? link.author ?? "",
            problem: ControlCommands.problem(outcome)
        ))
        Log.sharing.notice("A shared tune link is waiting for the terminal app")
        while waiting?.offer.id == id, !Task.isCancelled {
            try? await Task.sleep(for: gone / 2)
            if waiting?.offer.id == id, !isWatched {
                waiting = nil
                Log.sharing.notice("The terminal app closed before answering a shared tune link")
                unanswered(link)
            }
        }
    }

    /// The link the terminal app is answering, which stops waiting.
    func take(_ id: Int?) -> Waiting? {
        guard let found = waiting, found.offer.id == id else { return nil }
        waiting = nil
        return found
    }
}
