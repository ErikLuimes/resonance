import Foundation

/// Resonance Help's articles: what the Help window shows, in the order of
/// its sidebar. Plain data, so the text can be searched and tested. Inline
/// `**bold**` and `*italic*` are Markdown.
struct HelpTopic: Identifiable, Hashable {
    enum ID: String, CaseIterable {
        case gettingStarted, soundsLike, readingFingerprints
        case library, nowPlaying, visualizers
        case smartPlaylists, playlists, favorites, dragAndDrop, sharing
        case terminal, commands, assistants, raycast, siriAndSpotlight, dock
        case shortcuts, settings, troubleshooting
    }

    enum Group: String, CaseIterable {
        case start = "Start Here"
        case listening = "Listening"
        case yourMusic = "Your Music"
        case integrations = "Integrations"
        case reference = "Reference"

        var title: String {
            switch self {
            case .start: String(localized: "Start Here")
            case .listening: String(localized: "Listening")
            case .yourMusic: String(localized: "Your Music")
            case .integrations: String(localized: "Integrations")
            case .reference: String(localized: "Reference")
            }
        }
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
    /// The barcode's bars, each drawn on its own beside what it means.
    case traitKey([HelpTrait])
    /// Tunes drawn as a sphere and a barcode, side by side.
    case fingerprintExamples([HelpFingerprintExample])
    /// Commands to read or copy, one per line.
    case code(String)
    case link(HelpLink)

    var text: [String] {
        switch self {
        case .heading(let text), .paragraph(let text), .code(let text): [text]
        case .bullets(let items), .steps(let items): items
        case .note(let title, let text, _): [title, text]
        case .shortcuts(let shortcuts): shortcuts.flatMap { [$0.keys, $0.action] }
        case .traitKey(let traits): traits.flatMap { [$0.trait.name, $0.meaning] }
        case .fingerprintExamples(let examples): examples.map(\.caption)
        case .link: []
        }
    }
}

struct HelpShortcut: Hashable {
    let keys: String
    let action: String
}

struct HelpTrait: Hashable {
    let trait: SoundTrait
    let meaning: String
}

/// A made-up tune: its nine traits, in `SoundTrait` order, and its share of
/// triangle, saw, pulse and noise.
struct HelpFingerprintExample: Hashable {
    let caption: String
    let traits: [Float]
    let mix: [Float]
}

/// A link in an article: to a page of Settings, or another topic.
enum HelpLink: Hashable {
    case settings(SettingsPage)
    case topic(HelpTopic.ID)

