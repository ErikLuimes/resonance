import Foundation

/// Resonance Help's articles: what the Help window shows, in the order of
/// its sidebar. Plain data, so the text can be searched and tested. Inline
/// `**bold**` and `*italic*` are Markdown.
struct HelpTopic: Identifiable, Hashable {
    enum ID: String, CaseIterable {
        case gettingStarted, soundsLike
        case library, nowPlaying, visualizers
        case playlists, favourites, dragAndDrop
        case shortcuts, settings, troubleshooting
    }

    enum Group: String, CaseIterable {
        case start = "Start Here"
        case listening = "Listening"
        case yourMusic = "Your Music"
        case reference = "Reference"
    }

    let id: ID
    let group: Group
    let title: String
    let symbol: String
    let summary: String
    let blocks: [HelpBlock]
    let related: [ID]

    /// Every word of `query` appears in the topic, ignoring case and
    /// accents. An empty query matches everything.
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { searchText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The topic's words, without Markdown's asterisks.
    var searchText: String {
        ([title, summary] + blocks.flatMap(\.text))
            .joined(separator: " ")
            .replacingOccurrences(of: "*", with: "")
    }

    static func topic(_ id: ID) -> HelpTopic {
        all.first { $0.id == id }!
    }
}

enum HelpBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    /// Numbered steps.
    case steps([String])
    /// Set off in a card, with an optional link below it.
    case note(title: String, text: String, link: HelpLink? = nil)
    /// Keys and what they do.
    case shortcuts([HelpShortcut])
    case link(HelpLink)

    var text: [String] {
        switch self {
        case .heading(let text), .paragraph(let text): [text]
        case .bullets(let items), .steps(let items): items
        case .note(let title, let text, _): [title, text]
        case .shortcuts(let shortcuts): shortcuts.flatMap { [$0.keys, $0.action] }
        case .link: []
        }
    }
}

struct HelpShortcut: Hashable {
    let keys: String
    let action: String
}

/// A link in an article: to a tab of Settings, or another topic.
enum HelpLink: Hashable {
    case settings(SettingsTab)
    case topic(HelpTopic.ID)

    var title: String {
        switch self {
        case .settings(let tab): "Open Settings → \(tab.title)"
        case .topic(let id): HelpTopic.topic(id).title
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .playback: "Playback"
        case .appearance: "Appearance"
        case .collection: "Collection"
        case .history: "History"
        case .advanced: "Advanced"
        }
    }
}

