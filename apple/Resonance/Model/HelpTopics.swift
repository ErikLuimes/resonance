import Foundation

/// Resonance Help's articles: what the Help window shows, in the order of
/// its sidebar. Plain data, so the text can be searched and tested. Inline
/// `**bold**` and `*italic*` are Markdown.
struct HelpTopic: Identifiable, Hashable {
    enum ID: String, CaseIterable {
        case gettingStarted, soundsLike
        case library, nowPlaying, visualizers
        case smartPlaylists, playlists, favourites, dragAndDrop
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

#if CSDB
private let composerSources = "HVSC and CSDb know"
#else
private let composerSources = "HVSC knows"
#endif

extension SettingsTab {
    var title: String {
        switch self {
        case .playback: "Playback"
        case .appearance: "Appearance"
        case .collection: "HVSC"
#if CSDB
        case .csdb: "CSDb"
#endif
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
                .paragraph("Resonance plays Commodore 64 music: SID tunes, through the emulation engine of Phosphor, an open-source SID player. Its library is the High Voltage SID Collection (HVSC), about 60,000 tunes by thousands of composers."),
                .heading("Get the collection"),
                .steps([
                    "In the sidebar, under HVSC, click **Download** next to **Collection**. Resonance fetches the newest HVSC release from an HVSC mirror and unpacks it into its own folder.",
                    "Follow the download on the Home, which the Collection row opens. Elsewhere in the window a pill at the top shows it, with **Cancel**.",
                    "Once it's in, the Home shows the release: what's new, the three sections to browse (Musicians, Games and Demos) and the curated playlists.",
                ]),
                .paragraph("Already have HVSC? Choose its folder (the one that holds MUSICIANS, GAMES and DEMOS) in Settings → HVSC."),
                .link(.settings(.collection)),
                .note(title: "Coming from Phosphor?",
                      text: "Resonance keeps its own favourites, history and collection. **Import from Phosphor** brings over Phosphor's playback settings, favourites and play history, and its HVSC collection if Resonance has none. Nothing in Phosphor changes.",
                      link: .settings(.advanced)),
                .heading("Sound fingerprints"),
                .paragraph("Sounds Like, the Fingerprint column and the Sound filters need each tune's fingerprint. The first time, Resonance downloads the published fingerprint set (about 42 MB) and audio embeddings (about 11 MB), which cover all of HVSC, and a background scan fills in whatever it doesn't have. A full scan of your own takes a few hours; with the published set it's mostly done in a minute."),
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
                .paragraph("Resonance plays every tune in the collection silently in the background and learns how it sounds: its waveforms, its arpeggios and filter sweeps, its drums and its bass. That fingerprint is what it compares, across all of HVSC, along with an embedding of each tune's sound, made in advance and downloaded once."),
                .heading("What sounds like this?"),
                .bullets([
                    "Play a tune. The inspector's **Sounds Like** card shows its fingerprint as a sphere, its sound in a sentence, and the closest tunes, each with how alike it is as a percentage.",
                    "Click a match to show it in the library, or click **Play These** to play them all, most alike first.",
                    "Until the scan has reached the tune, the card says how far the scan has got.",
                ]),
                .heading("In any tune list"),
                .bullets([
                    "The **Fingerprint** column shows each tune's fingerprint as a barcode. Hover it for a card with the tune's sphere and sound, to play it or find similar tunes.",
                    "Control-click a tune and choose **Find Similar** to sort the list by how alike the others sound to it. Click **Clear** above the list, or sort by a column, to undo it.",
                    "The **Sound** chips above a list keep only the tunes that have all the sounds you pick: Arpeggios, Filter sweeps, Noise drums, Ring mod, Sync leads and Digi samples.",
                ]),
                .heading("Composers who sound alike"),
                .paragraph("Open a composer in Musicians: their card names the three composers who sound most like them, each a link to their tunes."),
                .note(title: "Not fingerprinted yet?",
                      text: "Settings → HVSC shows how far the scan has got, and lets you pause it or download the published set again. The scan runs at low priority and picks up where it left off.",
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
                    "**Search**: everything in HVSC that matches what you type.",
                    "**Recently Played**: the last 100 different tunes you played.",
                    "**Playlists**: Favourites, My Playlist and your own playlists.",
                    "**HVSC**: the Collection row opens the Home; **Musicians**, **Games** and **Demos** list the collection's composers and folders, with their tune counts and years.",
                    "**Curated Playlists**: HVSC's own lists, from the Top 100 to the Grand Tour.",
                ]),
                .paragraph("Settings → Appearance chooses which of these Resonance opens on."),
                .paragraph("Select a composer to see their card and their tunes: **Play**, **Shuffle** or **Add to…** takes them all. Above the tunes is what \(composerSources) about them: swipe the cards, or use the dots under them, for more. Composers without a folder of their own still get a list of the tunes credited to them. The sections of **Games** and **Demos** have the same header, about their tunes: when they were made, how they sound, and the longest, oldest and newest."),
                .heading("Search"),
                .paragraph("Type in the search field at the top of the window, from anywhere. **Search** opens with all of HVSC that matches: the top result beside the first tunes, then composers, games, demos and playlists. The filters at the top narrow it to Tunes, Composers, Games or Demos."),
                .bullets([
                    "Handles and real names, in any order: “tel jeroen”.",
                    "The most prolific first: “jeroen” puts Jeroen Tel on top.",
                    "Spelled either way: “second reality” finds 2nd Reality.",
                    "Accents are optional: “hulsbeck” finds Hülsbeck. Small typos still find their tune.",
                    "Press Return to open the top result.",
                ]),
                .paragraph("Open a composer from the results and **Back to Results** returns to them. Clear the search field to go back to where you were."),
                .paragraph("To narrow only the list you're looking at, use its **Filter this list** field."),
                .note(title: "The first search takes a moment",
                      text: "The first search builds an index of the collection; after that, searches are instant."),
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
                .paragraph("In the library, the floating bar plays, pauses and skips, shows the progress through the tune, and has Shuffle, Repeat and the volume. Drag or click the progress bar to scrub. Tunes with more than one song step through them with the arrows next to the progress bar."),
                .heading("The menu bar player"),
                .paragraph("Click Resonance's icon in the menu bar, or press **⌃⌥⌘P** in any app, for a small player: the tune and its voices, the heart, the controls with Shuffle and Repeat, the next tunes in the list it plays from (click one to play it), Surprise Me and Add to…. Turn Surprise Me off there and Resonance goes back to the list you were playing."),
                .paragraph("While it's on, closing the main window keeps the music playing; **Open Resonance** in the player brings the window back. Turn it off in Settings → Appearance."),
                .heading("Control Center and media keys"),
                .paragraph("Resonance shows what's playing in Control Center and answers your keyboard's play, next and previous keys. Control Center's position slider and its 15-second skips work too."),
                .note(title: "Why does the sound stop for a moment when I scrub?",
                      text: "A SID tune is a little C64 program, so there's nothing to jump to: to reach a point, Resonance runs the tune there silently at full speed, about a second per minute of tune on reSIDfp and faster on SIDLite direct. The bar shows the new position right away; the sound follows. The SIDLite and reSID engines play in real time only and can't scrub."),
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
            id: .smartPlaylists, group: .yourMusic,
            title: "Smart Playlists", symbol: "wand.and.stars",
            summary: "New to you, never heard, similar to a tune, or just say what you'd like to hear.",
            blocks: [
                .paragraph("**Smart Playlist** in the sidebar makes a list from how tunes sound, how long they are and what you've played. Everything happens on your Mac."),
                .heading("Start with a suggestion"),
                .bullets([
                    "**New to Me**: tunes different to what you've heard before. It needs a little history first.",
                    "**Never Heard**: the tunes you haven't played, shuffled.",
                    "**Similar to a Tune**: the closest tunes to what's playing, or one you pick. Its **Match** menu goes through the closest 50, 200 or 1,000, and **Other Versions** also adds tunes with the same name.",
                    "**Slow to Intense**: calm tunes that build towards the end.",
                ]),
                .heading("Or say what you'd like to hear"),
                .bullets([
                    "Moods: “chill”, “fast”, and their order, so “slow to intense” builds up and “start hard and wind down” winds down.",
                    "Composers and tunes: “Rob Hubbard”, “like Commando”.",
                    "Titles: “all tunes with love in the title”, “called Axel F”.",
                    "Sounds and chips: “arpeggio-heavy”, “filtered”, “strong bass”, “6581”, “8580”, “dual SID”.",
                    "Several at once: “Tel, Hubbard and Follin”, “like Sanxion and Delta”.",
                    "Facts: “from 1985 and 1986”, “the eighties”, “game music”, “never heard”, “longer than 3 minutes”, “for 2 hours”, “until 9 PM”.",
                ]),
                .paragraph("It reacts as you type. When it isn't sure, it says what it did instead. You can also pick **Make a Playlist Like This** from a tune's menu, or **Make a Playlist** in search."),
                .heading("Keeping a list"),
                .paragraph("**Save** keeps the tunes as one of your playlists. It stays as it is then, and **Refresh** makes a new pick."),
            ],
            related: [.soundsLike, .playlists]
        ),
        HelpTopic(
            id: .playlists, group: .yourMusic,
            title: "Playlists", symbol: "music.note.list",
            summary: "Make your own playlists, and keep them in order.",
            blocks: [
                .bullets([
                    "Click **+** next to Playlists in the sidebar to make one, and type its name.",
                    "Control-click a playlist in the sidebar to play, rename, duplicate, export or delete it, or show its file in Finder. A deleted playlist goes to the Trash; its tunes stay where they are.",
                    "Drag tunes up and down in a playlist to reorder them. That works while the list is in its own order: not sorted by a column or filtered.",
                    "To take a tune out, Control-click it and choose **Remove from Playlist**.",
                ]),
                .heading("Add to…"),
                .paragraph("**Add to…** in the inspector, in Now Playing, on a composer's card and in a tune's context menu shows My Playlist, Favourites and your playlists, most recently used first. Type to find one; a name that's not taken makes a new playlist with the tunes in it."),
                .heading("Where they live"),
                .paragraph("Your playlists are plain M3U files in ~/Library/Application Support/Resonance/Playlists, which other players can open too."),
                .paragraph("To share one, or Favourites or My Playlist, Control-click it in the sidebar and choose **Export…**. Tunes from HVSC are saved with paths relative to the collection, so the file works on any Mac with HVSC. Other players may not find them without your HVSC folder as their base."),
            ],
            related: [.favourites, .dragAndDrop]
        ),
        HelpTopic(
            id: .favourites, group: .yourMusic,
            title: "Favourites and My Playlist", symbol: "heart",
            summary: "The two lists that are always there.",
            blocks: [
                .heading("Favourites"),
                .paragraph("Click the heart in the inspector or Now Playing to make a tune a favourite, and again to undo it. Favourites keep the order you hearted them in."),
                .heading("My Playlist"),
                .paragraph("My Playlist is where files from outside the library go: the SID files, folders and M3U playlists you drop on the window or add with **⌘O** (**Add Files** in the toolbar). Tunes outside HVSC play the same way; they just don't get STIL's notes."),
                .bullets([
                    "Press **Space** in My Playlist to play or pause.",
                    "Drag tunes up and down to reorder them, and Control-click to remove them.",
                    "It's saved as session.m3u in Resonance's folder.",
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
                    "Drop them on **Playlists** or an empty part of the sidebar to make a new playlist. A playlist or a folder is named after its file, and the file itself stays as it is.",
                    "Drop them on a playlist in the sidebar to add the tunes to it, or on Favourites to heart them.",
                    "Drop an M3U playlist on the app's icon, or use **Open With** in Finder, to make a new playlist. It's shown, not played. SID files opened this way play in My Playlist.",
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
                    HelpShortcut(keys: "Space", action: "Play or pause (not while typing)"),
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
                    HelpShortcut(keys: "⌃⌥⌘P", action: "Open the menu bar player, from any app"),
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
                    "**Engine**: four software emulations, all following each tune's header for PAL or NTSC and the chip model. **reSIDfp**, the default, is the most accurate: libsidplayfp's reference C64 and chip emulation. **SIDLite direct** is a compact chip model, the lightest on the processor. These two can scrub within a tune. **SIDLite** is the same compact chip through Phosphor's original player, and **reSID** the older cycle-by-cycle model, the heaviest; both play in real time only. Changing the engine restarts the tune.",
                    "**Skip RSID tunes**, and the **default song length** for tunes whose length isn't known (0 plays until silence).",
                    "**Stereo**: play 2SID tunes in mirrored stereo, and widen mono tunes: Subtle, Medium or Wide.",
                ]),
                .link(.settings(.playback)),
                .heading("Appearance"),
                .paragraph("Whether the menu bar player shows, the visualizers' theme, your own colours, and whether the theme badge shows."),
                .link(.settings(.appearance)),
                .heading("Collection"),
                .bullets([
                    "The HVSC folder: choose another, or use the one Phosphor downloaded.",
                    "The release you have, updates, and downloading the collection again to restore missing or damaged files.",
                    "Sound fingerprints: how far the scan has got, Pause and Resume, Rebuild All, and the published set.",
                ]),
                .link(.settings(.collection)),
                .heading("History"),
                .paragraph("Clear Recently Played, or reset the count of SIDs you've heard."),
                .link(.settings(.history)),
                .heading("Advanced"),
                .paragraph("**Import from Phosphor** takes Phosphor's playback settings, adds its favourites and play history to yours, and uses its HVSC collection if Resonance has none. Nothing in Phosphor changes. Below it, the data folders of both apps and how much they hold. **Reset** moves the collection Resonance downloaded to the Trash, or resets everything: Resonance's folder goes to the Trash, its settings are forgotten, and it restarts fresh. Phosphor's folder is never touched."),
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
                .paragraph("The HVSC folder has moved, or isn't the one that holds MUSICIANS, GAMES and DEMOS. Choose the right one in Settings → HVSC, or click **Use Phosphor's**."),
                .link(.settings(.collection)),
                .heading("Tunes are missing or won't play"),
                .paragraph("In Settings → HVSC, **Download Again…** fetches the whole collection and restores missing or damaged files. The tunes already there are kept."),
                .heading("Sounds Like says a tune isn't fingerprinted"),
                .paragraph("The scan hasn't reached it yet. Check Settings → HVSC: is the scan paused? Click **Download** next to Published set to fetch the fingerprints of all of HVSC. If some tunes couldn't be scanned, **Retry** tries them again."),
                .heading("A tune stops too soon, or plays on and on"),
                .paragraph("Song lengths come from HVSC's Songlengths database. For tunes it doesn't know, such as ones from outside HVSC, Resonance works the length out in the background by running the tune and listening for it to end or start over; those lengths show with a ~ and can be off. Until then, or if it can't tell, a tune plays for the default song length in Settings → Playback. Some tunes sound different on another engine: try switching between SIDLite, reSIDfp, SIDLite direct and reSID."),
                .heading("The HVSC download stopped"),
                .paragraph("Click **Retry** in the message at the top of the window. A download that was cancelled starts over from Download next to Collection."),
                .heading("Coming from Phosphor"),
                .paragraph("Resonance is its own app, built on Phosphor's engine, and keeps its own favourites, history, playlists, settings and collection: it doesn't read Phosphor's folder. To bring them over, use **Import from Phosphor** in Settings → Advanced."),
                .link(.settings(.advanced)),
                .note(title: "Still stuck?",
                      text: "Resonance is in alpha. Report problems on GitHub, from Help → Report a Problem, with what you did and what happened."),
            ],
            related: [.settings, .gettingStarted]
        ),
    ]
}