    var title: String {
        switch self {
        case .settings(let page): String(localized: "Open Settings → \(page.title)")
        case .topic(let id): HelpTopic.topic(id).title
        }
    }
}

#if CSDB
private let composerSources = String(localized: "HVSC and CSDb know")
#else
private let composerSources = String(localized: "HVSC knows")
#endif

extension HelpTopic {
    static let all: [HelpTopic] = [
        HelpTopic(
            id: .gettingStarted, group: .start,
            title: String(localized: "Getting Started"), symbol: "arrow.down.circle",
            summary: String(localized: "Get the High Voltage SID Collection, and start listening."),
            blocks: [
                .paragraph(String(localized: "Resonance plays Commodore 64 music: SID tunes, through the emulation engine of Phosphor, an open-source SID player. Its library is the High Voltage SID Collection (HVSC), about 60,000 tunes by thousands of composers.")),
                .heading(String(localized: "Get the collection")),
                .steps([
                    String(localized: "In the sidebar, under HVSC, click **Download** next to **Collection**. Resonance fetches the newest HVSC release from an HVSC mirror and unpacks it into its own folder."),
                    String(localized: "Follow the download on the Home, which the Collection row opens. Elsewhere in the window a pill at the top shows it, with **Cancel**."),
                    String(localized: "Once it's in, the Home shows the release: what's new, the three sections to browse (Musicians, Games and Demos) and the curated playlists."),
                ]),
                .paragraph(String(localized: "Already have HVSC? Choose its folder (the one that holds MUSICIANS, GAMES and DEMOS) in Settings → Collection.")),
                .link(.settings(.collection)),
                .heading(String(localized: "Sound fingerprints")),
                .paragraph(String(localized: "Sounds Like, the Fingerprint column and the Sound filters need each tune's fingerprint. The first time, Resonance downloads the published fingerprint set (about 42 MB) and audio embeddings (about 11 MB), which cover all of HVSC, and a background scan fills in whatever it doesn't have. A full scan of your own takes a few hours; with the published set it's mostly done in a minute.")),
                .paragraph(String(localized: "While the collection downloads or the scan runs, the Dock icon shows how far it has gotten. If Resonance is in the background when one of them ends, or the download fails, it sends a notification. It asks for permission the first time; change your mind in System Settings → Notifications.")),
                .heading(String(localized: "Start listening")),
                .bullets([
                    String(localized: "Press **⇧⌘R** for **Surprise Me**: a radio of random tunes from all of HVSC."),
                    String(localized: "Double-click any tune in a list to play it."),
                    String(localized: "Drop SID files, folders or M3U playlists onto the window, or press **⌘O**. They go into My Playlist."),
                ]),
                .paragraph(String(localized: "The Help menu brings back the welcome steps with **Welcome to Resonance**. It also has **Keyboard Shortcuts** and the **Credits**, with a nod to the demoscene.")),
            ],
            related: [.soundsLike, .library, .settings]
        ),
        HelpTopic(
            id: .soundsLike, group: .start,
            title: String(localized: "Sounds Like"), symbol: "waveform.badge.magnifyingglass",
            summary: String(localized: "Find the tunes in HVSC that sound most like the one you love."),
            blocks: [
                .paragraph(String(localized: "Resonance plays every tune in the collection silently in the background and learns how it sounds: its waveforms, its arpeggios and filter sweeps, its drums and its bass. That fingerprint is what it compares, across all of HVSC, along with an embedding of each tune's sound, made in advance and downloaded once.")),
                .heading(String(localized: "What sounds like this?")),
                .bullets([
                    String(localized: "Play a tune. The inspector's **Sounds Like** card shows its fingerprint as a sphere, its sound in a sentence, and the closest tunes, each with how alike it is as a percentage."),
                    String(localized: "Click a match to show it in the library, or click **Play These** to play them all, most alike first."),
                    String(localized: "Until the scan has reached the tune, the card says how far the scan has gotten."),
                ]),
                .heading(String(localized: "Sound Drift")),
                .paragraph(String(localized: "Click **Drift From Here** on the Sounds Like card, or choose **Drift From This Tune** on the Dock icon, for a radio that doesn't end: each tune sounds like the one before, so it slowly wanders across the collection. It stops when you play something else.")),
                .heading(String(localized: "In any tune list")),
                .bullets([
                    String(localized: "The **Fingerprint** column shows each tune's fingerprint as a barcode. Hover it for a card with the tune's sphere and sound, to play it or find similar tunes."),
                    String(localized: "Control-click a tune and choose **Find Similar** to sort the list by how alike the others sound to it. Click **Clear** above the list, or sort by a column, to undo it."),
                    String(localized: "The **Sound** chips above a list keep only the tunes that have all the sounds you pick: Arpeggios, Filter sweeps, Noise drums, Ring mod, Sync leads and Digi samples."),
                ]),
                .link(.topic(.readingFingerprints)),
                .heading(String(localized: "Composers who sound alike")),
                .paragraph(String(localized: "Open a composer in Musicians: their card names the three composers who sound most like them, each a link to their tunes.")),
                .note(title: String(localized: "Not fingerprinted yet?"),
                      text: String(localized: "Settings → Fingerprints shows how far the scan has gotten, and lets you pause it or download the published set again. The scan runs at low priority and picks up where it left off."),
                      link: .settings(.fingerprints)),
            ],
            related: [.readingFingerprints, .gettingStarted, .library, .nowPlaying]
        ),
        HelpTopic(
            id: .readingFingerprints, group: .start,
            title: String(localized: "Reading a Fingerprint"), symbol: "barcode",
            summary: String(localized: "What the bars of the barcode and the shape of the sphere tell you."),
            blocks: [
                .paragraph(String(localized: "Resonance measures up to three minutes of each tune, by watching what it asks the SID chip to do. It draws nine of those measurements as a **barcode** in tune lists and as a **sphere** on the Sounds Like card and the barcode's hover card.")),
                .fingerprintExamples([
                    HelpFingerprintExample(caption: String(localized: "Fast arpeggios and noise drums, mostly pulse"),
                                           traits: [0.8, 0.85, 0.3, 0.1, 0, 0, 0, 0.75, 0.6],
                                           mix: [0.05, 0.1, 0.6, 0.25]),
                    HelpFingerprintExample(caption: String(localized: "Filtered sync leads, mostly saw"),
                                           traits: [0.3, 0.05, 0.5, 0.95, 0, 0.5, 0, 0.1, 0],
                                           mix: [0.1, 0.8, 0.05, 0.05]),
                    HelpFingerprintExample(caption: String(localized: "Few notes and no tricks, mostly triangle"),
                                           traits: [0.15, 0, 0.05, 0, 0, 0, 0, 0, 0],
                                           mix: [0.9, 0, 0.1, 0]),
                ]),
                .paragraph(String(localized: "These three are made up, to show the difference.")),
                .heading(String(localized: "The barcode")),
                .paragraph(String(localized: "Every barcode has the same nine bars in the same order, so tunes that share a sound share a pattern down the column. The taller and stronger a bar, the more of that trait. A trait the tune doesn't use leaves a small stub.")),
                .traitKey([
                    HelpTrait(trait: .notes, meaning: String(localized: "How many notes start each second, across all voices. Full at 18 a second.")),
                    HelpTrait(trait: .arpeggios, meaning: String(localized: "Jumps of a semitone or more within a held note, the rapid chords the SID is known for. Full at 50 a second.")),
                    HelpTrait(trait: .vibrato, meaning: String(localized: "Small wobbles in pitch within a note. Full at 12 a second.")),
                    HelpTrait(trait: .filter, meaning: String(localized: "How much of the time a voice goes through the filter. Full when one always does.")),
                    HelpTrait(trait: .ring, meaning: String(localized: "How much of the time ring modulation is on, for bell-like and metallic tones. Full at about a sixth of the time.")),
                    HelpTrait(trait: .sync, meaning: String(localized: "How much of the time hard sync is on, for biting lead sounds. Full at 40% of the time.")),
                    HelpTrait(trait: .digi, meaning: String(localized: "How much of the tune plays samples through the chip, such as speech or sampled drums. Full at a third of the time.")),
                    HelpTrait(trait: .noise, meaning: String(localized: "Noise hits each second, which are mostly drums. Full at 12 a second.")),
                    HelpTrait(trait: .pulseWidth, meaning: String(localized: "How far the pulse width sweeps during a note, which gives pulse sounds their movement. Full at a third of its range.")),
                ]),
                .paragraph(String(localized: "Most scales top out around where HVSC's busiest tunes sit, so a full bar means “about as much as tunes get,” not 100% of anything. Only a few tunes go past the top, and they stay at full height.")),
                .paragraph(String(localized: "The colors group the bars: cyan for pitch movement, violet for the filter, orange for the chip's harsher sounds, red for samples and green for pulse width. Notes take the color of the text.")),
                .heading(String(localized: "The sphere")),
                .paragraph(String(localized: "The sphere draws the same nine traits in 3D, from a ball of 700 points.")),
                .bullets([
                    String(localized: "**Shape**: each trait has its own direction, the same for every tune, and the ball bulges that way as far as the trait is strong. A tall bar is a long spike, and a tune with few traits stays nearly round. Tunes with similar bars get similar shapes."),
                    String(localized: "**Color**: here the colors mean something different than they do on the barcode. Each point takes one of the chip's waveforms, in proportion to how much the tune uses it: green for triangle, violet for saw, cyan for pulse and orange for noise. The hover card's Waveform Mix bar shows the same shares in numbers."),
                    String(localized: "**Turning**: it turns so you can see every side. The speed means nothing, and neither does the size: every sphere is scaled to fit its frame, so compare shapes, not sizes."),
                ]),
                .note(title: String(localized: "Looking alike isn't the same as sounding alike"),
                      text: String(localized: "The barcode and the sphere show only part of what Sounds Like compares: 41 measurements of how a tune drives the chip, and an embedding of its sound. Two tunes can look alike and still not be close matches, or the other way around. The percentage on a match is the better guide.")),
            ],
            related: [.soundsLike, .library]
        ),
        HelpTopic(
            id: .library, group: .listening,
            title: String(localized: "Library and Search"), symbol: "books.vertical",
            summary: String(localized: "Browse HVSC by composer, game or demo, and find any tune by typing."),
            blocks: [
                .heading(String(localized: "The sidebar")),
                .bullets([
                    String(localized: "**Search**: everything in HVSC that matches what you type."),
                    String(localized: "**Recently Played**: the last 100 different tunes you played."),
                    String(localized: "**Playlists**: Favorites, My Playlist and your own playlists."),
                    String(localized: "**HVSC**: the Collection row opens the Home; **Musicians**, **Games** and **Demos** list the collection's composers and folders, with their tune counts and years."),
                    String(localized: "**Curated Playlists**: HVSC's own lists, from the Top 100 to the Grand Tour."),
                ]),
                .paragraph(String(localized: "Settings → General chooses which of these Resonance opens on.")),
                .paragraph(String(localized: "Select a composer to see their card and their tunes: **Add to…** or **Play**, in the row above the list, takes them all, and the player bar's shuffle decides the order. At the top is what \(composerSources) about them: swipe the cards, or use the dots under them, for more. Composers without a folder of their own still get a list of the tunes credited to them. The sections of **Games** and **Demos** have the same header, about their tunes: when they were made, how they sound, and the longest, oldest and newest.")),
                .heading(String(localized: "Search")),
                .paragraph(String(localized: "Type in the search field at the top of the window, from anywhere. **Search** opens with all of HVSC that matches: the top result beside the first tunes, then composers, games, demos and playlists. The filters at the top narrow it to Tunes, Composers, Games or Demos.")),
                .bullets([
                    String(localized: "Handles and real names, in any order: “tel jeroen”."),
                    String(localized: "The most prolific first: “jeroen” puts Jeroen Tel on top."),
                    String(localized: "Spelled either way: “second reality” finds 2nd Reality."),
                    String(localized: "Accents are optional: “hulsbeck” finds Hülsbeck. Small typos still find their tune."),
                    String(localized: "Press Return to open the top result."),
                ]),
                .paragraph(String(localized: "Open a composer from the results and **Back to Results** returns to them. Clear the search field to go back to where you were.")),
                .paragraph(String(localized: "To narrow only the list you're looking at, use its **Filter this list** field.")),
                .note(title: String(localized: "The first search takes a moment"),
                      text: String(localized: "The first search builds an index of the collection; after that, searches are instant.")),
                .heading(String(localized: "Tune lists")),
                .bullets([
                    String(localized: "Double-click a tune to play it; the list plays on from there."),
                    String(localized: "Click a column header to sort, and **Back to Original Order** above the list to undo it. Control-click the header to choose which columns show."),
                    String(localized: "Control-click a tune to play it, add it to a playlist, find similar tunes or show it in Finder."),
                ]),
                .heading(String(localized: "The inspector")),
                .paragraph(String(localized: "The column on the right (toggle it with **Inspector** in the toolbar) shows what's playing: the voices of the chip, Sounds Like, the tune's details, STIL's notes and stories about it, its composer, and HVSC's known bugs when the tune has any. Where the tune came from — “Playing from Rob Hubbard” — is a link back to it.")),
            ],
            related: [.soundsLike, .playlists, .shortcuts]
        ),
        HelpTopic(
            id: .nowPlaying, group: .listening,
            title: String(localized: "Now Playing"), symbol: "play.rectangle",
            summary: String(localized: "Turn the window into a player with a big visualizer."),
            blocks: [
                .paragraph(String(localized: "Press **⇧⌘F**, or click the tune's title or the button at the right end of the bar at the bottom of the window, and Now Playing slides up over the library: the tune, its composer, where it's playing from, and a large visualizer driven by the SID chip's own registers.")),
                .bullets([
                    String(localized: "Pick a visualizer at the top: **Halo**, **Particles**, **Radial** or **Sound Map**."),
                    String(localized: "Move the pointer to show the controls; they fade when it rests. In full screen the pointer hides too."),
                    String(localized: "Heart the tune or add it to a playlist from here."),
                    String(localized: "Close it with the close button at the top, press **Esc**, or press **⇧⌘F** again."),
                ]),
                .heading(String(localized: "The bar at the bottom")),
                .paragraph(String(localized: "In the library, the floating bar plays, pauses and skips, shows the progress through the tune, and has Shuffle, Repeat and the volume. Drag or click the progress bar to scrub. Tunes with more than one song step through them with the arrows next to the progress bar.")),
                .heading(String(localized: "The menu bar player")),
                .paragraph(String(localized: "Click Resonance's icon in the menu bar, or press **⌃⌥⌘P** in any app, for a small player: the tune and its voices, the heart, the controls with Shuffle and Repeat, the next tunes in the list it plays from (click one to play it), Surprise Me and Add to…. Turn Surprise Me off there and Resonance goes back to the list you were playing.")),
                .paragraph(String(localized: "While it's on, closing the main window keeps the music playing; **Open Resonance** in the player brings the window back. Turn it off in Settings → General.")),
                .heading(String(localized: "Control Center and media keys")),
                .paragraph(String(localized: "Resonance shows what's playing in Control Center, with the tune's fingerprint sphere as its picture, or its composer's colors before it's scanned, and answers your keyboard's play, next and previous keys. Control Center's position slider and its 15-second skips work too.")),
                .note(title: String(localized: "Why does the sound stop for a moment when I scrub?"),
                      text: String(localized: "A SID tune is a little C64 program, so there's nothing to jump to: to reach a point, Resonance runs the tune there silently at full speed, about a second per minute of tune on reSIDfp and faster on SIDLite direct. The bar shows the new position right away; the sound follows.")),
            ],
            related: [.visualizers, .shortcuts, .dock, .siriAndSpotlight]
        ),
        HelpTopic(
            id: .visualizers, group: .listening,
            title: String(localized: "Visualizers"), symbol: "waveform",
            summary: String(localized: "See what each of the chip's three voices is doing."),
            blocks: [
                .paragraph(String(localized: "The SID chip has three voices, and every visualizer shows all three, each in its own color. They're drawn from the chip's registers as the tune plays, so what you see is what the chip is doing.")),
                .heading(String(localized: "In the inspector")),
                .paragraph(String(localized: "The card at the top of the inspector has three pages. Swipe between them on a trackpad, or click the dots along its bottom edge; Resonance remembers the last one.")),
                .bullets([
                    String(localized: "**Scope**: each voice's waveform, with the note and waveform it's playing."),
                    String(localized: "**Bars**: each voice's level, with peak hold."),
                    String(localized: "**Envelope**: each voice's attack, decay, sustain and release as it plays."),
                ]),
                .heading(String(localized: "In Now Playing")),
                .bullets([
                    String(localized: "**Halo**: a glowing ring per voice that swells with its envelope and wobbles with its waveform's harmonics."),
                    String(localized: "**Particles**: 24,000 points on a turning sphere, a third per voice, rippling with its envelope and sending a wave across on every new note."),
                    String(localized: "**Radial**: a ring of spectrum bars per voice, the rings turning opposite ways."),
                    String(localized: "**Sound Map**: every note becomes a point in 3D, placed by its timbre, so the tune draws its own map as it plays."),
                ]),
                .heading(String(localized: "Under the hood")),
                .paragraph(String(localized: "The chip button in the player bar, or **View → Show Under the Hood**, slides a drawer up over the list, and the button at its top right slides it back down.")),
                .bullets([
                    String(localized: "**Tracker**: the tune as a tracker would show it, with what's coming below the row you're hearing. A SID file holds code, not patterns, so this is rebuilt from what its player writes to the chip. An instrument here is a waveform and envelope, not necessarily one the composer had in mind, and some tunes have no steady beat to find."),
                    String(localized: "**Registers**: every byte the player writes, lighting up as it changes, with the control bits spelled out."),
                    String(localized: "**Sweeps**: pulse width, the filter and the gates over the last few seconds."),
                    String(localized: "**Pitch Trail**: where each voice's pitch has been."),
                ]),
                .paragraph(String(localized: "On a tune with more than one SID, Registers, Sweeps and Pitch Trail show them all at once where there's room, and otherwise the one you pick. The Tracker always shows the one you pick.")),
                .heading(String(localized: "Colors")),
                .paragraph(String(localized: "Choose the voices' colors in Settings → Appearance: Resonance, C64, Noir, Ember, Abyss, Phosphor, Grayscale, or your own three colors and background. The theme badge, a small strip in the theme's colors, sits on the inspector's visualizer card; you can hide it there too.")),
                .link(.settings(.appearance)),
            ],
            related: [.nowPlaying, .settings]
        ),
        HelpTopic(
            id: .smartPlaylists, group: .yourMusic,
            title: String(localized: "Smart Playlists"), symbol: "wand.and.stars",
            summary: String(localized: "New to you, never heard, similar to a tune, or just say what you'd like to hear."),
            blocks: [
                .paragraph(String(localized: "**Smart Playlist** in the sidebar makes a list from how tunes sound, how long they are and what you've played. Everything happens on your Mac.")),
                .heading(String(localized: "Start with a suggestion")),
                .bullets([
                    String(localized: "**New to Me**: tunes different from what you've heard before. It needs a little history first."),
                    String(localized: "**Never Heard**: the tunes you haven't played, shuffled."),
                    String(localized: "**Similar to a Tune**: the closest tunes to what's playing, or one you pick. Its **Match** menu goes through the closest 50, 200 or 1,000, and **Other Versions** also adds tunes with the same name."),
                    String(localized: "**Slow to Intense**: calm tunes that build toward the end."),
                ]),
                .heading(String(localized: "Or say what you'd like to hear")),
                .bullets([
                    String(localized: "Moods: “chill”, “fast”, and their order, so “slow to intense” builds up and “start hard and wind down” winds down."),
                    String(localized: "Composers and tunes: “Rob Hubbard”, “like Commando”."),
                    String(localized: "Titles: “all tunes with love in the title”, “called Axel F”."),
                    String(localized: "Sounds and chips: “arpeggio-heavy”, “filtered”, “strong bass”, “6581”, “8580”, “dual SID”."),
                    String(localized: "Several at once: “Tel, Hubbard and Follin”, “like Sanxion and Delta”."),
                    String(localized: "Facts: “from 1985 and 1986”, “the eighties”, “game music”, “never heard”, “longer than 3 minutes”, “for 2 hours”, “until 9 PM”."),
                ]),
                .paragraph(String(localized: "It reacts as you type. When it isn't sure, it says what it did instead. You can also pick **Make a Playlist Like This** from a tune's menu, or **Make a Playlist** in search.")),
                .heading(String(localized: "Keeping a list")),
                .paragraph(String(localized: "**Save** keeps the tunes as one of your playlists. It stays as it is then, and **Refresh** makes a new pick.")),
            ],
            related: [.soundsLike, .playlists]
        ),
        HelpTopic(
            id: .playlists, group: .yourMusic,
            title: String(localized: "Playlists"), symbol: "music.note.list",
            summary: String(localized: "Make your own playlists, and keep them in order."),
            blocks: [
                .bullets([
                    String(localized: "Click **+** next to Playlists in the sidebar to make one, and type its name."),
                    String(localized: "Control-click a playlist in the sidebar to play, rename, duplicate, export or delete it, or show its file in Finder. A deleted playlist goes to the Trash; its tunes stay where they are."),
                    String(localized: "The **#** column shows each tune's place in the playlist."),
                    String(localized: "Drag tunes up and down in a playlist to reorder them. That works while the list is in its own order: not sorted by a column or filtered. **Back to Original Order**, above a sorted list, returns to it."),
                    String(localized: "To take a tune out, Control-click it and choose **Remove from Playlist**."),
                ]),
                .heading(String(localized: "Add to…")),
                .paragraph(String(localized: "**Add to…** in the inspector, in Now Playing, on a composer's card and in a tune's context menu shows My Playlist, Favorites and your playlists, most recently used first. Type to find one; a name that's not taken makes a new playlist with the tunes in it.")),
                .heading(String(localized: "Where they live")),
                .paragraph(String(localized: "Your playlists are plain M3U files in Resonance's folder, which other players can open too: Settings → Storage and Reset shows it in Finder.")),
                .paragraph(String(localized: "To share one, or Favorites or My Playlist, Control-click it in the sidebar and choose **Export…**. Tunes from HVSC are saved with paths relative to the collection, so the file works on any Mac with HVSC. Other players may not find them without your HVSC folder as their base.")),
            ],
            related: [.favorites, .dragAndDrop]
        ),
        HelpTopic(
            id: .favorites, group: .yourMusic,
            title: String(localized: "Favorites and My Playlist"), symbol: "heart",
            summary: String(localized: "The two lists that are always there."),
            blocks: [
                .heading(String(localized: "Favorites")),
                .paragraph(String(localized: "Click the heart in the inspector or Now Playing to make a tune a favorite, and again to undo it. Favorites keep the order you hearted them in.")),
                .heading(String(localized: "My Playlist")),
                .paragraph(String(localized: "My Playlist is where files from outside the library go: the SID files, folders and M3U playlists you drop on the window or add with **⌘O** (**Add Files** in the toolbar). Tunes outside HVSC play the same way; they just don't get STIL's notes.")),
                .bullets([
                    String(localized: "Press **Space** in My Playlist to play or pause."),
                    String(localized: "Drag tunes up and down to reorder them, and Control-click to remove them."),
                    String(localized: "It's saved as session.m3u in Resonance's folder."),
                ]),
            ],
            related: [.playlists, .dragAndDrop]
        ),
        HelpTopic(
            id: .dragAndDrop, group: .yourMusic,
            title: String(localized: "Drag and Drop"), symbol: "hand.draw",
            summary: String(localized: "Drag tunes onto playlists, and files onto the window."),
            blocks: [
                .paragraph(String(localized: "Drag a tune, or a whole selection, from any list onto a playlist in the sidebar: Favorites, My Playlist or one of yours. The playlist lights up while the tunes are over it.")),
                .bullets([
                    String(localized: "Dropping **copies**: the tunes are added and stay where they came from."),
                    String(localized: "Hold **⌘** while you drop to **move** tunes from one of your playlists to another, as ⌘ moves files in Finder. Dropping into Favorites or My Playlist, or from any other list, always adds."),
                    String(localized: "Within one of your playlists or My Playlist, drag to reorder."),
                    String(localized: "Drop SID files, folders or M3U playlists from Finder onto the window to add them to My Playlist."),
                    String(localized: "Drop them on **Playlists** or an empty part of the sidebar to make a new playlist. A playlist or a folder is named after its file, and the file itself stays as it is."),
                    String(localized: "Drop them on a playlist in the sidebar to add the tunes to it, or on Favorites to heart them."),
                    String(localized: "Drop an M3U playlist on the app's icon, or use **Open With** in Finder, to make a new playlist. It's shown, not played. SID files opened this way play in My Playlist."),
                ]),
            ],
            related: [.playlists, .favorites]
        ),
        HelpTopic(
            id: .sharing, group: .yourMusic,
            title: String(localized: "Sharing a Tune"), symbol: "square.and.arrow.up",
            summary: String(localized: "Send a friend a link to the tune you're listening to."),
            blocks: [
                .paragraph(String(localized: "**Share…**, next to Add to… in Now Playing, the inspector and the menu bar player, makes a short link to a tune: Copy Link, Messages, Mail, or **More…** for any other app. **Share** in a tune's context menu does the same from a list. A subtune stays that subtune.")),
                .bullets([
                    String(localized: "Pasted into Messages, Slack, Discord and the like, the link shows the tune's card: its title, composer, year, length and sound fingerprint."),
                    String(localized: "**Open in Resonance** on that page opens the tune in the app, where you can play it or show it in the library."),
                    String(localized: "People without Resonance see the tune's card and a download link."),
                ]),
                .heading(String(localized: "When someone sends you a tune")),
                .paragraph(String(localized: "If your collection is older and doesn't have it, Resonance offers the HVSC update. With no collection yet, it offers the download. The download continues if you close the sheet; open the link again when it's done.")),
                .note(title: String(localized: "Only tunes from HVSC"),
                      text: String(localized: "A link names a tune in HVSC, so the other person gets it from their own collection. Your own SID files can't be shared this way.")),
            ],
            related: [.playlists, .favorites]
        ),
        HelpTopic(
            id: .terminal, group: .integrations,
            title: String(localized: "The Terminal App"), symbol: "apple.terminal",
            summary: String(localized: "Your library, Sounds Like and the music, in a terminal window."),
            blocks: [
                .paragraph(String(localized: "Install the **resonance** command from Settings → Integrations, and run it with nothing after it. The app does the playing, so the window, the terminal and every shortcut are the same player. If Resonance isn't running, it starts in the background.")),
                .link(.settings(.integrations)),
                .paragraph(String(localized: "Press **?** there for its keys. It fits the window: from 110 columns, a panel beside the list says how the tune under the cursor sounds and what it sounds like, and from 120 columns by 38 rows you get the large header. It looks best in a terminal with millions of colors, such as iTerm2, Ghostty or Kitty.")),
                .heading(String(localized: "Finding tunes")),
                .bullets([
                    String(localized: "The sidebar has your library, then HVSC. Home has the release, what's new, the curated playlists and what you played last: **S** shuffles the whole collection and **T** plays the Top 100."),
                    String(localized: "Musicians, Demos and Games list the folders with how each sounds on average. **/** finds one as you type, **Return** opens its tunes and **Esc** comes back to the same row."),
                    String(localized: "Every tune has the same nine-bar barcode as in the app. In Sounds Like, the tune being compared sits over the column, so you can see why each one matched. A row of dots means no fingerprint yet."),
                    String(localized: "Downloading the collection happens in the app."),
                ]),
                .link(.topic(.readingFingerprints)),
                .heading(String(localized: "Describe")),
                .paragraph(String(localized: "The Describe row in the sidebar makes a Smart Playlist from a sentence, or from New to Me, Never Heard, Similar to a Tune and Slow to Intense. It reads sentences just as the app does, and the app's Smart Playlist pane follows along. **Return** plays from a tune, **/** changes the sentence, **n** saves the list as a playlist and **Esc** starts over.")),
                .link(.topic(.smartPlaylists)),
                .heading(String(localized: "The music, full screen")),
                .paragraph(String(localized: "Press **v** for the music, laid out like Now Playing in the app. The picker and the keys disappear after three seconds without a key press. **v** steps through the views, or go straight to one:")),
                .bullets([
                    String(localized: "**s**: a skull in ASCII, whose eyes glow with the voices and whose jaw chomps on the hits."),
                    String(localized: "**f**: fire, where each voice feeds its own part of the flames and hits throw sparks."),
                    String(localized: "**t**: Tesla coils, where each voice's pitch sets how high its lightning strikes."),
                    String(localized: "**w**: a pool, where each new note drops in: low notes make wide ripples, high notes tight ones."),
                    String(localized: "**o**: the app's Particles sphere."),
                ]),
                .paragraph(String(localized: "With fire and the pool, **c** colors them by voice, to see which is which.")),
                .heading(String(localized: "Under the hood")),
                .paragraph(String(localized: "**u** slides up a tracker over the list: what the player writes to the chip, rebuilt by running the tune once, with the row being heard in the middle. **↑** and **↓** look around, **f** follows the music again, and **Esc** closes it. **Tab** steps on to Registers, Sweeps and Pitch, which show every SID of a tune with more than one where there's room. In the tracker, or when there isn't room, **1**, **2** and **3** switch between them.")),
                .heading(String(localized: "Vim and Emacs keys")),
                .paragraph("The terminal app has Normal, Vim and Emacs keys, set apart from the window's. Without a choice it goes by your **$VISUAL**, then **$EDITOR**: Vim and Neovim mean Vim keys, anything else means Emacs keys. To choose, run **resonance --keys vim**, or set it for good in your shell:"),
                .code("export RESONANCE_KEYS=vim    # or emacs, or normal"),
                .heading(String(localized: "Credits")),
                .paragraph(String(localized: "Press **c** outside the music, or run **resonance credits**. They close by themselves, or with **Esc**.")),
            ],
            related: [.commands, .readingFingerprints, .shortcuts]
        ),
        HelpTopic(
            id: .commands, group: .integrations,
            title: String(localized: "Commands and Scripts"), symbol: "chevron.left.forwardslash.chevron.right",
            summary: String(localized: "A remote control for Resonance, for your shell and your scripts."),
            blocks: [
                .paragraph(String(localized: "With a command after it, **resonance** does that one thing and returns. Run **resonance --help** for all of them.")),
                .code("""
                resonance play | pause | toggle | stop | next | prev
                resonance now
                resonance fav
                resonance surprise
                resonance search commando --play
                resonance like --play
                resonance drift
                resonance describe fast arpeggios from 1987
                resonance recent
                """),
                .heading(String(localized: "Playlists")),
                .code("""
                resonance playlist list
                resonance playlist play "Late Night"
                resonance playlist add "Late Night" file.sid
                resonance playlist rm "Late Night" file.sid
                """),
                .heading(String(localized: "In your own scripts")),
                .bullets([
                    String(localized: "Piped, lists print tab-separated with the path first, and anything that answers takes **--json**."),
                    String(localized: "**playlist add**, **new** and **rm** read paths from a pipe."),
                    String(localized: "**resonance pick** opens a small list to choose from and prints the paths, for use inside other commands."),
                ]),
                .code("""
                resonance search hubbard | resonance playlist add Hubbard
                resonance playlist add "Late Night" $(resonance pick --multi)
                """),
                .heading(String(localized: "zsh and Oh My Zsh")),
                .paragraph("The [zsh plugin](https://github.com/ErikLuimes/resonance/tree/main/apple/cli/zsh) adds completions, with your playlists' names too, and short commands: **rn**, **rp**, **rs**, **rl**, **rf** and **rq**. **rdone make release** gives you a surprise when something slow ends, and **resonance_prompt_info** puts what's playing in your prompt."),
            ],
            related: [.terminal, .assistants]
        ),
        HelpTopic(
            id: .assistants, group: .integrations,
            title: String(localized: "Claude and Assistants"), symbol: "sparkles",
            summary: String(localized: "Ask an assistant for what you'd like to hear."),
            blocks: [
                .paragraph(String(localized: "Resonance's command line tool can serve the Model Context Protocol, so an assistant can search, play, make playlists, open HVSC's own playlists and start a drift. Then you can ask for “something like Commando but darker”, or who on HVSC Favorite Top 100 still makes music.")),
                .heading(String(localized: "Connect Claude Code")),
                .steps([
                    String(localized: "Install the command line tool in Settings → Integrations."),
                    String(localized: "Click **Copy Command** there."),
                    String(localized: "Paste it into a terminal and press Return."),
                ]),
                .link(.settings(.integrations)),
                .paragraph(String(localized: "For another assistant that speaks the protocol, give it the tool's full path, with **mcp** after it, as the command to run.")),
                .heading(String(localized: "What it can do")),
                .bullets([
                    String(localized: "Find tunes by title or composer, by words for a mood or style, and by how they sound."),
                    String(localized: "See what's playing and what you played recently, and how a tune sounds."),
                    String(localized: "Play, pause and skip, Surprise Me and Sound Drift, and favorite the tune playing."),
                    String(localized: "Make playlists, play them, and add tunes to them or take tunes out. It can't delete a playlist."),
                ]),
                .note(title: String(localized: "What the assistant sees"),
                      text: String(localized: "Resonance only answers on your Mac, but what your assistant reads, such as playlist names and what you've played, goes wherever that assistant sends what you ask it.")),
            ],
            related: [.commands, .soundsLike, .smartPlaylists]
        ),
        HelpTopic(
            id: .raycast, group: .integrations,
            title: String(localized: "Raycast"), symbol: "command",
            summary: String(localized: "Search, play and discover from Raycast, without opening a window."),
            blocks: [
                .paragraph(String(localized: "Install **Resonance** from the Raycast Store. It doesn't need the command line tool, and if Resonance isn't running, it starts in the background.")),
                .bullets([
                    String(localized: "**Search Tunes**: find tunes by title or composer, and see how each one sounds."),
                    String(localized: "**Sounds Like This**: tunes that sound like the one playing."),
                    String(localized: "**Describe Sound**: a list from words, such as “fast arpeggios from 1987”."),
                    String(localized: "**Now Playing**: the tune playing and how it sounds, with its controls."),
                    String(localized: "**Playlists** and **Recently Played**: open and play Favorites and your playlists, or go back to a tune."),
                    String(localized: "**Play or Pause**, **Next Tune**, **Previous Tune**, **Surprise Me** and **Favorite Tune** do their work without opening a window."),
                ]),
                .paragraph(String(localized: "Give the ones you use most a hotkey or an alias in Raycast's settings. Search Tunes and Describe Sound take what you type after their alias.")),
                .heading(String(localized: "In a list of tunes")),
                .paragraph(String(localized: "**Return** plays from that tune on. **⌘L** shows what sounds like it, **⌘D** shows or hides how it sounds, and **⌘K** has the rest: Sound Drift, Add to Playlist and Show in Resonance. With the sound pane closed, each row shows the tune's fingerprint.")),
            ],
            related: [.soundsLike, .readingFingerprints]
        ),
        HelpTopic(
            id: .siriAndSpotlight, group: .integrations,
            title: String(localized: "Siri and Spotlight"), symbol: "magnifyingglass",
            summary: String(localized: "Ask Siri, build your own shortcuts, and find tunes from anywhere."),
            blocks: [
                .heading(String(localized: "Siri")),
                .bullets([
                    String(localized: "“Surprise me in Resonance”"),
                    String(localized: "“Play something like this in Resonance”"),
                    String(localized: "“Drift from this tune in Resonance”"),
                    String(localized: "“Favorite this tune in Resonance”"),
                    String(localized: "“Play Favorites in Resonance”, or the name of one of your playlists"),
                ]),
                .heading(String(localized: "Shortcuts")),
                .paragraph(String(localized: "The Shortcuts app has these actions too, and **Play or Pause** and **Next Track**, for your own shortcuts and automations.")),
                .heading(String(localized: "Spotlight")),
                .paragraph(String(localized: "Spotlight finds the collection's tunes by title and composer: click one to play it. To keep them out of Spotlight, turn Resonance off in System Settings → Spotlight.")),
                .heading(String(localized: "Quick Look")),
                .paragraph(String(localized: "In Finder, select a SID file and press Space to see its title, composer, release and subtunes.")),
                .link(.settings(.integrations)),
            ],
            related: [.dock, .nowPlaying]
        ),
        HelpTopic(
            id: .dock, group: .integrations,
            title: String(localized: "Dock and Notifications"), symbol: "dock.rectangle",
            summary: String(localized: "The controls on the Dock icon, and word when something long ends."),
            blocks: [
                .heading(String(localized: "The Dock menu")),
                .paragraph(String(localized: "Control-click Resonance's Dock icon for the tune playing, to play, pause or skip, and for **Play Something Like This**, **Drift From This Tune** and **Surprise Me**.")),
                .heading(String(localized: "Progress")),
                .paragraph(String(localized: "While the collection downloads or the fingerprint scan runs, the Dock icon shows how far it has gotten.")),
                .heading(String(localized: "Notifications")),
                .paragraph(String(localized: "If Resonance is in the background when a download or a long scan ends, or a download fails, it sends a notification. Clicking a download's opens the HVSC Home, and a failed one also offers Retry. Resonance asks for permission the first time; change your mind in System Settings → Notifications.")),
                .link(.settings(.integrations)),
            ],
            related: [.gettingStarted, .siriAndSpotlight, .nowPlaying]
        ),
        HelpTopic(
            id: .shortcuts, group: .reference,
            title: String(localized: "Keyboard Shortcuts"), symbol: "keyboard",
            summary: String(localized: "Every Playback command has a key."),
            blocks: [
                .paragraph(String(localized: "Press **?** in the main window to see every shortcut on a panel. A key still works with the panel open, so you can try one. Move through the rows with the arrow keys, press **Return** to run one, and press **Esc** to close it.")),
                .shortcuts(KeyAction.columns.flatMap(\.actions).map {
                    HelpShortcut(keys: $0.binding(in: .normal).label, action: $0.helpPageTitle)
                }),
                .heading(String(localized: "Vim and Emacs Keys")),
                .paragraph(String(localized: "Choose **Vim** or **Emacs** at the top of the panel, with **Tab** there, or in Settings under General. They add keys of their own, such as **j** and **k** or **⌃N** and **⌃P** to move through a list, and the panel shows them. The menus' shortcuts keep working, and text fields keep their keys while you type.")),
                .paragraph(String(localized: "The Playback menu also has Repeat and Shuffle Collection. Your keyboard's media keys work too.")),
            ],
            related: [.nowPlaying, .library]
        ),
        HelpTopic(
            id: .settings, group: .reference,
            title: String(localized: "Settings"), symbol: "gearshape",
            summary: String(localized: "What each page of Settings does."),
            blocks: [
                .heading(String(localized: "Updates")),
                .paragraph(String(localized: "Which releases you get (Stable, Beta or Alpha), whether Resonance checks for a new version and installs it by itself, and a way to check now. If an update fails, the reason is at the top, with a button to copy the details for a bug report.")),
                .link(.settings(.updates)),
                .heading(String(localized: "General")),
                .paragraph(String(localized: "What Resonance opens on, whether the menu bar player shows, and the Normal, Vim or Emacs keys.")),
                .link(.settings(.general)),
                .heading(String(localized: "Appearance")),
                .paragraph(String(localized: "Light, Dark, or Auto to follow your Mac, for Resonance only. Now Playing and Under the Hood stay dark in all three. Below that, the visualizers' theme, your own colors, and whether the theme badge shows.")),
                .link(.settings(.appearance)),
                .heading(String(localized: "Engine")),
                .paragraph(String(localized: "Two software emulations, both following each tune's header for PAL or NTSC and the chip model, and both able to scrub within a tune. **reSIDfp**, the default, is the most accurate: libsidplayfp's reference C64 and chip emulation. **SIDLite direct** is a compact chip model, the lightest on the processor. Changing the engine restarts the tune.")),
                .link(.settings(.engine)),
                .heading(String(localized: "Playback")),
                .bullets([
                    String(localized: "**Skip RSID tunes**, and the **default song length** for tunes whose length isn't known (0 plays until silence)."),
                    String(localized: "**Stereo**: play 2SID tunes in mirrored stereo."),
                ]),
                .link(.settings(.playback)),
                .heading(String(localized: "Collection")),
                .bullets([
                    String(localized: "The HVSC folder: choose another."),
                    String(localized: "The release you have, updates, and downloading the collection again to restore missing or damaged files."),
                ]),
                .link(.settings(.collection)),
                .heading(String(localized: "Fingerprints")),
                .paragraph(String(localized: "How far the scan has gotten, Pause and Resume, Rebuild All, and the published set.")),
                .link(.settings(.fingerprints)),
                .heading(String(localized: "History")),
                .paragraph(String(localized: "Clear Recently Played, or reset the count of SIDs you've heard.")),
                .link(.settings(.history)),
                .heading(String(localized: "Integrations")),
                .paragraph(String(localized: "Install the command line tool and copy the command that connects Claude Code. Below that, what already works without setting up, such as Siri, Spotlight and Quick Look, with links to where macOS keeps their switches.")),
                .link(.settings(.integrations)),
                .heading(String(localized: "Storage and Reset")),
                .paragraph(String(localized: "**Data Folder** shows how much Resonance's folder holds, and opens it in Finder. **Reset** moves the collection Resonance downloaded to the Trash, or resets everything: Resonance's folder goes to the Trash, its settings are forgotten, and it restarts fresh.")),
                .link(.settings(.storage)),
            ],
            related: [.gettingStarted, .terminal, .troubleshooting]
        ),
        HelpTopic(
            id: .troubleshooting, group: .reference,
            title: String(localized: "Troubleshooting"), symbol: "lifepreserver",
            summary: String(localized: "When something doesn't work as it should."),
            blocks: [
                .heading(String(localized: "Musicians, Games or Demos says it can't read the folder")),
                .paragraph(String(localized: "The HVSC folder has moved, or isn't the one that holds MUSICIANS, GAMES and DEMOS. Choose the right one in Settings → Collection.")),
                .link(.settings(.collection)),
                .heading(String(localized: "Tunes are missing or won't play")),
                .paragraph(String(localized: "In Settings → Collection, **Download Again…** fetches the whole collection and restores missing or damaged files. The tunes already there are kept.")),
                .heading(String(localized: "Sounds Like says a tune isn't fingerprinted")),
                .paragraph(String(localized: "The scan hasn't reached it yet. Check Settings → Fingerprints: is the scan paused? Click **Download** next to Published set to fetch the fingerprints of all of HVSC. If some tunes couldn't be scanned, **Retry** tries them again.")),
                .heading(String(localized: "A tune stops too soon, or plays on and on")),
                .paragraph(String(localized: "Song lengths come from HVSC's Songlengths database. For tunes it doesn't know, such as ones from outside HVSC, Resonance figures out the length in the background by running the tune and listening for it to end or start over; those lengths show with a ~ and can be off. Until then, or if it can't tell, a tune plays for the default song length in Settings → Playback. Some tunes sound different on another engine: try switching between reSIDfp and SIDLite direct.")),
                .heading(String(localized: "The HVSC download stopped")),
                .paragraph(String(localized: "Click **Retry** in the message at the top of the window. A download that was canceled starts over from Download next to Collection.")),
                .heading(String(localized: "The terminal says it can't find resonance")),
                .paragraph(String(localized: "Install it from Settings → Integrations. If it's in ~/.local/bin, Settings has a line to copy that adds the folder to your PATH, and a new terminal window then finds it. If another program already has the name **resonance** in a folder, the tool goes in the next one. Settings tells you if your terminal may still run the other program, or if no folder is free.")),
                .link(.settings(.integrations)),
                .heading(String(localized: "An assistant can't reach Resonance")),
                .paragraph(String(localized: "Assistants need the command line tool. Install it, then use **Copy Command** in Settings → Integrations again: it has the tool's full path, because an assistant may not look in the same folders as your terminal.")),
                .heading(String(localized: "An update failed")),
                .paragraph(String(localized: "Settings → Updates gives the reason at the top, and **Copy Details** copies what a bug report needs. An update that didn't install shows there the next time Resonance opens.")),
                .link(.settings(.updates)),
                .note(title: String(localized: "Still stuck?"),
                      text: String(localized: "Resonance is in alpha. Report problems on GitHub, from Help → Report a Problem, with what you did and what happened.")),
            ],
            related: [.settings, .gettingStarted, .terminal, .assistants]
        ),
    ]
}