extension HelpTopic {
    static let all: [HelpTopic] = [
        HelpTopic(
            id: .gettingStarted, group: .start,
            title: "Getting Started", symbol: "arrow.down.circle",
            summary: "Get the High Voltage SID Collection, and start listening.",
            blocks: [
                .paragraph("Resonance plays Commodore 64 music: SID tunes, through the same emulation engine as Phosphor. Its library is the High Voltage SID Collection (HVSC), about 60,000 tunes by thousands of composers."),
                .heading("Get the collection"),
                .steps([
                    "In the sidebar, under HVSC, click **Download** next to **Collection**. Resonance fetches the newest HVSC release from an HVSC mirror and unpacks it, into the folder Phosphor uses.",
                    "Follow the download on the Home, which the Collection row opens. Elsewhere in the window a pill at the top shows it, with **Cancel**.",
                    "Once it's in, the Home shows the release: what's new, the three sections to browse (Musicians, Games and Demos) and the curated playlists.",
                ]),
                .paragraph("Already have HVSC? Resonance finds Phosphor's copy by itself. For a copy somewhere else, choose its folder (the one that holds MUSICIANS, GAMES and DEMOS) in Settings → Collection."),
                .link(.settings(.collection)),
                .heading("Sound fingerprints"),
                .paragraph("Sounds Like, the Sound column and the Sound filters need each tune's fingerprint. The first time, Resonance downloads the published fingerprint set (about 37 MB), which covers all of HVSC, and a background scan fills in whatever it doesn't have. A full scan of your own takes a few hours; with the published set it's mostly done in a minute."),
                .heading("Start listening"),
                .bullets([
                    "Press **⇧⌘R** for **Surprise Me**: a radio of random tunes from all of HVSC.",
                    "Double-click any tune in a list to play it.",
                    "Drop SID files, folders or M3U playlists onto the window, or press **⌘O**. They go into My Playlist.",
                ]),
            ],
            related: [.soundsLike, .library, .settings]
        ),
        HelpTopic(
            id: .soundsLike, group: .start,
            title: "Sounds Like", symbol: "waveform.badge.magnifyingglass",
            summary: "Find the tunes in HVSC that sound most like the one you love.",
            blocks: [
                .paragraph("Resonance plays every tune in the collection silently in the background and learns how it sounds: its waveforms, its arpeggios and filter sweeps, its drums and its bass. That fingerprint is what it compares, across all of HVSC."),
                .heading("What sounds like this?"),
                .bullets([
                    "Play a tune. The inspector's **Sounds Like** card shows its fingerprint as a sphere, its sound in a sentence, and the closest tunes, each with how alike it is as a percentage.",
                    "Click a match to show it in the library, or click **Play These** to play them all, most alike first.",
                    "Until the scan has reached the tune, the card says how far the scan has got.",
                ]),
                .heading("In any tune list"),
                .bullets([
                    "The **Sound** column shows each tune's fingerprint as a barcode. Hover it for a card with the tune's sphere and sound, to play it or find similar tunes.",
                    "Control-click a tune and choose **Find Similar** to sort the list by how alike the others sound to it. Click **Clear** above the list, or sort by a column, to undo it.",
                    "The **Sound** chips above a list keep only the tunes that have all the sounds you pick: Arpeggios, Filter sweeps, Noise drums, Ring mod, Sync leads and Digi samples.",
                ]),
                .heading("Composers who sound alike"),
                .paragraph("Open a composer in Musicians: their card names the three composers who sound most like them, each a link to their tunes."),
                .note(title: "Not fingerprinted yet?",
                      text: "Settings → Collection shows how far the scan has got, and lets you pause it or download the published set again. The scan runs at low priority and picks up where it left off.",
                      link: .settings(.collection)),
            ],
            related: [.gettingStarted, .library, .nowPlaying]
        ),
        HelpTopic(
            id: .library, group: .listening,
            title: "Library and Search", symbol: "books.vertical",
            summary: "Browse HVSC by composer, game or demo, and find any tune by typing.",
            blocks: [
                .heading("The sidebar"),
                .bullets([
                    "**Recently Played**: the last 100 different tunes you played, shared with Phosphor.",
                    "**Playlists**: Favourites, My Playlist and your own playlists.",
                    "**HVSC**: the Collection row opens the Home; **Musicians**, **Games** and **Demos** list the collection's composers and folders, with their tune counts and years.",
                    "**Curated Playlists**: HVSC's own lists, from the Top 100 to the Grand Tour.",
                ]),
                .paragraph("Select a composer to see their card and their tunes: **Play**, **Shuffle** or **Add to…** takes them all. Composers without a folder of their own still get a list of the tunes credited to them."),
                .heading("Search"),
                .paragraph("Type in the search field at the top of the window. In Musicians, Games or Demos it searches that section, or all of HVSC: composers come first, then tunes."),
                .bullets([
                    "Handles and real names, in any order: “tel jeroen”.",
                    "The most prolific first: “jeroen” puts Jeroen Tel on top.",
                    "Spelled either way: “second reality” finds 2nd Reality.",
                    "Accents are optional: “hulsbeck” finds Hülsbeck. Small typos still find their tune.",
                    "Press Return to open the first composer it found.",
                ]),
                .paragraph("Anywhere else, the search filters the list you're looking at, and **Search all of HVSC** appears above it (Return does the same)."),
                .note(title: "The first search takes a moment",
                      text: "The first search in a section builds an index of the collection; after that, searches are instant. Phosphor shares the index."),
                .heading("Tune lists"),
                .bullets([
                    "Double-click a tune to play it; the list plays on from there.",
                    "Click a column header to sort. Control-click the header to choose which columns show.",
                    "Control-click a tune to play it, add it to a playlist, find similar tunes or show it in Finder.",
                ]),
                .heading("The inspector"),
                .paragraph("The column on the right (toggle it with **Inspector** in the toolbar) shows what's playing: the voices of the chip, Sounds Like, the tune's details, STIL's notes and stories about it, its composer, and HVSC's known bugs when the tune has any. Where the tune came from — “Playing from Rob Hubbard” — is a link back to it."),
            ],
            related: [.soundsLike, .playlists, .shortcuts]
        ),
        HelpTopic(
            id: .nowPlaying, group: .listening,
            title: "Now Playing", symbol: "play.rectangle",
            summary: "Turn the window into a player with a big visualizer.",
            blocks: [
                .paragraph("Press **⇧⌘F**, or click the tune's title or the button at the right end of the bar at the bottom of the window, and Now Playing slides up over the library: the tune, its composer, where it's playing from, and a large visualizer driven by the SID chip's own registers."),
                .bullets([
                    "Pick a visualizer at the top: **Halo**, **Particles**, **Radial** or **Sound Map**.",
                    "Move the pointer to show the controls; they fade when it rests. In full screen the pointer hides too.",
                    "Heart the tune or add it to a playlist from here.",
                    "Close it with the close button at the top, press **Esc**, or press **⇧⌘F** again.",
                ]),
                .heading("The bar at the bottom"),
                .paragraph("In the library, the floating bar plays, pauses and skips, shows the progress through the tune, and has Shuffle, Repeat and the volume. Tunes with more than one song step through them with the arrows next to the progress bar."),
                .heading("Control Center and media keys"),
                .paragraph("Resonance shows what's playing in Control Center and answers your keyboard's play, next and previous keys."),
                .note(title: "Why can't I scrub through a tune?",
                      text: "A SID tune is a little C64 program that plays in real time, so jumping ahead means running it at full speed, silently, up to that point. The engine can't do that yet."),
            ],
            related: [.visualizers, .shortcuts, .settings]
        ),
        HelpTopic(
            id: .visualizers, group: .listening,
            title: "Visualizers", symbol: "waveform",
            summary: "See what each of the chip's three voices is doing.",
            blocks: [
                .paragraph("The SID chip has three voices, and every visualizer shows all three, each in its own colour. They're drawn from the chip's registers as the tune plays, so what you see is what the chip is doing."),
                .heading("In the inspector"),
                .paragraph("The card at the top of the inspector has three pages. Swipe between them on a trackpad, or click the dots along its bottom edge; Resonance remembers the last one."),
                .bullets([
                    "**Scope**: each voice's waveform, with the note and waveform it's playing.",
                    "**Bars**: each voice's level, with peak hold.",
                    "**Envelope**: each voice's attack, decay, sustain and release as it plays.",
                ]),
                .heading("In Now Playing"),
                .bullets([
                    "**Halo**: a glowing ring per voice that swells with its envelope and wobbles with its waveform's harmonics.",
                    "**Particles**: 24,000 points on a turning sphere, a third per voice, rippling with its envelope and sending a wave across on every new note.",
                    "**Radial**: a ring of spectrum bars per voice, the rings turning opposite ways.",
                    "**Sound Map**: every note becomes a point in 3D, placed by its timbre, so the tune draws its own map as it plays.",
                ]),
                .heading("Colours"),
                .paragraph("Choose the voices' colours in Settings → Appearance: Resonance, C64, Noir, Ember, Abyss, Phosphor, Greyscale, or your own three colours and background. The theme badge, a small strip in the theme's colours, sits on the inspector's visualizer card; you can hide it there too."),
                .link(.settings(.appearance)),
            ],
            related: [.nowPlaying, .settings]
        ),
        HelpTopic(
            id: .playlists, group: .yourMusic,
            title: "Playlists", symbol: "music.note.list",
            summary: "Make your own playlists, and keep them in order.",
            blocks: [
                .bullets([
                    "Click **+** next to Playlists in the sidebar to make one, and type its name.",
                    "Control-click a playlist in the sidebar to play, rename, duplicate or delete it, or show its file in Finder. A deleted playlist goes to the Trash; its tunes stay where they are.",
                    "Drag tunes up and down in a playlist to reorder them. That works while the list is in its own order: not sorted by a column, filtered or searched.",
                    "To take a tune out, Control-click it and choose **Remove from Playlist**.",
                ]),
                .heading("Add to…"),
                .paragraph("**Add to…** in the inspector, in Now Playing, on a composer's card and in a tune's context menu shows My Playlist, Favourites and your playlists, most recently used first. Type to find one; a name that's not taken makes a new playlist with the tunes in it."),
                .heading("Where they live"),
                .paragraph("Your playlists are plain M3U files in ~/Library/Application Support/Resonance/Playlists, which other players can open too."),
            ],
            related: [.favourites, .dragAndDrop]
        ),
        HelpTopic(
            id: .favourites, group: .yourMusic,
            title: "Favourites and My Playlist", symbol: "heart",
            summary: "The two lists that are always there.",
            blocks: [
                .heading("Favourites"),
                .paragraph("Click the heart in the inspector or Now Playing to make a tune a favourite, and again to undo it. Favourites keep the order you hearted them in, and are shared with Phosphor: a heart in one app shows in the other."),
                .heading("My Playlist"),
                .paragraph("My Playlist is where files from outside the library go: the SID files, folders and M3U playlists you drop on the window or add with **⌘O** (**Add Files** in the toolbar). Tunes outside HVSC play the same way; they just don't get STIL's notes."),
                .bullets([
                    "Press **Space** in My Playlist to play or pause.",
                    "Drag tunes up and down to reorder them, and Control-click to remove them.",
                    "It's saved as session.m3u in Resonance's own folder, apart from Phosphor's playlist.",
                ]),
            ],
            related: [.playlists, .dragAndDrop]
        ),
        HelpTopic(
            id: .dragAndDrop, group: .yourMusic,
            title: "Drag and Drop", symbol: "hand.draw",
            summary: "Drag tunes onto playlists, and files onto the window.",
            blocks: [
                .paragraph("Drag a tune, or a whole selection, from any list onto a playlist in the sidebar: Favourites, My Playlist or one of yours. The playlist lights up while the tunes are over it."),
                .bullets([
                    "Dropping **copies**: the tunes are added and stay where they came from.",
                    "Hold **⌘** while you drop to **move** tunes from one of your playlists to another, as ⌘ moves files in Finder. Dropping into Favourites or My Playlist, or from any other list, always adds.",
                    "Within one of your playlists or My Playlist, drag to reorder.",
                    "Drop SID files, folders or M3U playlists from Finder onto the window to add them to My Playlist.",
                ]),
            ],
            related: [.playlists, .favourites]
        ),
        HelpTopic(
            id: .shortcuts, group: .reference,
            title: "Keyboard Shortcuts", symbol: "keyboard",
            summary: "Every Playback command has a key.",
            blocks: [
                .shortcuts([
                    HelpShortcut(keys: "Space", action: "Play or pause, in My Playlist"),
                    HelpShortcut(keys: "⌘.", action: "Stop"),
                    HelpShortcut(keys: "⌘→", action: "Next track"),
                    HelpShortcut(keys: "⌘←", action: "Previous track"),
                    HelpShortcut(keys: "⌥⌘→", action: "Next subtune"),
                    HelpShortcut(keys: "⌥⌘←", action: "Previous subtune"),
                    HelpShortcut(keys: "⌘↑", action: "Volume up"),
                    HelpShortcut(keys: "⌘↓", action: "Volume down"),
                    HelpShortcut(keys: "⌥⌘S", action: "Shuffle on or off"),
                    HelpShortcut(keys: "⇧⌘R", action: "Surprise Me"),
                    HelpShortcut(keys: "⇧⌘F", action: "Show or hide Now Playing"),
                    HelpShortcut(keys: "Esc", action: "Close Now Playing"),
                    HelpShortcut(keys: "⌘O", action: "Add files or folders"),
                    HelpShortcut(keys: "⌘,", action: "Settings"),
                    HelpShortcut(keys: "⌘?", action: "Resonance Help"),
                ]),
                .paragraph("The Playback menu has all of these, and Repeat and Shuffle Collection besides. Your keyboard's media keys work too."),
            ],
            related: [.nowPlaying, .library]
        ),
        HelpTopic(
            id: .settings, group: .reference,
            title: "Settings", symbol: "gearshape",
            summary: "What each tab of Settings does.",
            blocks: [
                .heading("Playback"),
                .bullets([
                    "**Engine**: SIDLite picks the chip model from each tune's header; reSID emulates the chip cycle by cycle. Changing it restarts the tune.",
                    "**Skip RSID tunes**, and the **default song length** for tunes missing from the Songlengths database (0 plays until silence).",
                    "**Stereo**: play 2SID tunes in mirrored stereo, and widen mono tunes: Subtle, Medium or Wide.",
                ]),
                .link(.settings(.playback)),
                .heading("Appearance"),
                .paragraph("The visualizers' theme, your own colours, and whether the theme badge shows."),
                .link(.settings(.appearance)),
                .heading("Collection"),
                .bullets([
                    "The HVSC folder: choose another, or go back to Phosphor's.",
                    "The release you have, updates, and downloading the collection again to restore missing or damaged files.",
                    "Sound fingerprints: how far the scan has got, Pause and Resume, Rebuild All, and the published set.",
                ]),
                .link(.settings(.collection)),
                .heading("History"),
                .paragraph("Clear Recently Played, or reset the count of SIDs you've heard. Both are shared with Phosphor, so this clears them there too."),
                .link(.settings(.history)),
                .heading("Advanced"),
                .paragraph("Import your settings from Phosphor in one click, and see the data folders of both apps and how much they hold."),
                .link(.settings(.advanced)),
            ],
            related: [.gettingStarted, .troubleshooting]
        ),
        HelpTopic(
            id: .troubleshooting, group: .reference,
            title: "Troubleshooting", symbol: "lifepreserver",
            summary: "When something doesn't work as it should.",
            blocks: [
                .heading("Musicians, Games or Demos says it can't read the folder"),
                .paragraph("The HVSC folder has moved, or isn't the one that holds MUSICIANS, GAMES and DEMOS. Choose the right one in Settings → Collection, or click **Use Phosphor's**."),
                .link(.settings(.collection)),
                .heading("Tunes are missing or won't play"),
                .paragraph("In Settings → Collection, **Download Again…** fetches the whole collection and restores missing or damaged files. The tunes already there are kept."),
                .heading("Sounds Like says a tune isn't fingerprinted"),
                .paragraph("The scan hasn't reached it yet. Check Settings → Collection: is the scan paused? Click **Download** next to Published set to fetch the fingerprints of all of HVSC. If some tunes couldn't be scanned, **Retry** tries them again."),
                .heading("A tune stops too soon, or plays on and on"),
                .paragraph("Song lengths come from HVSC's Songlengths database. Tunes it doesn't know play for the default song length in Settings → Playback. Some tunes sound different on the other engine: try switching between SIDLite and reSID."),
                .heading("The HVSC download stopped"),
                .paragraph("Click **Retry** in the message at the top of the window. A download that was cancelled starts over from Download next to Collection."),
                .heading("Running Resonance next to Phosphor"),
                .paragraph("They share Phosphor's data folder: the collection, song lengths, STIL, play history and favourites. Each keeps its own playlist and settings. It's best not to run both at once."),
                .note(title: "Still stuck?",
                      text: "Resonance is in alpha. Report problems on GitHub, from Help → Report a Problem, with what you did and what happened."),
            ],
            related: [.settings, .gettingStarted]
        ),
    ]
}
