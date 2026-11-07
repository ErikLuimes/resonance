//! The terminal app: `resonance` on its own. Sidebar, tune list, what's playing
//! and the three voices. `App` holds the state and answers keys and replies with
//! requests to send, so it can be tested with no terminal and no Resonance.

use crate::client::Client;
use crate::credits;
use crate::fingerprint;
use crate::fire::Fire;
use crate::header;
use crate::keys::{edit_line, Choice, KeyMap, KeyScheme};
#[cfg_attr(not(test), allow(unused_imports))]
use crate::model::HvscPlaylist;
use crate::model::{clock, Described, HvscOverview, TrackerPosition, TrackerSong, PlaylistInfo, Print, Scope, Status, Tune};
use crate::palette::{self, dim};
use crate::skull::{terminal_has_truecolor, Skull};
use crate::sphere::Sphere;
use crate::tesla::Tesla;
use crate::viz::{self, Ears};
use crate::water::Water;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Clear, List, ListItem, ListState, Paragraph, Row, Table, TableState};
use ratatui::Frame;
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const DEBOUNCE: Duration = Duration::from_millis(120);
const SCOPE_EVERY: Duration = Duration::from_millis(50);
const STATUS_EVERY: Duration = Duration::from_millis(500);
/// The most the app gives. Telling a pitch takes two whole cycles, and this is 46 ms,
/// so down to about 44 Hz: the deepest SID bass lines, with a level for anything lower.
const SCOPE_SAMPLES: usize = 2048;
/// A pause on a tune before asking how it sounds, so moving down a list stays quick.
const DETAILS_AFTER: Duration = Duration::from_millis(200);
const DETAILS_KEPT: usize = 500;
const LIKE_SHOWN: usize = 4;
/// From this wide the Sounds Like panel fits beside the list; below the other, the
/// sidebar takes the list's place while it has the focus.
const RAIL_FROM: u16 = 110;
const SIDEBAR_FROM: u16 = 70;
/// The outer columns' shares of the window's width, from what their text needs at
/// least to what's still comfortable to read; the list has the rest.
const SIDEBAR_SHARE: (u16, u16, u16) = (16, 28, 48);
const RAIL_SHARE: (u16, u16, u16) = (24, 40, 72);
/// How many rows either side of the cursor to know the fingerprints of: more than
/// a window shows. Asked for this often at most, however fast the cursor moves.
const PRINTS_AROUND: usize = 60;
const PRINTS_EVERY: Duration = Duration::from_millis(100);
const PRINTS_KEPT: usize = 5000;
/// The list makes room for a barcode by giving up the composer, who's in the side
/// panel anyway, as it narrows.
const COMPOSER_FROM: u16 = 60;
/// The help screen: its keys, and the fingerprint legend beside or under them.
const HELP_WIDTH: u16 = 62;
const HELP_HEIGHT: u16 = 24;
const LEGEND_WIDTH: u16 = 40;

#[derive(Debug, Clone, PartialEq)]
pub enum View {
    Search,
    Recent,
    Playlist(String),
    /// Sounds Like, by the seed's title.
    Like(String),
    /// A Smart Playlist from a sentence.
    Describe,
    /// HVSC's front door.
    HvscHome,
    /// A section's composers or folders: "musicians", "demos" or "games".
    Hvsc(&'static str),
    /// A composer's tunes, and the section and row to go back to.
    Composer { section: &'static str, path: String, title: String, back_to: usize },
    /// A curated playlist, by its file.
    Curated { file: String, name: String },
}

/// Search, Describe and Recently Played, in a section of their own above the playlists.
const FIXED_ROWS: usize = 3;
/// What Describe offers before there's a list, and the sentence each one is. Similar
/// to a Tune has none: it asks for the tune that's playing.
const SUGGESTIONS: [(&str, &str, &str); 4] = [
    ("New to Me", "new to me", "unlike what you usually play"),
    ("Never Heard", "never heard", "tunes you haven't played yet"),
    ("Similar to a Tune", "", "the closest to the one playing"),
    ("Slow to Intense", "slow to intense", "starts calm and builds"),
];
/// How long Under the hood takes to slide up or away, and how often it asks what's heard.
const DRAWER_SLIDES: Duration = Duration::from_millis(220);
const POSITION_EVERY: Duration = Duration::from_millis(33);
/// Under the hood's side panel needs this much room beside the rows.
const TRACKER_PANEL_FROM: u16 = 84;
/// The tabs: their names, in order.
const DRAWER_TABS: [&str; 4] = ["Tracker", "Registers", "Sweeps", "Pitch"];
/// Frames kept for Sweeps and Pitch, as many as the app will give: about 10 seconds.
const DRAWER_HISTORY: usize = 512;
/// A register stays lit this many frames after it changes.
const FLASH_FRAMES: u64 = 6;
/// $00–$1C, for each chip.
const CHIP_REGISTERS: usize = 29;
/// Room for a line per voice with the filter's line whole.
const VOICE_LINES_WIDTH: u16 = 66;
/// Room for the bars as well.
const VOICE_BARS_WIDTH: u16 = 90;
/// What the Registers tab calls each voice's registers and each control bit.
const VOICE_REGISTERS: [&str; 7] = ["FREQ LO", "FREQ HI", "PW LO", "PW HI", "CTRL", "AD", "SR"];
const CONTROL_BITS: [&str; 8] = ["GATE", "SYNC", "RING", "TST", "TRI", "SAW", "PUL", "NOI"];
/// HVSC's rows in the sidebar, under the library's.
const HVSC_ROWS: [(&str, Option<&str>); 4] = [("Home", None), ("Musicians", Some("musicians")), ("Demos", Some("demos")), ("Games", Some("games"))];
/// Holds the logo before making room for the player, and how long that takes.
const SPLASH_FOR: Duration = Duration::from_secs(2);
const SPLASH_LEAVES: Duration = Duration::from_millis(600);

/// The pages of the full-screen visuals.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Page {
    Skull,
    Fire,
    Tesla,
    Water,
    Sphere,
}

impl Page {
    fn next(self) -> Page {
        match self {
            Page::Skull => Page::Fire,
            Page::Fire => Page::Tesla,
            Page::Tesla => Page::Water,
            Page::Water => Page::Sphere,
            Page::Sphere => Page::Skull,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Page::Skull => "Skull",
            Page::Fire => "Fire",
            Page::Tesla => "Tesla",
            Page::Water => "Water",
            Page::Sphere => "Sphere",
        }
    }
}

/// What the Sounds Like panel knows of a tune, as the answers come in.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Details {
    pub summary: Option<String>,
    /// The fingerprint in detail, for the panel to draw.
    pub print: Option<Print>,
    pub likes: Option<Vec<Tune>>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Focus {
    Sidebar,
    List,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Tag {
    Lists,
    Rows(u64),
    Status,
    Scope,
    /// How the tune at this path sounds.
    Sound(String),
    /// The tunes most like the one at this path.
    Alike(String),
    /// The fingerprints of these, for the barcodes.
    Prints(Vec<String>),
    /// The fingerprint in detail of the tune at this path.
    Detail(String),
    /// The collection's front door.
    HvscInfo,
    /// A tune rebuilt as a tracker would show it.
    TrackerSong,
    /// What's being heard.
    TrackerPosition,
    /// A list from a sentence, by when it was asked for; `seeded` if from what's playing.
    Described { asked: u64, seeded: bool },
    /// Favourites starting for the credits; if it can't, Surprise Me does.
    CreditsMusic,
    /// Nothing to read in the answer: say this, and maybe refresh.
    Ack { message: Option<String>, reload: bool },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub tag: Tag,
    pub cmd: &'static str,
    pub args: Value,
}

pub enum Mode {
    Normal,
    Search,
    NewPlaylist(String),
    AddTo(usize),
    Browser(Browser),
    Help,
    Visual,
    /// When they started.
    Credits(Instant),
    /// The logo, from when it appeared.
    Splash(Instant),
    /// Typing to find a composer.
    Jump(String),
    /// Typing what you'd like to hear.
    Describing(String),
    /// Under the hood, from when it started sliding up.
    Drawer(Instant),
    /// Under the hood sliding away, from when it started.
    DrawerClosing(Instant),
    /// Reading the update announcement, this many lines down.
    Reading(usize),
}

/// Under the hood's tune, kept while it's closed as it takes a moment to rebuild.
#[derive(Debug, Default)]
struct TrackerState {
    song: Option<TrackerSong>,
    /// The tune and chip it's for, or being asked for.
    tune: Option<(String, u32, u32)>,
    asking: bool,
    problem: Option<String>,
    position: TrackerPosition,
    /// The row looked at, when not following what's playing.
    looking_at: Option<usize>,
    tab: usize,
    chip: u32,
    /// Recent frames' registers, every chip's in turn, newest last, and their last frame's number.
    history: std::collections::VecDeque<Vec<u8>>,
    last_frame: Option<u64>,
    /// The frame each register last changed on, in the same order.
    changed: Vec<u64>,
    /// True when the last draw had no room for every chip, so it showed the chosen one.
    collapsed: std::cell::Cell<bool>,
}

impl TrackerState {
    fn take_frames(&mut self, frames: &[crate::model::PositionFrame]) {
        // Back to the start: a new tune, a new subtune or a rewind. Only the newest frame
        // can say so, as each answer overlaps the one before.
        if let (Some(newest), Some(last)) = (frames.last(), self.last_frame) {
            if newest.i < last {
                self.history.clear();
                self.last_frame = None;
                self.changed.clear();
            }
        }
        for frame in frames {
            if self.last_frame.is_some_and(|last| frame.i <= last) {
                continue;
            }
            let registers = frame.registers();
            // Another number of chips is another tune, whatever its frame number says.
            if self.history.back().is_some_and(|before| before.len() != registers.len()) {
                self.history.clear();
                self.changed.clear();
            }
            self.changed.resize(registers.len(), 0);
            if let Some(before) = self.history.back() {
                for (n, (old, new)) in before.iter().zip(&registers).enumerate() {
                    if old != new {
                        self.changed[n] = frame.i;
                    }
                }
            }
            self.history.push_back(registers);
            while self.history.len() > DRAWER_HISTORY {
                self.history.pop_front();
            }
            self.last_frame = Some(frame.i);
        }
    }

    fn lit(&self, register: usize) -> bool {
        let changed = self.changed.get(register).copied().unwrap_or(0);
        self.last_frame.is_some_and(|last| changed > 0 && last.saturating_sub(changed) < FLASH_FRAMES)
    }

    /// True on the tracker, and on the other tabs when there's no room for every chip.
    fn one_chip_shows(&self) -> bool {
        self.tab == 0 || self.collapsed.get()
    }

    /// How many chips the frames hold.
    fn chips(&self) -> usize {
        self.history.back().map_or(1, |frame| (frame.len() / CHIP_REGISTERS).max(1))
    }

    fn clock(&self) -> f64 {
        // PAL's 50 frames a second, unless the tune's known to be NTSC.
        if self.song.as_ref().is_some_and(|song| song.frame_rate > 55.0) { 1_022_727.0 } else { 985_248.0 }
    }
}

/// Describe's sentence and list, kept while you look at other things.
#[derive(Debug, Default)]
struct DescribeState {
    sentence: String,
    title: String,
    note: Option<String>,
    understood: Option<String>,
    facts: Option<String>,
    tunes: Vec<Tune>,
    problem: Option<String>,
    busy: bool,
    asked: u64,
}

/// What can be chosen on HVSC's Home.
#[derive(Debug, Clone, PartialEq)]
enum HomeItem {
    Section(usize),
    Announcement,
    Playlist(usize),
}

pub struct Browser {
    pub dir: PathBuf,
    pub entries: Vec<(String, bool)>,
    pub cursor: usize,
    pub marked: BTreeSet<PathBuf>,
}

fn is_tune(name: &str) -> bool {
    let lower = name.to_lowercase();
    [".sid", ".psid", ".rsid", ".mus"].iter().any(|e| lower.ends_with(e))
}

impl Browser {
    pub fn open(dir: PathBuf) -> Browser {
        let mut browser = Browser { dir, entries: Vec::new(), cursor: 0, marked: BTreeSet::new() };
        browser.read();
        browser
    }

    fn read(&mut self) {
        let mut entries: Vec<(String, bool)> = std::fs::read_dir(&self.dir)
            .map(|found| {
                found
                    .filter_map(Result::ok)
                    .filter_map(|e| {
                        let name = e.file_name().to_string_lossy().into_owned();
                        if name.starts_with('.') {
                            return None;
                        }
                        // Through links, as HVSC folders may be.
                        let is_dir = e.path().is_dir();
                        (is_dir || is_tune(&name)).then_some((name, is_dir))
                    })
                    .collect()
            })
            .unwrap_or_default();
        entries.sort_by_key(|(name, is_dir)| (!*is_dir, name.to_lowercase()));
        self.entries = entries;
        self.cursor = 0;
    }

    fn up(&mut self) {
        if let Some(parent) = self.dir.parent().map(Path::to_path_buf) {
            self.dir = parent;
            self.read();
        }
    }
}

pub struct App {
    pub lists: Vec<PlaylistInfo>,
    pub sidebar: usize,
    pub view: View,
    pub rows: Vec<Tune>,
    pub cursor: usize,
    pub marked: BTreeSet<String>,
    pub focus: Focus,
    pub mode: Mode,
    pub query: String,
    pub status: Option<Status>,
    pub message: Option<String>,
    pub quit: bool,
    hvsc: Option<HvscOverview>,
    describing: DescribeState,
    tracker: TrackerState,
    /// Opened with `resonance credits`, so they leave when they're done.
    leave_after_credits: bool,
    /// The credits have just opened, and should start something if nothing's on.
    credits_want_music: bool,
    keys: KeyMap,
    /// The set in use, as the help screen tells it.
    key_choice: Choice,
    pub outbox: Vec<Request>,
    pub search_due: Option<Instant>,
    pub skull: Skull,
    pub ears: Ears,
    pub fire: Fire,
    pub tesla: Tesla,
    pub water: Water,
    pub sphere: Sphere,
    /// Whether fire and water show which voice each flame or ripple came from.
    pub channels: bool,
    pub page: Page,
    pub details: HashMap<String, Details>,
    /// Whether the Sounds Like panel is on screen, so worth asking for.
    pub rail_showing: bool,
    /// Whether to draw barcodes, and so ask for them.
    pub prints_wanted: bool,
    /// What's known: nothing yet, once asked, or no fingerprint.
    prints: HashMap<String, Option<Vec<f32>>>,
    prints_next: Option<Instant>,
    /// The app is older than the barcodes, so it can't answer.
    prints_off: bool,
    /// What Sounds Like is showing tunes like.
    like_seed: Option<String>,
    details_for: Option<String>,
    details_due: Option<Instant>,
    now: Option<Instant>,
    /// When a key was last pressed.
    last_key: Option<Instant>,
    /// The tune the tags are for, and those tags: what the SID file itself says.
    tags: Option<(String, Vec<String>)>,
    status_at: Option<Instant>,
    generation: u64,
}

impl App {
    pub fn new() -> App {
        let mut app = App {
            lists: Vec::new(),
            sidebar: FIXED_ROWS,
            view: View::Playlist("Favourites".into()),
            rows: Vec::new(),
            cursor: 0,
            marked: BTreeSet::new(),
            focus: Focus::List,
            mode: Mode::Normal,
            query: String::new(),
            status: None,
            message: None,
            quit: false,
            hvsc: None,
            describing: DescribeState::default(),
            tracker: TrackerState::default(),
            leave_after_credits: false,
            credits_want_music: false,
            keys: KeyMap::default(),
            key_choice: Choice { scheme: KeyScheme::Normal, reason: "the app's own" },
            outbox: Vec::new(),
            search_due: None,
            skull: Skull::new(terminal_has_truecolor()),
            ears: Ears::default(),
            fire: Fire::default(),
            tesla: Tesla::default(),
            water: Water::default(),
            sphere: Sphere::default(),
            channels: false,
            page: Page::Skull,
            details: HashMap::new(),
            rail_showing: false,
            prints_wanted: false,
            last_key: None,
            tags: None,
            prints: HashMap::new(),
            prints_next: None,
            prints_off: false,
            like_seed: None,
            details_for: None,
            details_due: None,
            now: None,
            status_at: None,
            generation: 0,
        };
        app.send(Tag::Lists, "playlist.list", json!({}));
        app.reload();
        app
    }

    fn send(&mut self, tag: Tag, cmd: &'static str, args: Value) {
        self.outbox.push(Request { tag, cmd, args });
    }

    fn ack(&mut self, message: Option<String>, reload: bool, cmd: &'static str, args: Value) {
        self.send(Tag::Ack { message, reload }, cmd, args);
    }

    /// Search, Recently Played, then Favourites and your playlists.
    pub fn sidebar_entries(&self) -> Vec<String> {
        let mut entries = vec!["Search".to_string(), "Describe".to_string(), "Recently Played".to_string()];
        entries.extend(self.lists.iter().map(|l| l.name.clone()));
        entries.extend(HVSC_ROWS.iter().map(|(name, _)| name.to_string()));
        entries
    }

    fn library_rows(&self) -> usize {
        FIXED_ROWS + self.lists.len()
    }

    /// The rows of a list of tunes, as against composers or Home.
    fn showing_tunes(&self) -> bool {
        !matches!(self.view, View::HvscHome | View::Hvsc(_))
    }

    pub fn ask_about_hvsc(&mut self) {
        self.send(Tag::HvscInfo, "hvsc.info", json!({}));
    }

    fn home_items(&self) -> Vec<HomeItem> {
        let mut items: Vec<HomeItem> = vec![HomeItem::Section(1), HomeItem::Section(2), HomeItem::Section(3)];
        let Some(info) = &self.hvsc else { return items };
        if info.update.is_some() {
            items.push(HomeItem::Announcement);
        }
        items.extend((0..info.playlists.len()).map(HomeItem::Playlist));
        items
    }

    fn go_to_hvsc(&mut self, row: usize) {
        self.sidebar = self.library_rows() + row;
        self.open_sidebar();
    }

    fn open_home_item(&mut self) {
        match self.home_items().get(self.cursor).cloned() {
            Some(HomeItem::Section(row)) => self.go_to_hvsc(row),
            Some(HomeItem::Announcement) => self.mode = Mode::Reading(0),
            Some(HomeItem::Playlist(n)) => {
                let Some(list) = self.hvsc.as_ref().and_then(|info| info.playlists.get(n)).cloned() else { return };
                self.view = View::Curated { file: list.file, name: list.name };
                self.cursor = 0;
                self.reload();
            }
            None => {}
        }
    }

    fn open_composer(&mut self, section: &'static str) {
        let Some(composer) = self.rows.get(self.cursor).cloned() else { return };
        self.view = View::Composer { section, path: composer.path, title: composer.title, back_to: self.cursor };
        self.cursor = 0;
        self.marked.clear();
        self.reload();
    }

    /// True while the drawer needs to know what's being heard.
    fn wants_position(&self) -> bool {
        matches!(self.mode, Mode::Drawer(_))
    }

    /// What to ask for: everything there is the first time, then just what's new.
    fn position_args(&self) -> Value {
        let count = if self.tracker.history.is_empty() { DRAWER_HISTORY } else { 8 };
        json!({ "count": count, "chip": self.tracker.chip })
    }

    fn position_answered(&mut self, position: TrackerPosition) {
        let tune = position.path.clone().map(|path| (path, position.song, self.tracker.chip));
        // The frames hold every chip, but the rest is about the chip it was asked about.
        self.tracker.take_frames(&position.frames);
        if position.chip != self.tracker.chip {
            return;
        }
        self.tracker.position = position;
        if tune.is_none() {
            return;
        }
        if tune != self.tracker.tune {
            self.tracker.tune = tune;
            self.tracker.song = None;
            self.tracker.problem = None;
            self.tracker.looking_at = None;
            self.tracker.asking = true;
            let chip = self.tracker.chip;
            self.send(Tag::TrackerSong, "tracker.song", json!({ "chip": chip }));
        }
    }

    fn tracker_row(&self) -> usize {
        let Some(song) = &self.tracker.song else { return 0 };
        self.tracker.looking_at.unwrap_or_else(|| song.row_at(self.tracker.position.heard.unwrap_or(0.0)))
    }

    fn look_by(&mut self, by: isize) {
        let Some(last) = self.tracker.song.as_ref().map(|s| s.rows.len().saturating_sub(1)) else { return };
        self.tracker.looking_at = Some(self.tracker_row().saturating_add_signed(by).min(last));
    }

    fn switch_chip(&mut self, chip: u32) {
        if chip != self.tracker.chip && chip < self.tracker.position.chips.max(1) {
            self.tracker.chip = chip;
        }
    }

    fn key_drawer(&mut self, key: KeyEvent, since: Instant) {
        self.mode = Mode::Drawer(since);
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc | KeyCode::Char('u') if !ctrl => {
                self.mode = Mode::DrawerClosing(self.now.unwrap_or_else(Instant::now));
            }
            KeyCode::Char('p') if ctrl => self.look_by(-1),
            KeyCode::Char('n') if ctrl => self.look_by(1),
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Char('p') => self.ack(None, false, "toggle", json!({})),
            KeyCode::Char('>' | '.') => self.ack(None, false, "next", json!({})),
            KeyCode::Char('<' | ',') => self.ack(None, false, "prev", json!({})),
            KeyCode::Char('r') => self.ack(None, false, "surprise", json!({})),
            KeyCode::Up | KeyCode::Char('k') => self.look_by(-1),
            KeyCode::Down | KeyCode::Char('j') => self.look_by(1),
            KeyCode::PageUp => self.look_by(-16),
            KeyCode::PageDown => self.look_by(16),
            KeyCode::Tab => self.tracker.tab = (self.tracker.tab + 1) % DRAWER_TABS.len(),
            KeyCode::BackTab => self.tracker.tab = (self.tracker.tab + DRAWER_TABS.len() - 1) % DRAWER_TABS.len(),
            // The other tabs show every chip, where there's room.
            KeyCode::Char(c @ '1'..='3') if self.tracker.one_chip_shows() => self.switch_chip(c as u32 - '1' as u32),
            KeyCode::Char('s') if self.tracker.one_chip_shows() => {
                let chips = self.tracker.position.chips.max(1);
                self.switch_chip((self.tracker.chip + 1) % chips);
            }
            KeyCode::Char('f') | KeyCode::Enter | KeyCode::End => self.tracker.looking_at = None,
            KeyCode::Home => self.tracker.looking_at = Some(0),
            _ => {}
        }
    }

    fn ask_describe(&mut self, sentence: String) {
        let sentence = sentence.trim().to_string();
        if sentence.is_empty() {
            return self.clear_describe();
        }
        self.describing.sentence = sentence.clone();
        self.describing.problem = None;
        self.describing.busy = true;
        self.describing.asked += 1;
        let tag = Tag::Described { asked: self.describing.asked, seeded: false };
        self.send(tag, "describe", json!({ "text": sentence, "play": false }));
    }

    fn try_suggestion(&mut self) {
        let Some((name, sentence, _)) = SUGGESTIONS.get(self.cursor) else { return };
        if sentence.is_empty() {
            self.describing.sentence = (*name).to_string();
            self.describing.problem = None;
            self.describing.busy = true;
            self.describing.asked += 1;
            let tag = Tag::Described { asked: self.describing.asked, seeded: true };
            self.send(tag, "describe.playing", json!({}));
        } else {
            self.ask_describe((*sentence).to_string());
        }
    }

    /// Back to the empty line and the suggestions; an answer still on its way no longer counts.
    fn clear_describe(&mut self) {
        let asked = self.describing.asked + 1;
        self.describing = DescribeState { asked, ..DescribeState::default() };
        self.rows.clear();
        self.marked.clear();
        self.cursor = 0;
    }

    fn describe_answered(&mut self, seeded: bool, answer: Result<Value, String>) {
        self.describing.busy = false;
        let here = self.view == View::Describe;
        match answer.and_then(|value| serde_json::from_value::<Described>(value).map_err(|e| e.to_string())) {
            Ok(made) => {
                if seeded {
                    self.describing.sentence = made.title.clone();
                }
                self.describing.title = made.title;
                self.describing.note = made.note;
                self.describing.understood = made.understood;
                self.describing.facts = made.facts;
                self.describing.tunes = made.tunes;
                if here {
                    self.rows = self.describing.tunes.clone();
                    self.cursor = 0;
                    self.marked.clear();
                }
            }
            Err(problem) => {
                self.describing.problem = Some(problem);
                self.describing.tunes.clear();
                self.describing.note = None;
                self.describing.understood = None;
                self.describing.facts = None;
                if here {
                    self.rows.clear();
                    self.cursor = 0;
                    self.marked.clear();
                    if seeded {
                        self.describing.sentence.clear();
                        self.mode = Mode::Describing("like ".into());
                    }
                }
            }
        }
    }

    fn key_describing(&mut self, key: KeyEvent, mut text: String) {
        match key.code {
            KeyCode::Esc | KeyCode::Down => return,
            KeyCode::Enter => return self.ask_describe(text),
            _ => {
                edit_line(&mut text, key);
            }
        }
        self.mode = Mode::Describing(text);
    }

    /// Esc: one step back from a composer, a curated playlist or a described list, and
    /// otherwise leave.
    fn step_back(&mut self) {
        match self.view.clone() {
            View::Composer { section, back_to, .. } => {
                self.view = View::Hvsc(section);
                self.reload();
                self.cursor = back_to;
            }
            View::Curated { .. } => {
                self.view = View::HvscHome;
                self.reload();
                self.cursor = 0;
            }
            View::Describe if !self.describing.sentence.is_empty() || self.describing.problem.is_some() => self.clear_describe(),
            _ => self.quit = true,
        }
    }

    fn play_top_100(&mut self) {
        let top = self.hvsc.as_ref().and_then(|info| info.playlists.iter().find(|p| p.name.to_lowercase().contains("top 100")));
        if let Some(file) = top.map(|p| p.file.clone()) {
            self.ack(None, false, "hvsc.playlist.play", json!({ "name": file }));
        }
    }

    fn key_jump(&mut self, key: KeyEvent, mut text: String) {
        match key.code {
            KeyCode::Esc | KeyCode::Enter => return,
            _ => {
                edit_line(&mut text, key);
            }
        }
        let wanted = text.to_lowercase();
        if let Some(found) = self.rows.iter().position(|row| row.title.to_lowercase().contains(&wanted)) {
            self.cursor = found;
        }
        self.mode = Mode::Jump(text);
    }

    fn key_reading(&mut self, key: KeyEvent, top: usize) {
        let moved = match key.code {
            KeyCode::Esc | KeyCode::Char('q') | KeyCode::Enter => return,
            KeyCode::Up | KeyCode::Char('k') => top.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => top + 1,
            KeyCode::PageUp => top.saturating_sub(15),
            KeyCode::PageDown | KeyCode::Char(' ') => top + 15,
            KeyCode::Home => 0,
            _ => top,
        };
        self.mode = Mode::Reading(moved);
    }

    fn open_sidebar(&mut self) {
        self.view = match self.sidebar {
            0 => View::Search,
            1 => View::Describe,
            2 => View::Recent,
            n if n >= self.library_rows() => match HVSC_ROWS.get(n - self.library_rows()) {
                Some((_, Some(section))) => View::Hvsc(section),
                Some((_, None)) => View::HvscHome,
                None => return,
            },
            n => match self.lists.get(n - FIXED_ROWS) {
                Some(list) => View::Playlist(list.name.clone()),
                None => return,
            },
        };
        self.cursor = 0;
        self.marked.clear();
        self.reload();
    }

    /// Ask for the current view's tunes; older answers no longer count.
    fn reload(&mut self) {
        self.generation += 1;
        let tag = Tag::Rows(self.generation);
        match self.view.clone() {
            View::Search if self.query.is_empty() => self.rows.clear(),
            View::Search => self.send(tag, "search", json!({ "text": self.query, "limit": 200 })),
            View::Recent => self.send(tag, "recent", json!({ "limit": 200 })),
            View::Playlist(name) => self.send(tag, "playlist.show", json!({ "name": name })),
            View::Like(_) => {}
            View::Describe => {
                self.rows = self.describing.tunes.clone();
                self.cursor = self.cursor.min(self.rows.len().saturating_sub(1));
            }
            View::HvscHome => {
                self.rows.clear();
                self.ask_about_hvsc();
                self.send(tag, "recent", json!({ "limit": 4 }));
            }
            View::Hvsc(section) => {
                self.rows.clear();
                self.send(tag, "hvsc.authors", json!({ "name": section }));
            }
            View::Composer { path, .. } => {
                self.rows.clear();
                self.send(tag, "hvsc.tunes", json!({ "path": path }));
            }
            View::Curated { file, .. } => {
                self.rows.clear();
                self.send(tag, "hvsc.playlist", json!({ "name": file }));
            }
        }
    }

    pub fn tick(&mut self, now: Instant) {
        self.now = Some(now);
        self.ask_for_details(now);
        self.ask_for_prints(now);
        if let Mode::DrawerClosing(started) = self.mode {
            if now.duration_since(started) >= DRAWER_SLIDES {
                self.mode = Mode::Normal;
            }
        }
        if let Mode::Splash(started) = self.mode {
            if now.duration_since(started) >= SPLASH_FOR + SPLASH_LEAVES {
                self.mode = Mode::Normal;
            }
        }
        if let Mode::Credits(started) = self.mode {
            if now.duration_since(started).as_secs_f64() >= credits::length(self.playing()) {
                self.close_credits();
            }
        }
        if self.search_due.is_some_and(|due| now >= due) {
            self.search_due = None;
            self.cursor = 0;
            self.reload();
        }
    }

    pub fn reply(&mut self, tag: Tag, answer: Result<Value, String>) {
        let value = match answer {
            Ok(value) => value,
            Err(error) => {
                // Polling shouldn't talk over what you just did.
                match tag {
                    Tag::Scope | Tag::Status => {}
                    // Asked for on their own, so no news is shown where it was wanted.
                    Tag::Sound(path) => {
                        self.details.entry(path).or_default().summary = Some("No fingerprint yet.".into());
                    }
                    Tag::Alike(path) => self.details.entry(path).or_default().likes = Some(Vec::new()),
                    Tag::Prints(_) | Tag::Detail(_) => self.prints_off = true,
                    Tag::CreditsMusic => self.ack(None, false, "surprise", json!({})),
                    // Home says there's no collection, and the sidebar keeps quiet.
                    Tag::HvscInfo => self.hvsc = None,
                    Tag::TrackerPosition => self.tracker.problem = Some(error),
                    Tag::TrackerSong => {
                        self.tracker.asking = false;
                        self.tracker.problem = Some(error);
                    }
                    Tag::Described { asked, seeded } => {
                        if asked == self.describing.asked {
                            self.describe_answered(seeded, Err(error));
                        }
                    }
                    _ => self.message = Some(error),
                }
                return;
            }
        };
        match tag {
            Tag::Lists => {
                if let Ok(lists) = serde_json::from_value(value) {
                    self.lists = lists;
                }
            }
            Tag::Rows(generation) if generation == self.generation => {
                if let Ok(rows) = serde_json::from_value::<Vec<Tune>>(value) {
                    self.rows = rows;
                    if self.view != View::HvscHome {
                        self.cursor = self.cursor.min(self.rows.len().saturating_sub(1));
                    }
                }
            }
            Tag::Rows(_) => {}
            Tag::Status => {
                self.status = serde_json::from_value(value).ok();
                self.status_at = self.now;
                self.start_credits_music();
            }
            Tag::CreditsMusic => {}
            Tag::TrackerPosition => {
                if let Ok(position) = serde_json::from_value(value) {
                    self.position_answered(position);
                }
            }
            Tag::TrackerSong => {
                self.tracker.asking = false;
                match serde_json::from_value::<TrackerSong>(value) {
                    // One for a tune that has since moved on is for nothing.
                    Ok(song) if self.tracker.tune.as_ref().is_some_and(|(path, n, chip)| *path == song.path && *n == song.song && *chip == song.chip) => self.tracker.song = Some(song),
                    Ok(_) => self.tracker.tune = None,
                    Err(error) => self.tracker.problem = Some(error.to_string()),
                }
            }
            Tag::Described { asked, seeded } => {
                if asked == self.describing.asked {
                    self.describe_answered(seeded, Ok(value));
                }
            }
            Tag::HvscInfo => self.hvsc = serde_json::from_value(value).ok(),
            Tag::Sound(path) => {
                let summary = value.get("summary").and_then(Value::as_str).unwrap_or("No fingerprint yet.").to_string();
                self.details.entry(path).or_default().summary = Some(summary);
            }
            Tag::Alike(path) => {
                let likes = serde_json::from_value::<Vec<Tune>>(value).unwrap_or_default();
                self.details.entry(path).or_default().likes = Some(likes);
            }
            Tag::Prints(_) => {
                for print in serde_json::from_value::<Vec<Print>>(value).unwrap_or_default() {
                    self.prints.insert(print.path, Some(print.traits));
                }
            }
            Tag::Detail(path) => {
                let found = serde_json::from_value::<Vec<Print>>(value).unwrap_or_default();
                if let Some(print) = found.into_iter().next() {
                    self.prints.insert(path.clone(), Some(print.traits.clone()));
                    self.details.entry(path).or_default().print = Some(print);
                }
            }
            Tag::Scope => {
                if let Ok(scope) = serde_json::from_value::<Scope>(value) {
                    // Only while playing: a paused tune's samples stay frozen at
                    // their last levels, which would hold the eyes open.
                    if self.is_playing() {
                        self.skull.reaction.hear(&scope.voices);
                        self.ears.hear(&scope.voices);
                        let [a, b, c] = self.ears.latest();
                        self.fire.hear([a.level, b.level, c.level]);
                        self.tesla.hear([a, b, c]);
                        self.water.hear([a, b, c]);
                        self.sphere.hear([a, b, c]);
                    }
                }
            }
            Tag::Ack { message, reload } => {
                if message.is_some() {
                    self.message = message;
                }
                if reload {
                    self.send(Tag::Lists, "playlist.list", json!({}));
                    self.reload();
                }
            }
        }
    }

    fn is_playing(&self) -> bool {
        self.status.as_ref().is_some_and(|s| s.state == "playing")
    }

    /// How far into the tune, carried on between the app's less frequent answers.
    fn elapsed(&self) -> f64 {
        let Some(status) = self.status.as_ref() else { return 0.0 };
        let since = match (self.is_playing(), self.now, self.status_at) {
            (true, Some(now), Some(then)) => now.duration_since(then).as_secs_f64(),
            _ => 0.0,
        };
        let elapsed = status.elapsed + since;
        status.duration.map_or(elapsed, |duration| elapsed.min(duration))
    }

    fn progress(&self) -> Option<f64> {
        let duration = self.status.as_ref()?.duration.filter(|d| *d > 0.0)?;
        Some((self.elapsed() / duration).clamp(0.0, 1.0))
    }

    /// Once the cursor has rested, ask about its tune unless that's already known.
    fn ask_for_details(&mut self, now: Instant) {
        if !self.rail_showing || !self.showing_tunes() {
            return;
        }
        let path = self.rows.get(self.cursor).map(|t| t.path.clone());
        if path != self.details_for {
            self.details_for = path;
            self.details_due = Some(now + DETAILS_AFTER);
        }
        if self.details_due.is_none_or(|due| now < due) {
            return;
        }
        self.details_due = None;
        let Some(path) = self.details_for.clone() else { return };
        if self.details.contains_key(&path) {
            return;
        }
        if self.details.len() >= DETAILS_KEPT {
            self.details.clear();
        }
        self.details.insert(path.clone(), Details::default());
        self.send(Tag::Sound(path.clone()), "sound", json!({ "path": path }));
        self.send(Tag::Alike(path.clone()), "like", json!({ "path": path, "limit": LIKE_SHOWN }));
        if self.prints_wanted && !self.prints_off {
            self.send(Tag::Detail(path.clone()), "prints", json!({ "paths": [path], "detail": true }));
        }
    }

    /// The barcodes near the cursor, the panel's and what Sounds Like compares with.
    fn ask_for_prints(&mut self, now: Instant) {
        let listing = matches!(self.mode, Mode::Normal | Mode::Search | Mode::Describing(_));
        if !listing || !self.prints_wanted || self.prints_off || self.prints_next.is_some_and(|next| now < next) {
            return;
        }
        self.prints_next = Some(now + PRINTS_EVERY);
        // A composer's print reads all their tunes, so only those on screen, or nearly.
        let composers = matches!(self.view, View::Hvsc(_));
        let reach = if composers { 40 } else { PRINTS_AROUND };
        let around = self.rows.iter().skip(self.cursor.saturating_sub(reach)).take(reach * 2);
        let likes = self.rows.get(self.cursor).and_then(|t| self.details.get(&t.path)).and_then(|d| d.likes.as_ref());
        let missing: BTreeSet<String> = around
            .chain(likes.into_iter().flatten())
            .map(|t| &t.path)
            .chain(self.like_seed.iter())
            .filter(|path| !self.prints.contains_key(*path))
            .cloned()
            .collect();
        if missing.is_empty() {
            return;
        }
        if self.prints.len() + missing.len() > PRINTS_KEPT {
            self.prints.clear();
        }
        let paths: Vec<String> = missing.into_iter().collect();
        for path in &paths {
            self.prints.insert(path.clone(), None);
        }
        let command = if composers { "prints.composers" } else { "prints" };
        self.send(Tag::Prints(paths.clone()), command, json!({ "paths": paths }));
    }

    /// Bring the full-screen page up to date for a screen this size, if it's showing.
    pub fn prepare_visual(&mut self, now: Instant, width: u16, height: u16) {
        if !matches!(self.mode, Mode::Visual) {
            return;
        }
        self.read_tags();
        let body = visual_layout(Rect::new(0, 0, width, height)).body;
        let (width, rows) = (body.width, body.height);
        match self.page {
            Page::Fire => self.fire.advance(now, width, rows),
            Page::Tesla => self.tesla.advance(now, width, rows),
            Page::Water => self.water.advance(now, width, rows),
            Page::Sphere => self.sphere.advance(now, width, rows),
            Page::Skull => {
                let playing = self.is_playing();
                self.skull.advance(now, width, rows, playing);
            }
        }
    }

    /// The tags come from the file, so once for each tune.
    fn read_tags(&mut self) {
        let Some(path) = self.status.as_ref().and_then(|s| s.now.as_ref()).map(|n| n.path.clone()) else {
            self.tags = None;
            return;
        };
        if self.tags.as_ref().is_some_and(|(known, _)| *known == path) {
            return;
        }
        let header = std::fs::read(&path).ok().and_then(|data| crate::sid::parse(&data));
        let tags = header.map_or(Vec::new(), |h| {
            let chips = (h.chips > 1).then(|| format!("{} SIDs", h.chips));
            [Some(h.format.to_string()), h.model.map(str::to_string), h.clock.map(str::to_string), chips].into_iter().flatten().collect()
        });
        self.tags = Some((path, tags));
    }

    /// False once the keys have been left alone a while.
    fn extras_showing(&self) -> bool {
        match (self.now, self.last_key) {
            (Some(now), Some(pressed)) => now.duration_since(pressed) < EXTRAS_FOR,
            _ => true,
        }
    }

    /// The tunes an action is about: those marked, else the one under the cursor.
    pub fn chosen(&self) -> Vec<String> {
        if !self.marked.is_empty() {
            return self.rows.iter().filter(|t| self.marked.contains(&t.path)).map(|t| t.path.clone()).collect();
        }
        self.rows.get(self.cursor).map(|t| vec![t.path.clone()]).unwrap_or_default()
    }

    fn current_playlist(&self) -> Option<String> {
        match &self.view {
            View::Playlist(name) => Some(name.clone()),
            _ => None,
        }
    }

    fn own_playlists(&self) -> Vec<String> {
        self.lists.iter().map(|l| l.name.clone()).collect()
    }

    pub fn use_keys(&mut self, choice: Choice) {
        self.keys = KeyMap::new(choice.scheme);
        self.key_choice = choice;
    }

    pub fn key(&mut self, key: KeyEvent) {
        self.message = None;
        self.last_key = self.now;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && key.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        if matches!(self.mode, Mode::Splash(_)) {
            self.mode = Mode::Normal;
            return;
        }
        // Letters are for typing in these, so only ⌃G and ⌃N mean anything.
        if matches!(self.mode, Mode::Search | Mode::NewPlaylist(_) | Mode::Jump(_) | Mode::Describing(_)) {
            let key = match key.code {
                KeyCode::Char('g') if ctrl => KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE),
                KeyCode::Char('n') if ctrl => KeyEvent::new(KeyCode::Down, KeyModifiers::NONE),
                _ => key,
            };
            match std::mem::replace(&mut self.mode, Mode::Normal) {
                Mode::Search => self.key_search(key),
                Mode::NewPlaylist(name) => self.key_new_playlist(key, name),
                Mode::Jump(text) => self.key_jump(key, text),
                Mode::Describing(text) => self.key_describing(key, text),
                other => self.mode = other,
            }
            return;
        }
        if matches!(self.mode, Mode::Help) {
            self.mode = Mode::Normal;
            return;
        }
        let Some(translated) = self.keys.translate(key) else { return };
        // ⌃G cancels. There's nothing to cancel in the list, and Esc would quit.
        if matches!(self.mode, Mode::Normal) && translated.code == KeyCode::Esc && key.code != KeyCode::Esc {
            return;
        }
        let key = translated;
        // The handlers below match on the letter alone, so a chord no key set
        // uses would run the plain key: ⌃X would take a tune out of a playlist.
        if matches!(key.code, KeyCode::Char(_)) && key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return;
        }
        match std::mem::replace(&mut self.mode, Mode::Normal) {
            Mode::Normal => self.key_normal(key),
            Mode::Visual => self.key_visual(key),
            Mode::Credits(started) => self.key_credits(key, started),
            Mode::Reading(top) => self.key_reading(key, top),
            Mode::Drawer(since) => self.key_drawer(key, since),
            Mode::DrawerClosing(since) => self.mode = Mode::DrawerClosing(since),
            Mode::AddTo(cursor) => self.key_add_to(key, cursor),
            Mode::Browser(browser) => self.key_browser(key, browser),
            Mode::Help | Mode::Search | Mode::NewPlaylist(_) | Mode::Jump(_) | Mode::Describing(_) | Mode::Splash(_) => unreachable!("handled above"),
        }
    }

    fn move_cursor(&mut self, by: isize) {
        match self.focus {
            Focus::Sidebar => {
                let last = self.sidebar_entries().len().saturating_sub(1);
                self.sidebar = self.sidebar.saturating_add_signed(by).min(last);
            }
            Focus::List => {
                let count = match self.view {
                    View::HvscHome => self.home_items().len(),
                    View::Describe if self.rows.is_empty() => SUGGESTIONS.len(),
                    _ => self.rows.len(),
                };
                self.cursor = self.cursor.saturating_add_signed(by).min(count.saturating_sub(1));
            }
        }
    }

    fn key_normal(&mut self, key: KeyEvent) {
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        // Composers and Home have no tunes for these to act on.
        if !self.showing_tunes() && matches!(key.code, KeyCode::Char('l' | 'd' | 's' | 'f' | 'a' | 'n' | 'x' | 'J' | 'K' | ' ')) {
            return;
        }
        match key.code {
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Esc => self.step_back(),
            KeyCode::Char('S') if self.view == View::HvscHome => self.ack(None, false, "hvsc.shuffle", json!({})),
            KeyCode::Char('T') if self.view == View::HvscHome => self.play_top_100(),
            KeyCode::Up if shift => self.move_tune(-1),
            KeyCode::Down if shift => self.move_tune(1),
            KeyCode::Char('K') => self.move_tune(-1),
            KeyCode::Char('J') => self.move_tune(1),
            KeyCode::Up | KeyCode::Char('k') => self.move_cursor(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_cursor(1),
            KeyCode::PageUp => self.move_cursor(-15),
            KeyCode::PageDown => self.move_cursor(15),
            KeyCode::Home => self.move_cursor(isize::MIN),
            KeyCode::End => self.move_cursor(isize::MAX),
            KeyCode::Tab => {
                self.focus = if self.focus == Focus::List { Focus::Sidebar } else { Focus::List };
            }
            KeyCode::Left => self.focus = Focus::Sidebar,
            KeyCode::Right => self.focus = Focus::List,
            KeyCode::Enter if self.focus == Focus::Sidebar => {
                self.open_sidebar();
                self.focus = Focus::List;
                if self.view == View::Search {
                    self.mode = Mode::Search;
                }
                if self.view == View::Describe && self.rows.is_empty() {
                    self.mode = Mode::Describing(self.describing.sentence.clone());
                }
            }
            KeyCode::Enter => match self.view.clone() {
                View::HvscHome => self.open_home_item(),
                View::Hvsc(section) => self.open_composer(section),
                View::Describe if self.rows.is_empty() => self.try_suggestion(),
                _ => self.play_cursor(),
            },
            KeyCode::Char(' ') if self.focus == Focus::List => {
                if let Some(tune) = self.rows.get(self.cursor) {
                    let path = tune.path.clone();
                    if !self.marked.remove(&path) {
                        self.marked.insert(path);
                    }
                    self.move_cursor(1);
                }
            }
            KeyCode::Char('/') if matches!(self.view, View::Hvsc(_)) => self.mode = Mode::Jump(String::new()),
            KeyCode::Char('/') if self.view == View::Describe => self.mode = Mode::Describing(self.describing.sentence.clone()),
            KeyCode::Char('/') => {
                self.view = View::Search;
                self.sidebar = 0;
                self.focus = Focus::List;
                self.mode = Mode::Search;
                self.cursor = 0;
                self.marked.clear();
                self.reload();
            }
            KeyCode::Char('p') => self.ack(None, false, "toggle", json!({})),
            KeyCode::Char('>') | KeyCode::Char('.') => self.ack(None, false, "next", json!({})),
            KeyCode::Char('<') | KeyCode::Char(',') => self.ack(None, false, "prev", json!({})),
            KeyCode::Char('r') => self.ack(None, false, "surprise", json!({})),
            KeyCode::Char('l') => self.sounds_like(),
            KeyCode::Char('d') => {
                if let Some(tune) = self.rows.get(self.cursor) {
                    let (path, title) = (tune.path.clone(), tune.title.clone());
                    self.ack(Some(format!("Drifting from {title}.")), false, "drift", json!({ "path": path }));
                }
            }
            KeyCode::Char('s') => {
                if let Some(tune) = self.rows.get(self.cursor) {
                    let path = tune.path.clone();
                    self.ack(None, false, "show", json!({ "path": path }));
                }
            }
            KeyCode::Char('f') => {
                let paths = self.chosen();
                if !paths.is_empty() {
                    let message = format!("Added {} to Favourites.", count(paths.len()));
                    self.ack(Some(message), true, "playlist.add", json!({ "name": "Favourites", "paths": paths }));
                }
            }
            KeyCode::Char('a') if !self.chosen().is_empty() => self.mode = Mode::AddTo(0),
            KeyCode::Char('n') if self.view == View::Describe && self.marked.is_empty() => {
                if !self.rows.is_empty() {
                    self.mode = Mode::NewPlaylist(self.describing.title.clone());
                }
            }
            KeyCode::Char('n') => self.mode = Mode::NewPlaylist(String::new()),
            KeyCode::Char('x') => self.remove_chosen(),
            KeyCode::Char('o') => {
                let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
                let start = std::env::current_dir().unwrap_or(home);
                self.mode = Mode::Browser(Browser::open(start));
            }
            KeyCode::Char('?') => self.mode = Mode::Help,
            KeyCode::Char('u') => self.mode = Mode::Drawer(self.now.unwrap_or_else(Instant::now)),
            KeyCode::Char('v') => self.mode = Mode::Visual,
            KeyCode::Char('c') => self.open_credits(),
            _ => {}
        }
    }

    fn playing(&self) -> Option<&crate::model::Now> {
        self.status.as_ref().and_then(|s| s.now.as_ref())
    }

    pub fn open_credits(&mut self) {
        self.mode = Mode::Credits(self.now.unwrap_or_else(Instant::now));
        self.credits_want_music = true;
        self.start_credits_music();
    }

    /// Credits need a soundtrack: Favourites if nothing's on. Something paused is left
    /// alone, as that was someone's choice. It waits for the app to say what's playing,
    /// which `resonance credits` doesn't know yet as it opens.
    fn start_credits_music(&mut self) {
        let Some(status) = self.status.as_ref().filter(|_| self.credits_want_music) else { return };
        self.credits_want_music = false;
        let silent = status.now.is_none() || status.state == "stopped";
        if silent && matches!(self.mode, Mode::Credits(_)) {
            self.send(Tag::CreditsMusic, "playlist.play", json!({ "name": "Favourites" }));
        }
    }

    fn close_credits(&mut self) {
        self.mode = Mode::Normal;
        if self.leave_after_credits {
            self.quit = true;
        }
    }

    /// As in the visuals: the music keeps its keys.
    fn key_credits(&mut self, key: KeyEvent, started: Instant) {
        match key.code {
            KeyCode::Esc => return self.close_credits(),
            KeyCode::Char('q') => {
                self.quit = true;
                return;
            }
            KeyCode::Char('p') => self.ack(None, false, "toggle", json!({})),
            KeyCode::Char('>') | KeyCode::Char('.') => self.ack(None, false, "next", json!({})),
            KeyCode::Char('<') | KeyCode::Char(',') => self.ack(None, false, "prev", json!({})),
            _ => {}
        }
        self.mode = Mode::Credits(started);
    }

    /// The music keeps its keys in here; the list's aren't on screen to use.
    fn key_visual(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => return,
            KeyCode::Char('q') => {
                self.quit = true;
                return;
            }
            KeyCode::Char('v') => self.page = self.page.next(),
            KeyCode::Char('f') => self.page = Page::Fire,
            KeyCode::Char('s') => self.page = Page::Skull,
            KeyCode::Char('t') => self.page = Page::Tesla,
            KeyCode::Char('w') => self.page = Page::Water,
            KeyCode::Char('o') => self.page = Page::Sphere,
            KeyCode::Char('c') if matches!(self.page, Page::Fire | Page::Water) => self.channels = !self.channels,
            KeyCode::Char('p') => self.ack(None, false, "toggle", json!({})),
            KeyCode::Char('>') | KeyCode::Char('.') => self.ack(None, false, "next", json!({})),
            KeyCode::Char('<') | KeyCode::Char(',') => self.ack(None, false, "prev", json!({})),
            KeyCode::Char('r') => self.ack(None, false, "surprise", json!({})),
            KeyCode::Left if self.page == Page::Skull => self.skull.turn_faster(-1),
            KeyCode::Right if self.page == Page::Skull => self.skull.turn_faster(1),
            _ => {}
        }
        self.mode = Mode::Visual;
    }

    fn play_cursor(&mut self) {
        let Some(tune) = self.rows.get(self.cursor) else { return };
        let start = tune.path.clone();
        match self.view.clone() {
            View::Playlist(name) => {
                self.ack(None, false, "playlist.play", json!({ "name": name, "start": start }));
            }
            view => {
                let paths: Vec<String> = self.rows.iter().map(|t| t.path.clone()).collect();
                let mut args = json!({ "paths": paths, "start": start });
                if view == View::Search {
                    args["text"] = json!(self.query);
                }
                if view == View::Describe {
                    args["name"] = json!(self.describing.title);
                }
                self.ack(None, false, "play", args);
            }
        }
    }

    fn sounds_like(&mut self) {
        let Some(tune) = self.rows.get(self.cursor).cloned() else { return };
        self.like_seed = Some(tune.path.clone());
        self.view = View::Like(tune.title);
        self.rows.clear();
        self.cursor = 0;
        self.marked.clear();
        self.generation += 1;
        self.send(Tag::Rows(self.generation), "like", json!({ "path": tune.path, "limit": 30 }));
    }

    fn remove_chosen(&mut self) {
        let Some(name) = self.current_playlist() else {
            self.message = Some("Tunes can only be taken out of a playlist.".into());
            return;
        };
        let paths = self.chosen();
        if paths.is_empty() {
            return;
        }
        let message = format!("Took {} out of {name}.", count(paths.len()));
        self.marked.clear();
        self.ack(Some(message), true, "playlist.rm", json!({ "name": name, "paths": paths }));
    }

    /// Up or down one, at once; the app is told in the background.
    fn move_tune(&mut self, by: isize) {
        let Some(name) = self.current_playlist() else { return };
        if name == "Favourites" {
            self.message = Some("Favourites keeps its own order.".into());
            return;
        }
        let Some(to) = self.cursor.checked_add_signed(by).filter(|to| *to < self.rows.len()) else { return };
        self.rows.swap(self.cursor, to);
        let path = self.rows[to].path.clone();
        let before = self.rows.get(to + 1).map(|t| t.path.clone());
        self.cursor = to;
        self.ack(None, false, "playlist.mv", json!({ "name": name, "paths": [path], "before": before }));
    }

    fn key_search(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc | KeyCode::Enter | KeyCode::Down => return,
            _ => {
                edit_line(&mut self.query, key);
            }
        }
        self.search_due = Some(Instant::now() + DEBOUNCE);
        self.mode = Mode::Search;
    }

    fn key_new_playlist(&mut self, key: KeyEvent, mut name: String) {
        match key.code {
            KeyCode::Esc => return,
            KeyCode::Enter => {
                if !name.trim().is_empty() {
                    // A described list is saved whole, unless some of it is marked.
                    let paths = if self.view == View::Describe && self.marked.is_empty() {
                        self.rows.iter().map(|t| t.path.clone()).collect()
                    } else {
                        self.chosen()
                    };
                    let message = format!("Made {name}.");
                    self.marked.clear();
                    self.ack(Some(message), true, "playlist.new", json!({ "name": name.trim(), "paths": paths }));
                }
                return;
            }
            _ => {
                edit_line(&mut name, key);
            }
        }
        self.mode = Mode::NewPlaylist(name);
    }

    fn key_add_to(&mut self, key: KeyEvent, cursor: usize) {
        let lists = self.own_playlists();
        match key.code {
            KeyCode::Esc => {}
            KeyCode::Up | KeyCode::Char('k') => self.mode = Mode::AddTo(cursor.saturating_sub(1)),
            KeyCode::Down | KeyCode::Char('j') => {
                self.mode = Mode::AddTo((cursor + 1).min(lists.len().saturating_sub(1)));
            }
            KeyCode::Enter => {
                if let Some(name) = lists.get(cursor).cloned() {
                    let paths = self.chosen();
                    let message = format!("Added {} to {name}.", count(paths.len()));
                    self.marked.clear();
                    self.ack(Some(message), true, "playlist.add", json!({ "name": name, "paths": paths }));
                }
            }
            _ => self.mode = Mode::AddTo(cursor),
        }
    }

    fn key_browser(&mut self, key: KeyEvent, mut browser: Browser) {
        match key.code {
            KeyCode::Esc => return,
            KeyCode::Up | KeyCode::Char('k') => browser.cursor = browser.cursor.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                browser.cursor = (browser.cursor + 1).min(browser.entries.len().saturating_sub(1));
            }
            KeyCode::Left | KeyCode::Backspace => browser.up(),
            KeyCode::Char(' ') => {
                if let Some((name, false)) = browser.entries.get(browser.cursor) {
                    let path = browser.dir.join(name);
                    if !browser.marked.remove(&path) {
                        browser.marked.insert(path);
                    }
                    browser.cursor = (browser.cursor + 1).min(browser.entries.len().saturating_sub(1));
                }
            }
            KeyCode::Enter | KeyCode::Right => {
                match browser.entries.get(browser.cursor).cloned() {
                    Some((name, true)) if browser.marked.is_empty() || key.code == KeyCode::Right => {
                        browser.dir = browser.dir.join(name);
                        browser.read();
                    }
                    entry if key.code == KeyCode::Enter => {
                        let mut files: Vec<PathBuf> = browser.marked.iter().cloned().collect();
                        if files.is_empty() {
                            if let Some((name, _)) = entry {
                                files.push(browser.dir.join(name));
                            }
                        }
                        return self.use_files(files);
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        self.mode = Mode::Browser(browser);
    }

    /// Files from the browser: into the playlist showing, else play them.
    fn use_files(&mut self, files: Vec<PathBuf>) {
        if files.is_empty() {
            return;
        }
        let paths: Vec<String> = files.iter().map(|f| f.to_string_lossy().into_owned()).collect();
        match self.current_playlist() {
            Some(name) => {
                let message = format!("Added {} to {name}.", count(paths.len()));
                self.ack(Some(message), true, "playlist.add", json!({ "name": name, "paths": paths }));
            }
            None => self.ack(None, false, "play", json!({ "paths": paths })),
        }
    }
}

fn count(tunes: usize) -> String {
    if tunes == 1 {
        "1 tune".to_string()
    } else {
        format!("{tunes} tunes")
    }
}

// MARK: Drawing

pub fn draw(frame: &mut Frame, app: &App) {
    draw_screen(frame, app);
    palette::paint(frame.buffer_mut());
}

fn draw_screen(frame: &mut Frame, app: &App) {
    if let Mode::Credits(started) = app.mode {
        let seconds = app.now.unwrap_or_else(Instant::now).saturating_duration_since(started).as_secs_f64();
        let area = frame.area();
        return credits::draw(frame.buffer_mut(), area, seconds, app.playing());
    }
    if matches!(app.mode, Mode::Visual) {
        return draw_visual(frame, app);
    }
    let area = frame.area();
    let [now, upper, main, lower, keys] = Layout::vertical([
        Constraint::Length(NOW_ROWS),
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(area);
    draw_now(frame, app, now);
    header::draw_frame_edge(frame.buffer_mut(), upper, true);
    draw_panes(frame, app, main);
    header::draw_frame_edge(frame.buffer_mut(), lower, false);
    draw_keys(frame, app, keys);
    match &app.mode {
        Mode::AddTo(cursor) => draw_add_to(frame, app, *cursor),
        Mode::NewPlaylist(name) => draw_prompt(frame, "New playlist", name),
        Mode::Browser(browser) => draw_browser(frame, browser, app.keys.scheme),
        Mode::Help => draw_help(frame, app.key_choice),
        Mode::Reading(top) => draw_announcement(frame, app, *top),
        Mode::Splash(started) => draw_splash(frame, app, *started),
        Mode::Drawer(since) => draw_drawer(frame, app, *since, false),
        Mode::DrawerClosing(since) => draw_drawer(frame, app, *since, true),
        Mode::Normal | Mode::Search | Mode::Jump(_) | Mode::Describing(_) | Mode::Visual | Mode::Credits(_) => {}
    }
}

/// The logo fills the window, then the player takes its place from the bottom up. The
/// logo's own drawing is untouched: it's copied across, row by row.
fn draw_splash(frame: &mut Frame, app: &App, started: Instant) {
    let area = frame.area();
    let plan = header::plan(area.width, area.height);
    let seconds = app.now.unwrap_or(started).saturating_duration_since(started);
    let leaving = seconds.saturating_sub(SPLASH_FOR).as_secs_f32() / SPLASH_LEAVES.as_secs_f32();
    let shown = (f32::from(area.height) * (1.0 - leaving.min(1.0))).round() as u16;
    let divider = u16::from(plan.rows > 1);
    let art = Rect::new(0, 0, area.width, plan.rows + divider);
    let mut picture = ratatui::buffer::Buffer::empty(art);
    header::draw(&mut picture, Rect::new(0, 0, area.width, plan.rows), plan);
    if divider > 0 {
        header::draw_divider(&mut picture, Rect::new(0, plan.rows, area.width, 1));
    }
    let top = shown.saturating_sub(art.height) / 2;
    let buffer = frame.buffer_mut();
    for y in 0..shown.min(area.height) {
        for x in 0..area.width {
            let cell = &mut buffer[(area.x + x, area.y + y)];
            cell.reset();
            if y >= top && y - top < art.height {
                *cell = picture[(x, y - top)].clone();
            }
        }
    }
    if leaving <= 0.0 {
        let hint = "any key to start";
        let left = area.width.saturating_sub(hint.len() as u16) / 2;
        buffer.set_string(area.x + left, area.y + area.height.saturating_sub(2), hint, dim());
    }
}

fn draw_announcement(frame: &mut Frame, app: &App, top: usize) {
    let Some(update) = app.hvsc.as_ref().and_then(|info| info.update.as_ref()) else { return };
    let area = centred(frame.area(), 84, frame.area().height.saturating_sub(4));
    frame.render_widget(Clear, area);
    let block = pane(format!(" Update #{}  ↑↓ read  esc close ", update.number), true);
    let height = block.inner(area).height as usize;
    let lines: Vec<Line> = update.text.lines().skip(top).take(height).map(|l| Line::raw(l.to_string())).collect();
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

fn thousands(n: u32) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// The collection's front door, as much of it as fits.
fn draw_home(frame: &mut Frame, app: &App, area: Rect) {
    let label = Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD);
    let Some(info) = &app.hvsc else {
        let lines = vec![
            Line::styled("▓▒░ High Voltage SID Collection", label),
            Line::raw(""),
            Line::styled("No collection yet. Download it in the Resonance app, from HVSC Home.", dim()),
        ];
        frame.render_widget(Paragraph::new(lines).wrap(ratatui::widgets::Wrap { trim: true }), area);
        return;
    };
    let focused = app.focus == Focus::List;
    let items = app.home_items();
    let selected = items.get(app.cursor);
    let band = |on: bool| if on && focused { cursor_style(true) } else { Style::new() };

    let mut title = vec![Span::styled("▓▒░ High Voltage SID Collection", label)];
    if let Some(version) = &info.version {
        title.push(Span::raw("  "));
        title.push(Span::styled(format!(" Release {version} "), Style::new().bg(palette::accent()).fg(palette::background()).add_modifier(Modifier::BOLD)));
    }
    let date = info.release_date.as_ref().map_or(String::new(), |d| format!("Released {d} · "));
    let coverage = if info.total_tunes == 0 { 0 } else { (u64::from(info.songlength_entries) * 100 / u64::from(info.total_tunes)).min(100) };
    let stat = |big: String, small: &str| (big, small.to_string());
    let stats = [stat(thousands(info.total_tunes), "tunes"), stat(thousands(info.composers), "composers"), stat(format!("{coverage}%"), "with lengths")];
    let mut top = vec![Line::from(title), Line::styled(format!("{date}every C64 SID tune, archived since 1996"), dim()), Line::raw("")];
    top.push(Line::from(stats.iter().map(|(big, _)| Span::styled(format!("{big:<16}"), Style::new().add_modifier(Modifier::BOLD))).collect::<Vec<_>>()));
    top.push(Line::from(stats.iter().map(|(_, small)| Span::styled(format!("{small:<16}"), dim())).collect::<Vec<_>>()));

    let two_columns = area.width >= 76;
    let [head, body] = Layout::vertical([Constraint::Length(top.len() as u16 + 1), Constraint::Min(0)]).areas(area);
    frame.render_widget(Paragraph::new(top), head);
    let [left, _, right] = Layout::horizontal([Constraint::Fill(1), Constraint::Length(u16::from(two_columns) * 2), Constraint::Fill(u16::from(two_columns))]).areas(body);

    let mut lines = vec![Line::styled("Browse", label)];
    let sections = [("Musicians", info.musician_tunes, palette::green(), 1), ("Demos", info.demo_tunes, palette::orange(), 2), ("Games", info.game_tunes, palette::violet(), 3)];
    for (name, count, color, row) in sections {
        let on = selected == Some(&HomeItem::Section(row));
        let share = if info.total_tunes == 0 { 0.0 } else { f64::from(count) / f64::from(info.total_tunes) };
        let lit = ((share * 12.0).round() as usize).clamp(1, 12);
        lines.push(Line::from(vec![
            Span::raw(format!("{name:<10}")),
            Span::styled("█".repeat(lit), Style::new().fg(color)),
            Span::styled("░".repeat(12 - lit), Style::new().fg(palette::faint())),
            Span::styled(format!(" {:>6}  {:>3.0}%", thousands(count), share * 100.0), dim()),
        ]).style(band(on)));
    }
    let browse_rows = lines.len();
    if !app.rows.is_empty() {
        lines.push(Line::raw(""));
        lines.push(Line::styled("Jump back in", label));
        for tune in app.rows.iter().take(4) {
            let mut spans = app.barcode(&tune.path).spans;
            spans.push(Span::raw(format!(" {}", tune.title)));
            spans.push(Span::styled(format!("  {}", tune.author), dim()));
            lines.push(Line::from(spans));
        }
    }
    if !info.disks.is_empty() {
        let images: u32 = info.disks.iter().map(|d| d.images).sum();
        lines.push(Line::raw(""));
        lines.push(Line::from(vec![Span::styled("C64 disk images", label), Span::styled(format!("  {images} for an emulator"), dim())]));
        lines.push(Line::styled(info.disks.iter().map(|d| d.name.as_str()).collect::<Vec<_>>().join(", "), dim()));
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(vec![Span::styled("Reference", label), Span::styled(format!("  {} documents in the collection", info.documents), dim())]));

    let mut side = Vec::new();
    if let Some(update) = &info.update {
        side.push(Line::styled(info.version.as_ref().map_or("What's new".to_string(), |v| format!("What's new in v{v}")), label));
        let facts = [(update.new_sids, "new SIDs", "+"), (update.fixed_rips, "fixed or better rips", ""), (update.credit_fixes, "credit fixes", ""), (update.moved, "tunes re-filed", "")];
        // A short, narrow window keeps the room for what can be chosen.
        let room_for_facts = two_columns || body.height >= 20;
        for (count, what, sign) in facts {
            if let (Some(count), true) = (count, room_for_facts) {
                side.push(Line::from(vec![Span::styled(format!("{:>5} ", format!("{sign}{count}")), Style::new().fg(if sign.is_empty() { palette::text() } else { palette::green() }).add_modifier(Modifier::BOLD)), Span::styled(what, dim())]));
            }
        }
        let on = selected == Some(&HomeItem::Announcement);
        side.push(Line::styled("↵ read the announcement", if on { dim() } else { Style::new().fg(palette::faint()) }).style(band(on)));
        side.push(Line::raw(""));
    }
    if !info.playlists.is_empty() {
        side.push(Line::from(vec![Span::styled("Curated playlists", label), Span::styled(format!("  {}", info.playlists.len()), dim())]));
        // As many as there's room for, keeping the chosen one in view.
        let above = side.len() + if two_columns { 0 } else { browse_rows + 1 };
        let room = (body.height as usize).saturating_sub(above + 1).max(1);
        let chosen = if let Some(HomeItem::Playlist(n)) = selected { *n } else { 0 };
        let first = (chosen + 1).saturating_sub(room);
        let wide = right.width.max(left.width) as usize;
        for (n, list) in info.playlists.iter().enumerate().skip(first).take(room) {
            let on = selected == Some(&HomeItem::Playlist(n));
            let name_width = wide.saturating_sub(6).min(40);
            let name: String = list.name.chars().take(name_width).collect();
            side.push(Line::from(vec![Span::raw(format!("{name:<name_width$}")), Span::styled(format!("{:>5}", list.tracks), dim())]).style(band(on)));
        }
        let hidden = info.playlists.len().saturating_sub(first + room);
        if hidden > 0 {
            side.push(Line::styled(format!("and {hidden} more below"), dim()));
        }
    }
    if two_columns {
        frame.render_widget(Paragraph::new(lines), left);
        frame.render_widget(Paragraph::new(side), right);
    } else {
        // What can be chosen first, so it's never below the window's edge.
        let rest = lines.split_off(browse_rows);
        lines.push(Line::raw(""));
        lines.extend(side);
        lines.extend(rest);
        frame.render_widget(Paragraph::new(lines), left);
    }
}

/// A section's composers, with the sound of their tunes on average.
fn draw_composers(frame: &mut Frame, app: &App, area: Rect, section: &str) {
    let [title, rest] = Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).areas(area);
    let focused = app.focus == Focus::List;
    let heading_text = match &app.mode {
        Mode::Jump(text) => format!("▓▒░ Find: {text}▏"),
        _ => format!("▓▒░ {}", HVSC_ROWS.iter().find(|(_, s)| *s == Some(section)).map_or("HVSC", |(name, _)| *name)),
    };
    frame.render_widget(self::heading(heading_text, focused), title);
    if app.rows.is_empty() {
        frame.render_widget(Paragraph::new(Line::styled(" Reading the collection…", dim())), rest);
        return;
    }
    let prints = app.showing_prints();
    let rows: Vec<Row> = app.rows.iter().map(|row| {
        let mut cells = vec![Cell::from(row.title.clone()), Cell::from(row.songs.to_string())];
        if prints {
            cells.push(Cell::from(app.barcode(&row.path)));
        }
        cells.push(Cell::from(row.released.clone()));
        Row::new(cells)
    }).collect();
    let mut widths = vec![Constraint::Fill(1), Constraint::Length(5)];
    let mut names = vec!["Name", "Tunes"];
    if prints {
        widths.push(Constraint::Length(fingerprint::SMALL_WIDTH));
        names.push("Sound");
    }
    widths.push(Constraint::Length(9));
    names.push("Years");
    let table = Table::new(rows, widths).header(Row::new(names).style(dim())).row_highlight_style(cursor_style(focused));
    let mut state = TableState::default().with_selected(Some(app.cursor));
    frame.render_stateful_widget(table, rest, &mut state);
}


/// What's playing: its name, and a slim bar with the time beside it.
const NOW_ROWS: u16 = 2;
/// Seconds without a key before the visuals' extras go, as in the app's Now Playing.
const EXTRAS_FOR: Duration = Duration::from_secs(3);

/// The whole screen for the music: a page of it, with the tune, voices and keys around.
/// Where everything goes on the visuals, the same way up as the app's Now Playing:
/// what to pick at the top, the music in the middle with room around it, the tune
/// and its voices under that, then the transport.
struct VisualLayout {
    top: Rect,
    body: Rect,
    info: Rect,
    voices: Rect,
    transport: Rect,
    keys: Rect,
    /// How much of the tune there's room to say, 1 to 5 rows.
    info_rows: u16,
}

const VOICES_WIDTH: u16 = 18;

fn visual_layout(area: Rect) -> VisualLayout {
    let side = match area.width {
        100.. => 6,
        60.. => 3,
        _ => 1,
    };
    let edge = u16::from(area.height >= 24);
    let inner = Rect::new(
        area.x + side,
        area.y + edge,
        area.width.saturating_sub(side * 2),
        area.height.saturating_sub(edge * 2),
    );
    let info_rows = match area.height {
        30.. => 5,
        22.. => 3,
        14.. => 2,
        _ => 1,
    };
    let [top, _, middle, _, info_row, _, transport, keys] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
        Constraint::Length(info_rows),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(inner);
    let (pad_x, pad_y) = (middle.width / 10, middle.height / 10);
    let body = Rect::new(
        middle.x + pad_x,
        middle.y + pad_y,
        middle.width.saturating_sub(pad_x * 2),
        middle.height.saturating_sub(pad_y * 2),
    );
    let [info, voices] = Layout::horizontal([Constraint::Min(0), Constraint::Length(VOICES_WIDTH)]).areas(info_row);
    VisualLayout { top, body, info, voices, transport, keys, info_rows }
}

fn draw_visual(frame: &mut Frame, app: &App) {
    let layout = visual_layout(frame.area());
    draw_visual_top(frame, app, layout.top);
    let (body, truecolor) = (layout.body, app.skull.truecolor);
    match app.page {
        Page::Fire => {
            app.fire.draw(frame.buffer_mut(), body, truecolor, app.channels);
            // Its base is where it burns from, so that edge stays.
            palette::fade_edges(frame.buffer_mut(), body, false);
        }
        Page::Tesla => app.tesla.draw(frame.buffer_mut(), body, truecolor),
        Page::Water => {
            app.water.draw(frame.buffer_mut(), body, truecolor, app.channels);
            palette::fade_edges(frame.buffer_mut(), body, true);
        }
        Page::Sphere => app.sphere.draw(frame.buffer_mut(), body, truecolor),
        Page::Skull => draw_skull(frame, app, body),
    }
    frame.render_widget(Paragraph::new(tune_lines(app, layout.info_rows)), layout.info);
    if layout.info_rows >= 3 {
        draw_voice_chips(frame, app, layout.voices);
    }
    draw_transport(frame, app, layout.transport);
    let bottom = match &app.message {
        Some(message) => Line::from(message.clone()),
        None if app.extras_showing() => {
            let shown = fit_bar(visual_keys(app), layout.keys.width, "esc");
            Line::styled(shown.iter().map(|(key, what)| format!("{key} {what}  ")).collect::<String>(), dim())
        }
        None => Line::raw(""),
    };
    frame.render_widget(Paragraph::new(bottom), layout.keys);
}

/// The visuals to pick from, with their keys.
const PICKER: [(Page, &str); 5] = [
    (Page::Skull, "s"),
    (Page::Fire, "f"),
    (Page::Tesla, "t"),
    (Page::Water, "w"),
    (Page::Sphere, "o"),
];

fn picker_spans(app: &App, width: u16) -> Vec<Span<'static>> {
    let chosen = Style::new().bg(palette::selection()).fg(palette::accent()).add_modifier(Modifier::BOLD);
    let spans: Vec<Span> = PICKER
        .iter()
        .map(|(page, key)| Span::styled(format!(" {key} {} ", page.name()), if *page == app.page { chosen } else { dim() }))
        .collect();
    let wide: usize = spans.iter().map(|s| s.content.chars().count()).sum();
    if wide <= width as usize {
        spans
    } else {
        vec![Span::styled(format!(" {} ", app.page.name()), chosen)]
    }
}

/// The close key, always, as the app keeps its cross; Surprise Me and the picker
/// only until the keys have been left alone a while.
fn draw_visual_top(frame: &mut Frame, app: &App, area: Rect) {
    let extras = app.extras_showing();
    let mut left = vec![Span::styled("✕ ", Style::new().fg(palette::text())), Span::styled("esc", dim())];
    if !extras {
        frame.render_widget(Paragraph::new(Line::from(left)), area);
        return;
    }
    let picker = picker_spans(app, area.width);
    let picker_width: u16 = picker.iter().map(|s| s.content.chars().count() as u16).sum();
    const SURPRISE: &str = "   r Surprise Me";
    if area.width >= picker_width + (SURPRISE.chars().count() as u16 + 5) * 2 {
        left.push(Span::styled(SURPRISE, dim()));
    }
    frame.render_widget(Paragraph::new(Line::from(left)), area);
    if area.width >= picker_width + 12 {
        frame.render_widget(Paragraph::new(Line::from(picker)).alignment(Alignment::Center), area);
    }
}

/// "1987 Epyx" as the app words it: "1987 · Epyx".
fn released_line(released: &str) -> String {
    match released.split_once(' ') {
        Some((year, by)) if year.len() == 4 && year.chars().all(|c| c.is_ascii_digit() || c == '?') => format!("{year} · {by}"),
        _ => released.to_string(),
    }
}

/// The tune, big as a terminal can make it, as much as there's room for.
fn tune_lines(app: &App, rows: u16) -> Vec<Line<'static>> {
    let status = app.status.as_ref();
    let Some((status, now)) = status.and_then(|s| s.now.as_ref().map(|n| (s, n))) else {
        return vec![Line::styled("Not Playing", dim().add_modifier(Modifier::BOLD))];
    };
    let paused = status.state == "paused";
    let mut title = vec![Span::styled(
        now.title.clone(),
        Style::new().fg(if paused { palette::muted() } else { palette::accent() }).add_modifier(Modifier::BOLD),
    )];
    if status.favourite {
        title.push(Span::styled("  ♥", Style::new().fg(palette::red())));
    }
    if paused {
        title.push(Span::styled("  paused", dim()));
    }
    let composer = Line::raw(now.author.clone());
    let released = Line::styled(released_line(&now.released), dim());
    let source = status.source.as_ref().map_or("NOW PLAYING".to_string(), |s| format!("PLAYING FROM {}", s.to_uppercase()));
    let mut tags: Vec<String> = app.tags.as_ref().map_or(Vec::new(), |(_, tags)| tags.clone());
    if now.songs > 1 {
        tags.push(format!("{} of {}", now.song, now.songs));
    }
    let chips = tags.into_iter().flat_map(|tag| {
        [Span::styled(format!(" {tag} "), Style::new().bg(palette::selection()).fg(palette::text())), Span::raw(" ")]
    });
    match rows {
        5.. => vec![Line::styled(source, dim()), Line::from(title), composer, released, Line::from(chips.collect::<Vec<_>>())],
        3 | 4 => vec![Line::from(title), composer, released],
        2 => vec![Line::from(title), composer],
        _ => vec![Line::from(title)],
    }
}

/// Each voice and the note it's on, stacked in the corner as in the app, at the
/// bottom of the room there is.
fn draw_voice_chips(frame: &mut Frame, app: &App, area: Rect) {
    let lines: Vec<Line> = app
        .ears
        .latest()
        .iter()
        .enumerate()
        .map(|(voice, heard)| {
            let color = Style::new().fg(viz::ink(voice, 3, app.skull.truecolor));
            let name = match (heard.noisy, heard.note) {
                (true, _) => "noise".to_string(),
                (false, Some(note)) => viz::note_name(note),
                _ => "---".to_string(),
            };
            let lit = ((heard.level * 6.0).round() as usize).min(6);
            Line::from(vec![
                Span::styled(format!("V{} ", voice + 1), dim()),
                Span::styled(format!("{name:<6}"), color),
                Span::styled("█".repeat(lit), color),
                Span::styled("░".repeat(6 - lit), Style::new().fg(palette::faint())),
            ])
        })
        .collect();
    let below = area.height.saturating_sub(lines.len() as u16);
    let placed = Rect::new(area.x, area.y + below, area.width, area.height - below);
    frame.render_widget(Paragraph::new(lines), placed);
}

/// Previous, pause or play and next, then the time either side of the bar.
fn draw_transport(frame: &mut Frame, app: &App, area: Rect) {
    let Some(status) = app.status.as_ref().filter(|s| s.now.is_some()) else { return };
    let playing = status.state == "playing";
    let mark = if playing { "▮▮" } else { "▶ " };
    let elapsed = clock(app.elapsed());
    let total = status.duration.map_or("--:--".to_string(), clock);
    let controls = format!("◀◀  {mark}  ▶▶  {elapsed:>5}  ");
    let [left, strip, right] = Layout::horizontal([
        Constraint::Length(controls.chars().count() as u16),
        Constraint::Min(1),
        Constraint::Length(total.chars().count() as u16 + 2),
    ])
    .areas(area);
    frame.render_widget(Paragraph::new(Line::styled(controls, Style::new().fg(palette::text()))), left);
    let loudest = app.ears.latest().iter().fold(0.0_f32, |most, voice| most.max(voice.level));
    viz::progress(frame.buffer_mut(), strip, app.progress().unwrap_or(0.0), loudest, app.ears.heard);
    frame.render_widget(Paragraph::new(total).alignment(Alignment::Right), right);
}

/// The visuals' bottom bar, the most useful first: what this page alone can do
/// comes early, as it's the part that can't be guessed from another page. Only
/// the skull's turning differs between the key sets.
fn visual_keys(app: &App) -> Vec<(&'static str, &'static str)> {
    let page = match (app.page, app.channels) {
        (Page::Skull, _) => Some((app.keys.scheme.choose("← →", "h l", "⌃B ⌃F"), "spin")),
        (Page::Fire | Page::Water, false) => Some(("c", "channel colours")),
        (Page::Fire, true) => Some(("c", "flame colours")),
        (Page::Water, true) => Some(("c", "water colours")),
        _ => None,
    };
    let mut keys = vec![("esc", "back")];
    keys.extend(page);
    keys.extend([
        ("v", "next view"),
        ("p", "pause"),
        (". ,", "next or previous"),
        ("r", "surprise"),
        ("q", "quit"),
    ]);
    keys
}

/// The skull, as its last frame left it.
fn draw_skull(frame: &mut Frame, app: &App, area: Rect) {
    let skull = &app.skull;
    let (columns, rows) = (skull.picture.width as usize, skull.picture.height as usize);
    let buffer = frame.buffer_mut();
    for row in 0..rows.min(area.height as usize) {
        for column in 0..columns.min(area.width as usize) {
            if let Some(glyph) = skull.picture.glyphs[row * columns + column] {
                if let Some(cell) = buffer.cell_mut((area.x + column as u16, area.y + row as u16)) {
                    cell.set_char(glyph.ch).set_fg(glyph.ink.color(skull.truecolor));
                }
            }
        }
    }
}

fn pane(title: String, focused: bool) -> Block<'static> {
    let block = Block::default().borders(Borders::ALL).title(title);
    block.border_style(Style::new().fg(if focused { palette::accent() } else { palette::faint() }))
}

fn column_width(window: u16, (percent, least, most): (u16, u16, u16)) -> u16 {
    ((u32::from(window) * u32::from(percent) / 100) as u16).clamp(least, most)
}

/// One column between its edges, with a space either side of what's in it.
fn inside(column: Rect) -> Rect {
    Rect::new(column.x + 1, column.y, column.width.saturating_sub(2), column.height)
}

/// The columns, each framed by shaded edges: as many as the window has room for.
fn draw_panes(frame: &mut Frame, app: &App, area: Rect) {
    let single = area.width < SIDEBAR_FROM;
    let nothing_to_show = app.view == View::Describe && app.rows.is_empty();
    let with_rail = area.width >= RAIL_FROM && app.view != View::HvscHome && !nothing_to_show;
    let mut widths = vec![Constraint::Length(1)];
    if !single {
        widths.extend([Constraint::Length(column_width(area.width, SIDEBAR_SHARE)), Constraint::Length(1)]);
    }
    widths.extend([Constraint::Min(1), Constraint::Length(1)]);
    if with_rail {
        widths.extend([Constraint::Length(column_width(area.width, RAIL_SHARE)), Constraint::Length(1)]);
    }
    let parts = Layout::horizontal(widths).split(area);
    for edge in parts.iter().step_by(2) {
        header::draw_column_edge(frame.buffer_mut(), edge.x, area);
    }
    if single {
        if app.focus == Focus::Sidebar {
            draw_sidebar(frame, app, inside(parts[1]));
        } else {
            draw_list(frame, app, inside(parts[1]));
        }
        return;
    }
    draw_sidebar(frame, app, inside(parts[1]));
    draw_list(frame, app, inside(parts[3]));
    if with_rail {
        draw_rail(frame, app, inside(parts[5]));
    }
}

fn heading(text: String, focused: bool) -> Paragraph<'static> {
    let color = if focused { palette::accent() } else { palette::text() };
    Paragraph::new(text).style(Style::new().fg(color).add_modifier(Modifier::BOLD))
}

/// The cursor: a band that leaves what's under it its colours, brighter when its
/// pane has the focus.
fn cursor_style(focused: bool) -> Style {
    Style::new().bg(if focused { palette::selection() } else { palette::quiet_selection() })
}

fn draw_sidebar(frame: &mut Frame, app: &App, area: Rect) {
    // A long list of playlists scrolls, rather than pushing HVSC off the bottom.
    let lists = app.lists.len() as u16;
    let lists_height = lists.min(area.height.saturating_sub(15)).max(1);
    let [title, fixed, _, lists_title, _, lists_area, _, hvsc_title, _, hvsc] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Length(FIXED_ROWS as u16),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(lists_height),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(area);
    let focused = app.focus == Focus::Sidebar;
    frame.render_widget(heading("▓▒░ Library".into(), focused), title);
    let entries = app.sidebar_entries();
    let own = app.library_rows();
    let highlight = if focused { cursor_style(true) } else { Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD) };
    let section_title = |name: &'static str| Span::styled(name, Style::new().fg(palette::text()).add_modifier(Modifier::BOLD));

    let items: Vec<ListItem> = entries[..FIXED_ROWS].iter().map(|name| ListItem::new(format!(" {name}"))).collect();
    let mut state = ListState::default().with_selected((app.sidebar < FIXED_ROWS).then_some(app.sidebar));
    frame.render_stateful_widget(List::new(items).highlight_style(highlight), fixed, &mut state);

    frame.render_widget(Paragraph::new(Line::from(section_title("▓▒░ Playlists"))), lists_title);
    let items: Vec<ListItem> = app
        .lists
        .iter()
        .map(|list| ListItem::new(Line::from(vec![Span::raw(format!(" {}", list.name)), Span::styled(format!("  {}", list.count), dim())])))
        .collect();
    let in_lists = (FIXED_ROWS..own).contains(&app.sidebar);
    let mut state = ListState::default().with_selected(in_lists.then(|| app.sidebar - FIXED_ROWS));
    frame.render_stateful_widget(List::new(items).highlight_style(highlight), lists_area, &mut state);

    let mut hvsc_heading = vec![section_title("▓▒░ HVSC")];
    if let Some(info) = &app.hvsc {
        hvsc_heading.push(Span::styled(format!("  {} tunes", thousands(info.total_tunes)), dim()));
    }
    frame.render_widget(Paragraph::new(Line::from(hvsc_heading)), hvsc_title);
    let wide = hvsc.width as usize;
    let rows: Vec<ListItem> = HVSC_ROWS
        .iter()
        .enumerate()
        .map(|(i, (name, _))| {
            let count = app.hvsc.as_ref().map_or(String::new(), |info| match i {
                0 => info.version.as_ref().map_or(String::new(), |v| format!("v{v}")),
                1 => thousands(info.musician_tunes),
                2 => thousands(info.demo_tunes),
                _ => thousands(info.game_tunes),
            });
            let gap = wide.saturating_sub(name.chars().count() + count.chars().count() + 2);
            ListItem::new(Line::from(vec![Span::raw(format!(" {name}{}", " ".repeat(gap))), Span::styled(count, dim())]))
        })
        .collect();
    let mut state = ListState::default().with_selected((app.sidebar >= own).then(|| app.sidebar - own));
    frame.render_stateful_widget(List::new(rows).highlight_style(highlight), hvsc, &mut state);
}

fn list_title(app: &App) -> String {
    match &app.view {
        View::Search if matches!(app.mode, Mode::Search) => format!("▓▒░ / {}▏", app.query),
        View::Search if app.query.is_empty() => "▓▒░ Search: press /".into(),
        View::Search => format!("▓▒░ Search “{}”", app.query),
        View::Describe => match &app.mode {
            Mode::Describing(text) => format!("▓▒░ Describe: {text}▏"),
            _ if app.describing.sentence.is_empty() => "▓▒░ Describe".into(),
            _ => format!("▓▒░ “{}”", app.describing.sentence),
        },
        View::Recent => "▓▒░ Recently Played".into(),
        View::Playlist(name) => format!("▓▒░ {name}"),
        View::Like(title) => format!("▓▒░ Sounds like {title}"),
        View::Composer { title, .. } => format!("▓▒░ {title}"),
        View::Curated { name, .. } => format!("▓▒░ {name}"),
        View::HvscHome | View::Hvsc(_) => String::new(),
    }
}

impl App {
    fn showing_prints(&self) -> bool {
        self.prints_wanted && !self.prints_off
    }

    /// A tune's barcode, or the place for it.
    fn barcode(&self, path: &str) -> Line<'static> {
        match self.prints.get(path) {
            Some(Some(traits)) => Line::from(fingerprint::small(traits)),
            _ => Line::from(fingerprint::none()),
        }
    }
}

fn draw_list(frame: &mut Frame, app: &App, area: Rect) {
    match app.view {
        View::HvscHome => return draw_home(frame, app, area),
        View::Hvsc(section) => return draw_composers(frame, app, area, section),
        _ => {}
    }
    let said = if app.view == View::Describe { describe_line(app, area.width as usize) } else { Vec::new() };
    let [title, understood, rest] = Layout::vertical([Constraint::Length(1), Constraint::Length(said.len() as u16), Constraint::Min(0)]).areas(area);
    let focused = app.focus == Focus::List;
    frame.render_widget(heading(list_title(app), focused), title);
    frame.render_widget(Paragraph::new(said), understood);
    if app.view == View::Describe && app.rows.is_empty() {
        return draw_describe_start(frame, app, rest);
    }
    let playing = app.status.as_ref().and_then(|s| s.now.as_ref()).map(|n| n.path.as_str());
    let prints = app.showing_prints();
    let composer = !prints || area.width >= COMPOSER_FROM;
    let rows: Vec<Row> = app
        .rows
        .iter()
        .map(|t| {
            let is_playing = playing == Some(t.path.as_str());
            let mark = if is_playing {
                "♪"
            } else if app.marked.contains(&t.path) {
                "✓"
            } else {
                " "
            };
            let last = match t.score {
                Some(score) => Line::from(format!("{:.0}%", score * 100.0)),
                None => Line::from(t.secs.map(|s| clock(f64::from(s))).unwrap_or_default()),
            };
            let mut cells = vec![Cell::from(mark), Cell::from(t.title.clone())];
            if composer {
                cells.push(Cell::from(t.author.clone()));
            }
            if prints {
                cells.push(Cell::from(app.barcode(&t.path)));
            }
            cells.push(Cell::from(last));
            let row = Row::new(cells);
            if is_playing {
                row.style(Style::new().fg(palette::accent()))
            } else {
                row
            }
        })
        .collect();
    let liking = matches!(app.view, View::Like(_));
    let (last_column, last_width) = if liking { ("Alike", 5) } else { ("Length", 6) };
    let mut widths = vec![Constraint::Length(1)];
    let mut header = vec![Cell::from(""), Cell::from("Title")];
    if prints {
        widths.push(Constraint::Fill(3));
    } else {
        widths.push(Constraint::Percentage(52));
    }
    if composer {
        widths.push(if prints { Constraint::Fill(2) } else { Constraint::Percentage(36) });
        header.push(Cell::from("Composer"));
    }
    if prints {
        widths.push(Constraint::Length(fingerprint::SMALL_WIDTH));
        // Over the tunes it's being compared with, where there are some.
        header.push(match app.like_seed.as_deref().filter(|_| liking) {
            Some(seed) => Cell::from(app.barcode(seed)),
            None => Cell::from("Sound"),
        });
    }
    widths.push(Constraint::Length(last_width));
    header.push(Cell::from(last_column));
    let table = Table::new(rows, widths).header(Row::new(header).style(dim())).row_highlight_style(cursor_style(focused));
    let mut state = TableState::default().with_selected(Some(app.cursor));
    frame.render_stateful_widget(table, rest, &mut state);
}

/// Under the hood: slides up over everything but the player's line and the keys.
fn draw_drawer(frame: &mut Frame, app: &App, since: Instant, closing: bool) {
    let full = frame.area();
    let tall = full.height.saturating_sub(NOW_ROWS + 1);
    // Decided on the height it slides up to, so nothing changes while it does.
    let fits = every_chip_fits(app.tracker.tab, app.tracker.chips() as u16, full.width, tall.saturating_sub(3));
    app.tracker.collapsed.set(!fits);
    let gone = app.now.unwrap_or(since).saturating_duration_since(since).as_secs_f32() / DRAWER_SLIDES.as_secs_f32();
    let eased = 1.0 - (1.0 - gone.min(1.0)).powi(3);
    let shown = if closing { 1.0 - eased } else { eased };
    let height = (f32::from(tall) * shown).round() as u16;
    if height == 0 || full.width == 0 {
        return;
    }
    let area = Rect::new(0, full.height - 1 - height, full.width, height);
    frame.render_widget(Clear, area);
    let buffer = frame.buffer_mut();
    for x in 0..area.width {
        buffer[(x, area.y)].set_symbol("▀").set_style(Style::new().fg(palette::frame()));
    }
    if height < 5 {
        return;
    }
    let label = Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD);
    // The title goes first when there's no room: the tabs matter more.
    let mut x = if area.width >= 58 {
        put(buffer, area, 2, 1, "▓▒░ Under the hood", label);
        22
    } else {
        2
    };
    for (n, name) in DRAWER_TABS.iter().enumerate() {
        let style = if n == app.tracker.tab { Style::new().fg(palette::text()).add_modifier(Modifier::BOLD | Modifier::UNDERLINED) } else { dim() };
        put(buffer, area, x, 1, name, style);
        x += name.len() as u16 + 3;
    }
    let chips = app.tracker.position.chips;
    if chips > 1 && app.tracker.one_chip_shows() {
        let which = format!("SID {} of {chips}, s to switch", app.tracker.chip + 1);
        // On the blank line below the tabs where it won't fit beside them.
        let (at, row) = if x + 1 + which.len() as u16 <= area.width { (x + 1, 1) } else { (2, 2) };
        put(buffer, area, at, row, &which, dim());
    }
    let body = Rect::new(area.x, area.y + 3, area.width, area.height - 3);
    match app.tracker.tab {
        1 => return draw_registers(buffer, app, body),
        2 => return draw_sweeps(buffer, app, body),
        3 => return draw_pitch(buffer, app, body),
        _ => {}
    }
    let state = &app.tracker;
    let Some(song) = &state.song else {
        let waiting = if let Some(problem) = &state.problem {
            problem.clone()
        } else if state.asking {
            "Rebuilding the tune from what its player writes…".to_string()
        } else if state.tune.is_none() && state.position.path.is_none() && app.status.as_ref().is_some_and(|s| s.now.is_none()) {
            "Nothing is playing. Press r for Surprise Me.".to_string()
        } else {
            "Listening…".to_string()
        };
        put(buffer, area, 2, 3, &waiting, dim());
        return;
    };
    let body_rows = area.height.saturating_sub(4);
    let panel = area.width >= TRACKER_PANEL_FROM;
    let spare = if panel { area.width.saturating_sub(34) } else { area.width };
    let step = (spare.saturating_sub(8) / 3).clamp(11, 16);
    let columns = [8, 8 + step, 8 + step * 2];
    let colours = [palette::cyan(), palette::green(), palette::orange()];
    let row_now = app.tracker_row();
    let current = current_instruments(song, row_now);

    put(buffer, area, 2, 3, "ROW", dim());
    for v in 0..3 {
        let name = current[v].and_then(|i| song.instruments.get(i)).map_or("", |i| i.name.as_str());
        let name = name.rsplit(" › ").next().unwrap_or("");
        let level = state.position.levels.get(v).copied().unwrap_or(0.0);
        let meter = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"][((level * 7.99) as usize).min(7)];
        let heading = format!("V{} {name}", v + 1);
        put(buffer, area, columns[v], 3, meter, Style::new().fg(colours[v]));
        put(buffer, area, columns[v] + 2, 3, &heading, Style::new().fg(colours[v]).add_modifier(Modifier::BOLD));
    }
    let middle = (body_rows / 2) as i64;
    let row_width = columns[2] + 11;
    for k in 0..body_rows {
        let number = row_now as i64 + i64::from(k) - middle;
        let y = 4 + k;
        let here = i64::from(k) == middle;
        if here {
            for x in 1..row_width.min(area.width) {
                buffer[(area.x + x, area.y + y)].set_style(Style::new().bg(palette::selection()));
            }
        }
        let Some(row) = usize::try_from(number).ok().and_then(|n| song.rows.get(n)) else { continue };
        let band = if here { Style::new().bg(palette::selection()) } else { Style::new() };
        let number_style = if here { band.fg(palette::accent()).add_modifier(Modifier::BOLD) } else { dim() };
        put(buffer, area, 2, y, &format!("{number:04X}"), number_style);
        for v in 0..3 {
            let (note, instrument, effect) = cell_parts(row.v.get(v).map_or("", String::as_str));
            let empty = band.fg(palette::faint());
            let note_style = match note {
                "···" => empty,
                "---" => band.fg(palette::muted()),
                _ if here => band.fg(palette::text()).add_modifier(Modifier::BOLD),
                _ => band.fg(colours[v]),
            };
            put(buffer, area, columns[v], y, note, note_style);
            put(buffer, area, columns[v] + 4, y, instrument, if instrument == "··" { empty } else { band.fg(palette::muted()) });
            put(buffer, area, columns[v] + 7, y, effect, if effect == "···" { empty } else { band.fg(palette::text()) });
        }
    }
    if panel {
        draw_tracker_panel(buffer, area, song, row_now, &current, row_width + 3, &colours, state.looking_at.is_some());
    }
}

const VOICE_COLOURS: fn() -> [ratatui::style::Color; 3] = || [palette::cyan(), palette::green(), palette::orange()];

fn draw_nothing_yet(buffer: &mut ratatui::buffer::Buffer, area: Rect) {
    put(buffer, area, 2, 0, "Nothing to show until a tune plays.", dim());
}

/// Each voice's registers, and the filter's, lit when the player writes a new value.
fn draw_registers(buffer: &mut ratatui::buffer::Buffer, app: &App, area: Rect) {
    let state = &app.tracker;
    let Some(registers) = state.history.back().filter(|r| r.len() >= 29) else { return draw_nothing_yet(buffer, area) };
    if state.chips() > 1 {
        return draw_voice_lines(buffer, state, area);
    }
    let colours = VOICE_COLOURS();
    let cell = |n: usize| -> Style {
        if state.lit(n) { Style::new().bg(palette::accent()).fg(palette::background()).add_modifier(Modifier::BOLD) } else { Style::new().fg(palette::text()) }
    };
    let step = 26u16;
    let columns = (area.width.saturating_sub(2) / step).max(1);
    for v in 0..3usize {
        let (x, y) = (2 + step * (v as u16 % columns), (v as u16 / columns) * 12);
        put(buffer, area, x, y, &format!("VOICE {}", v + 1), Style::new().fg(colours[v]).add_modifier(Modifier::BOLD));
        for (i, name) in VOICE_REGISTERS.iter().enumerate() {
            let n = v * 7 + i;
            let row = y + 1 + i as u16;
            put(buffer, area, x, row, &format!("$D4{n:02X}"), dim());
            put(buffer, area, x + 6, row, name, Style::new().fg(palette::text()));
            put(buffer, area, x + 15, row, &format!("{:02X}", registers[n]), cell(n));
        }
        let control = registers[v * 7 + 4];
        for (bit, name) in CONTROL_BITS.iter().enumerate() {
            let on = control & (1 << bit) != 0;
            let style = if on { Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD) } else { Style::new().fg(palette::faint()) };
            put(buffer, area, x + (bit as u16 % 4) * 5, y + 8 + bit as u16 / 4, name, style);
        }
    }
    let (fx, fy) = if columns >= 4 { (2 + step * 3, 0) } else { (2 + step * ((3 % columns) % columns), (3 / columns) * 12) };
    put(buffer, area, fx, fy, "FILTER", Style::new().fg(palette::violet()).add_modifier(Modifier::BOLD));
    for (i, (n, name)) in [(0x15, "CUT LO"), (0x16, "CUT HI"), (0x17, "RES/ROUT"), (0x18, "MODE/VOL")].iter().enumerate() {
        let row = fy + 1 + i as u16;
        put(buffer, area, fx, row, &format!("$D4{n:02X}"), dim());
        put(buffer, area, fx + 6, row, name, Style::new().fg(palette::text()));
        put(buffer, area, fx + 15, row, &format!("{:02X}", registers[*n]), cell(*n));
    }
    put(buffer, area, fx, fy + 6, "READ-ONLY", Style::new().fg(palette::muted()).add_modifier(Modifier::BOLD));
    for (i, (n, name)) in [(0x1B, "OSC 3"), (0x1C, "ENV 3")].iter().enumerate() {
        let row = fy + 7 + i as u16;
        put(buffer, area, fx, row, &format!("$D4{n:02X}"), dim());
        put(buffer, area, fx + 6, row, name, Style::new().fg(palette::text()));
        put(buffer, area, fx + 15, row, &format!("{:02X}", registers[*n]), Style::new().fg(palette::text()));
    }
    put(buffer, area, 2, area.height.saturating_sub(1), "Bytes light up when the player writes a new value.", dim());
}

/// Whether a tab can show `chips` chips readably in this much room.
fn every_chip_fits(tab: usize, chips: u16, width: u16, height: u16) -> bool {
    if chips <= 1 {
        return true;
    }
    match tab {
        1 => width >= VOICE_LINES_WIDTH && height >= 1 + chips * 5 + (chips - 1) + 1,
        2 => width / chips >= 24,
        3 => height / chips >= 5,
        _ => true,
    }
}

/// The chip to show when only one fits.
fn chosen_chip(state: &TrackerState) -> usize {
    (state.chip as usize).min(state.chips() - 1)
}

/// What the waveform bits of a voice's control byte say: a word, or initials for a mix.
fn wave_name(control: u8) -> String {
    let on: Vec<(&str, &str)> = [("TRI", "T"), ("SAW", "S"), ("PUL", "P"), ("NOI", "N")].into_iter().enumerate().filter(|(bit, _)| control & (0x10 << bit) != 0).map(|(_, names)| names).collect();
    match on.as_slice() {
        [] => "—".to_string(),
        [(word, _)] => (*word).to_string(),
        many => many.iter().map(|(_, initial)| *initial).collect::<Vec<_>>().join("+"),
    }
}

/// What the other bits say: words where they fit the column, else initials.
fn bits_name(control: u8) -> String {
    let on: Vec<&str> = ["GATE", "SYNC", "RING", "TEST"].into_iter().enumerate().filter(|(bit, _)| control & (1 << bit) != 0).map(|(_, name)| name).collect();
    if on.is_empty() {
        return "—".to_string();
    }
    let words = on.join(" ");
    if words.len() <= 10 { words } else { on.iter().map(|name| &name[..1]).collect::<Vec<_>>().join(" ") }
}

/// A horizontal bar: `share` of it in `colour`, the rest faint.
fn draw_bar(buffer: &mut ratatui::buffer::Buffer, area: Rect, x: u16, y: u16, width: u16, share: f32, colour: ratatui::style::Color) {
    let filled = (share.clamp(0.0, 1.0) * f32::from(width)).round() as u16;
    // Anything sounding at all shows.
    let filled = if share > 0.0 { filled.max(1) } else { filled };
    for at in 0..width {
        let (mark, shade) = if at < filled { ("█", colour) } else { ("░", palette::faint()) };
        put(buffer, area, x + at, y, mark, Style::new().fg(shade));
    }
}

/// A chip's registers as a line per voice and one for the filter, with byte pairs joined.
/// Shows every chip where they fit and the chosen one where they don't, with bars where
/// there's room. Orange only ever means just written; a voice with its gate shut fades.
fn draw_voice_lines(buffer: &mut ratatui::buffer::Buffer, state: &TrackerState, area: Rect) {
    let Some(frame) = state.history.back() else { return };
    let shown: Vec<usize> = if state.collapsed.get() { vec![chosen_chip(state)] } else { (0..state.chips()).collect() };
    let bars = area.width >= VOICE_BARS_WIDTH;
    // Where each column starts, with and without its bar.
    let (level, freq, pw_bar, pw, wave, bits, ad, sr) = if bars { (14, 26, 33, 43, 49, 57, 68, 72) } else { (0, 14, 0, 21, 27, 35, 46, 50) };
    let colours = VOICE_COLOURS();
    let bold = Style::new().add_modifier(Modifier::BOLD);
    let text = Style::new().fg(palette::text());
    let lit = bold.fg(palette::accent());
    put(buffer, area, 8, 0, "NOTE", dim());
    if bars {
        put(buffer, area, level, 0, "LEVEL", dim());
        put(buffer, area, pw_bar, 0, "PULSE WIDTH", dim());
    } else {
        put(buffer, area, pw, 0, "PW", dim());
    }
    put(buffer, area, freq, 0, "FREQ", dim());
    put(buffer, area, wave, 0, "WAVE", dim());
    put(buffer, area, bits, 0, "BITS", dim());
    put(buffer, area, ad, 0, "AD", dim());
    put(buffer, area, sr, 0, "SR", dim());
    let mut y = 1;
    for &chip in &shown {
        let base = chip * CHIP_REGISTERS;
        let Some(registers) = frame.get(base..base + CHIP_REGISTERS) else { continue };
        let changed = |n: &[usize]| n.iter().any(|n| state.lit(base + n));
        if shown.len() > 1 {
            put(buffer, area, 2, y, &format!("SID {}", chip + 1), bold.fg(palette::text()));
            put(buffer, area, 8, y, &"─".repeat(sr as usize - 6), Style::new().fg(palette::faint()));
            y += 1;
        }
        for v in 0..3usize {
            let at = v * 7;
            let control = registers[at + 4];
            let open = control & 1 != 0;
            let plain = if open { text } else { dim() };
            let style = |n: &[usize]| if changed(n) { lit } else { plain };
            put(buffer, area, 2, y, &format!("V{}", v + 1), if open { bold.fg(colours[v]) } else { dim() });
            let note = state.position.all_notes.get(chip).or(Some(&state.position.notes)).and_then(|notes| notes.get(v)).cloned().flatten();
            put(buffer, area, 8, y, note.as_deref().unwrap_or("—"), if note.is_some() { plain } else { Style::new().fg(palette::faint()) });
            if bars {
                let share = state.position.all_levels.get(chip).and_then(|levels| levels.get(v)).copied().unwrap_or(0.0);
                draw_bar(buffer, area, level, y, 10, share, if open { colours[v] } else { palette::muted() });
                let width = (u16::from(registers[at + 3] & 0x0F) << 8 | u16::from(registers[at + 2])) as f32 / 4095.0;
                // A pulse width means nothing to a voice not on a pulse wave.
                draw_bar(buffer, area, pw_bar, y, 8, width, if open && control & 0x40 != 0 { colours[v] } else { palette::muted() });
            }
            put(buffer, area, freq, y, &format!("{:02X}{:02X}", registers[at + 1], registers[at]), style(&[at, at + 1]));
            put(buffer, area, pw, y, &format!("{:X}{:02X}", registers[at + 3] & 0x0F, registers[at + 2]), style(&[at + 2, at + 3]));
            let quiet = Style::new().fg(palette::faint());
            let wave_now = wave_name(control);
            put(buffer, area, wave, y, &wave_now, if wave_now == "—" { quiet } else { style(&[at + 4]) });
            let bits_now = bits_name(control);
            put(buffer, area, bits, y, &bits_now, if bits_now == "—" { quiet } else if open { text.add_modifier(Modifier::BOLD) } else { dim() });
            put(buffer, area, ad, y, &format!("{:02X}", registers[at + 5]), style(&[at + 5]));
            put(buffer, area, sr, y, &format!("{:02X}", registers[at + 6]), style(&[at + 6]));
            y += 1;
        }
        let cutoff = u16::from(registers[0x16]) << 3 | u16::from(registers[0x15] & 7);
        let routed: Vec<String> = (0..3).filter(|v| registers[0x17] & (1 << v) != 0).map(|v| format!("V{}", v + 1)).collect();
        let through = if routed.is_empty() { "—".to_string() } else { routed.join(" ") };
        let modes: Vec<&str> = [("LP", 0x10), ("BP", 0x20), ("HP", 0x40)].into_iter().filter(|(_, bit)| registers[0x18] & bit != 0).map(|(name, _)| name).collect();
        let style = |n: &[usize]| if changed(n) { lit } else { text };
        put(buffer, area, 2, y, "FILT", bold.fg(palette::violet()));
        let mut x = 8;
        if bars {
            put(buffer, area, 8, y, &modes.join("+"), style(&[0x18]));
            // Registers can hold old values with no voice going through the filter.
            draw_bar(buffer, area, level, y, 10, f32::from(cutoff) / 2047.0, if routed.is_empty() { palette::muted() } else { palette::violet() });
            put(buffer, area, freq, y, &format!("{cutoff:03X}"), style(&[0x15, 0x16]));
            put(buffer, area, freq + 4, y, "cutoff", dim());
            x = freq + 12;
        }
        let mut write = |label: &str, value: String, style: Style| {
            if !label.is_empty() {
                put(buffer, area, x, y, label, dim());
                x += label.chars().count() as u16 + 1;
            }
            put(buffer, area, x, y, &value, style);
            x += value.chars().count() as u16 + 2;
        };
        if !bars {
            write("cutoff", format!("{cutoff:03X}"), style(&[0x15, 0x16]));
        }
        write("res", format!("{:X}", registers[0x17] >> 4), style(&[0x17]));
        write("through", through, style(&[0x17]));
        if !bars && !modes.is_empty() {
            write("", modes.join("+"), style(&[0x18]));
        }
        write("vol", format!("{:X}", registers[0x18] & 0x0F), style(&[0x18]));
        write("osc3", format!("{:02X}", registers[0x1B]), text);
        write("env3", format!("{:02X}", registers[0x1C]), text);
        y += 2;
    }
    put(buffer, area, 2, area.height.saturating_sub(1), "Orange: just written. Faded: gate shut. FREQ and PW join two bytes each.", dim());
}

/// A frame for each of `columns` columns, ending now, at no more than two frames a column.
fn frames_across(history: &std::collections::VecDeque<Vec<u8>>, columns: usize) -> Vec<&[u8]> {
    if history.is_empty() || columns == 0 {
        return Vec::new();
    }
    let shown = history.len().min(columns.saturating_mul(2).max(1).min(history.len()));
    let first = history.len() - shown;
    (0..columns)
        .filter_map(|c| {
            let at = first + c * shown / columns;
            let frame = history.get(at).map(Vec::as_slice)?;
            (frame.len() >= 29).then_some(frame)
        })
        .collect()
}

/// `frames_across`, for one chip.
fn chip_frames(history: &std::collections::VecDeque<Vec<u8>>, columns: usize, chip: usize) -> Vec<&[u8]> {
    let base = chip * CHIP_REGISTERS;
    frames_across(history, columns).into_iter().filter_map(|frame| frame.get(base..base + CHIP_REGISTERS)).collect()
}

/// A strip of block characters `rows` tall, with values 0–1 across it.
fn draw_strip(buffer: &mut ratatui::buffer::Buffer, area: Rect, x: u16, y: u16, rows: u16, values: &[f32], colour: ratatui::style::Color) {
    const BLOCKS: [&str; 9] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
    for (c, value) in values.iter().enumerate() {
        let eighths = (value.clamp(0.0, 1.0) * f32::from(rows) * 8.0).round() as u16;
        for r in 0..rows {
            let level = eighths.saturating_sub(r * 8).min(8) as usize;
            if level > 0 {
                put(buffer, area, x + c as u16, y + rows - 1 - r, BLOCKS[level], Style::new().fg(colour));
            }
        }
    }
}

/// Pulse width, the filter and the gates over the last few seconds.
fn draw_sweeps(buffer: &mut ratatui::buffer::Buffer, app: &App, area: Rect) {
    let state = &app.tracker;
    let chips = state.chips() as u16;
    if state.collapsed.get() || chips == 1 {
        return draw_sweeps_of(buffer, state, area, chosen_chip(state), 1);
    }
    let width = area.width / chips;
    for chip in 0..chips {
        draw_sweeps_of(buffer, state, Rect::new(area.x + chip * width, area.y, width.saturating_sub(1), area.height), chip as usize, chips);
    }
}

/// One chip's sweeps. Beside other chips, the labels get shorter.
fn draw_sweeps_of(buffer: &mut ratatui::buffer::Buffer, state: &TrackerState, area: Rect, chip: usize, chips: u16) {
    let beside = chips > 1;
    // Beside other chips, a column's edge is margin enough.
    let columns = area.width.saturating_sub(if beside { 6 } else { 10 }) as usize;
    let frames = chip_frames(&state.history, columns, chip);
    let Some(latest) = frames.last() else { return draw_nothing_yet(buffer, area) };
    // The first voice on a pulse wave, as a pulse width means nothing to the others.
    let voice = (0..3).find(|v| latest[v * 7 + 4] & 0x40 != 0);
    let strip_rows = (area.height.saturating_sub(if beside { 6 } else { 5 }) / 3).saturating_sub(1).clamp(1, 12);
    let label = Style::new().add_modifier(Modifier::BOLD);
    let mut y = 0;
    if beside {
        put(buffer, area, 2, 0, &format!("SID {}", chip + 1), label.fg(palette::text()));
        y = 1;
    }
    let colours = VOICE_COLOURS();
    let v = voice.unwrap_or(0);
    let pulse_width = |frame: &[u8]| (u16::from(frame[v * 7 + 3] & 0x0F) << 8 | u16::from(frame[v * 7 + 2])) as f32 / 4095.0;
    let pw_now = u16::from(latest[v * 7 + 3] & 0x0F) << 8 | u16::from(latest[v * 7 + 2]);
    let pw_name = match (voice.is_some(), beside) {
        (true, false) => format!("PULSE WIDTH V{}  {pw_now:03X}", v + 1),
        (false, false) => "PULSE WIDTH  no voice on a pulse wave now".to_string(),
        (true, true) => format!("PULSE V{} {pw_now:03X}", v + 1),
        (false, true) => "PULSE none".to_string(),
    };
    put(buffer, area, 2, y, &pw_name, label.fg(colours[v]));
    let values: Vec<f32> = frames.iter().map(|f| pulse_width(f)).collect();
    draw_strip(buffer, area, 2, y + 1, strip_rows, &values, colours[v]);
    y += strip_rows + 1;

    let cutoff = |frame: &[u8]| u16::from(frame[0x16]) << 3 | u16::from(frame[0x15] & 7);
    // Registers can hold old values with no voice going through the filter.
    let filtering = frames.iter().any(|f| f[0x17] & 7 != 0);
    let unused = if filtering { "" } else { "  not in use" };
    let name = if beside { "CUTOFF " } else { "FILTER CUTOFF  " };
    put(buffer, area, 2, y, &format!("{name}{:03X}{unused}", cutoff(latest)), label.fg(palette::violet()));
    let values: Vec<f32> = frames.iter().map(|f| f32::from(cutoff(f)) / 2047.0).collect();
    draw_strip(buffer, area, 2, y + 1, strip_rows, &values, palette::violet());
    y += strip_rows + 1;

    let name = if beside { "RES " } else { "RESONANCE  " };
    put(buffer, area, 2, y, &format!("{name}{:X}{unused}", latest[0x17] >> 4), label.fg(palette::violet()));
    let values: Vec<f32> = frames.iter().map(|f| f32::from(f[0x17] >> 4) / 15.0).collect();
    draw_strip(buffer, area, 2, y + 1, strip_rows, &values, palette::violet());
    y += strip_rows + 1;

    put(buffer, area, 2, y, "GATES", label);
    for voice in 0..3u16 {
        let colour = colours[voice as usize];
        let row = y + 1 + voice;
        put(buffer, area, 2, row, &format!("V{}", voice + 1), Style::new().fg(colour));
        for (c, frame) in frames.iter().enumerate() {
            let open = frame[voice as usize * 7 + 4] & 1 == 1;
            let (mark, style) = if open { ("━", Style::new().fg(colour)) } else { ("─", Style::new().fg(palette::faint())) };
            put(buffer, area, 6 + c as u16, row, mark, style);
        }
    }
}

/// Where each voice's pitch has been: time across, notes up.
fn draw_pitch(buffer: &mut ratatui::buffer::Buffer, app: &App, area: Rect) {
    let state = &app.tracker;
    let chips = state.chips() as u16;
    if state.collapsed.get() || chips == 1 {
        return draw_pitch_of(buffer, state, area, chosen_chip(state), 1);
    }
    let height = area.height / chips;
    for chip in 0..chips {
        draw_pitch_of(buffer, state, Rect::new(area.x, area.y + chip * height, area.width, height), chip as usize, chips);
    }
}

/// One chip's trail. Sharing the height with other chips, it names itself and packs its labels.
fn draw_pitch_of(buffer: &mut ratatui::buffer::Buffer, state: &TrackerState, area: Rect, chip: usize, chips: u16) {
    let width = area.width.saturating_sub(16) as usize;
    let frames = chip_frames(&state.history, width, chip);
    if frames.is_empty() || area.height < 3 {
        return draw_nothing_yet(buffer, area);
    }
    let beside = chips > 1;
    let rows = area.height.saturating_sub(1);
    let (low, high) = (24.0f64, 96.0f64);
    let row_of = |midi: f64| -> Option<u16> {
        let share = (midi - low) / (high - low);
        (0.0..=1.0).contains(&share).then(|| rows - 1 - ((share * f64::from(rows - 1)).round() as u16))
    };
    for octave in (24..=96).step_by(if rows < 13 { 24 } else { 12 }) {
        if let Some(y) = row_of(f64::from(octave)) {
            put(buffer, area, 2, y, &format!("C{}", octave / 12 - 1), dim());
            for x in 6..(6 + width as u16) {
                put(buffer, area, x, y, "·", Style::new().fg(palette::faint()));
            }
        }
    }
    let clock = state.clock();
    let colours = VOICE_COLOURS();
    for voice in 0..3usize {
        for (c, frame) in frames.iter().enumerate() {
            let registers = &frame[voice * 7..voice * 7 + 7];
            let freq = u16::from_le_bytes([registers[0], registers[1]]);
            if registers[4] & 1 == 0 || freq == 0 {
                continue;
            }
            let midi = 69.0 + 12.0 * (f64::from(freq) * clock / 16_777_216.0 / 440.0).log2();
            if let Some(y) = row_of(midi) {
                put(buffer, area, 6 + c as u16, y, "━", Style::new().fg(colours[voice]));
            }
        }
        let notes = state.position.all_notes.get(chip).unwrap_or(&state.position.notes);
        let note = notes.get(voice).cloned().flatten().unwrap_or_else(|| "—".into());
        let x = 7 + width as u16;
        let y = if beside { voice as u16 + 1 } else { voice as u16 * 2 };
        put(buffer, area, x, y, &format!("V{}", voice + 1), Style::new().fg(colours[voice]).add_modifier(Modifier::BOLD));
        put(buffer, area, x + 3, y, &note, Style::new().fg(palette::text()));
    }
    if beside {
        put(buffer, area, 7 + width as u16, 0, &format!("SID {}", chip + 1), Style::new().fg(palette::text()).add_modifier(Modifier::BOLD));
    }
}

fn put(buffer: &mut ratatui::buffer::Buffer, area: Rect, x: u16, y: u16, text: &str, style: Style) {
    if x < area.width && y < area.height {
        buffer.set_stringn(area.x + x, area.y + y, text, (area.width - x) as usize, style);
    }
}

/// "C-4 02 ARP" as its three parts, with dots for what's not there.
fn cell_parts(cell: &str) -> (&str, &str, &str) {
    let mut parts = cell.split(' ');
    let note = parts.next().filter(|n| !n.is_empty() && *n != "...").unwrap_or("···");
    let instrument = parts.next().filter(|i| *i != "00").unwrap_or("··");
    let effect = parts.next().filter(|e| *e != "...").unwrap_or("···");
    (note, instrument, effect)
}

/// The instrument each voice last started a note with, as of `row`.
fn current_instruments(song: &TrackerSong, row: usize) -> [Option<usize>; 3] {
    let last = row.min(song.rows.len().saturating_sub(1));
    // A long look back is cheap next to a frame, and a voice can be quiet for long.
    std::array::from_fn(|v| {
        song.rows[..=last].iter().rev().take(2048).find_map(|r| {
            let (_, instrument, _) = cell_parts(r.v.get(v).map_or("", String::as_str));
            usize::from_str_radix(instrument, 16).ok()?.checked_sub(1)
        })
    })
}

#[allow(clippy::too_many_arguments)]
fn draw_tracker_panel(buffer: &mut ratatui::buffer::Buffer, area: Rect, song: &TrackerSong, row: usize, current: &[Option<usize>; 3], x: u16, colours: &[ratatui::style::Color; 3], looking: bool) {
    let heading = Style::new().fg(palette::muted()).add_modifier(Modifier::BOLD);
    let mut y = 3;
    put(buffer, area, x, y, "INSTRUMENTS", heading);
    y += 1;
    let total = song.instruments.len();
    for v in 0..3 {
        let Some(instrument) = current[v].and_then(|i| song.instruments.get(i).map(|f| (i, f))) else { continue };
        let name: String = instrument.1.name.chars().take(14).collect();
        put(buffer, area, x, y, &format!("{:02X} {name:<15}{:02X} {:02X}", instrument.0 + 1, instrument.1.ad, instrument.1.sr), Style::new().fg(colours[v]));
        y += 1;
    }
    put(buffer, area, x, y, &format!("{total} in this tune"), dim());
    y += 2;
    if let Some(row) = song.rows.get(row) {
        put(buffer, area, x, y, "FILTER", heading);
        y += 1;
        let modes: Vec<&str> = [(1, "LP"), (2, "BP"), (4, "HP")].iter().filter(|(bit, _)| row.m & bit != 0).map(|(_, name)| *name).collect();
        if row.ro == 0 || modes.is_empty() {
            put(buffer, area, x, y, "Not in use", dim());
            y += 1;
        } else {
            let lit = (usize::from(row.c) * 20 / 2047).min(20);
            put(buffer, area, x, y, &format!("{:<3}", modes.join("+")), Style::new().fg(palette::violet()));
            put(buffer, area, x + 3, y, &"█".repeat(lit), Style::new().fg(palette::violet()));
            put(buffer, area, x + 3 + lit as u16, y, &"░".repeat(20 - lit), Style::new().fg(palette::faint()));
            y += 1;
            let voices: Vec<&str> = [(1, "V1"), (2, "V2"), (4, "V3")].iter().map(|(bit, name)| if row.ro & bit != 0 { *name } else { "--" }).collect();
            put(buffer, area, x, y, &format!("RES {:<2} {}", row.r, voices.join(" ")), dim());
            y += 1;
        }
    }
    y += 1;
    let mut notes = Vec::new();
    if song.has_grid {
        notes.push(format!("{} frames a row, {:.1} rows a second.", song.frames_per_row, song.frame_rate / f64::from(song.frames_per_row)));
    } else {
        notes.push("No steady beat found, so the rows are only a ruler.".to_string());
    }
    notes.push("Rebuilt from what the player writes to the chip, as .sid files hold code, not patterns.".to_string());
    if looking {
        notes.push("Looking around: f follows the music again.".to_string());
    }
    let width = area.width.saturating_sub(x + 1) as usize;
    for line in notes.iter().flat_map(|note| wrapped(note, width)) {
        put(buffer, area, x, y, &line, dim());
        y += 1;
    }
}

/// What Describe took from the sentence, and how much it made; two lines at most.
fn describe_line(app: &App, width: usize) -> Vec<Line<'static>> {
    let state = &app.describing;
    let text = if state.busy {
        "Making the list…".to_string()
    } else {
        let said = state.note.clone().or_else(|| state.understood.clone());
        let said = said.map(|text| text.trim_end_matches('.').to_string());
        [said, state.facts.clone()].into_iter().flatten().collect::<Vec<_>>().join(" · ")
    };
    wrapped(&text, width.saturating_sub(2).max(1)).into_iter().take(2).map(|line| Line::styled(format!(" {line}"), dim())).collect()
}

/// Before there's a list: what went wrong if something did, and the suggestions.
fn draw_describe_start(frame: &mut Frame, app: &App, area: Rect) {
    let width = area.width.saturating_sub(2).max(1) as usize;
    let mut lines = vec![Line::raw("")];
    let intro = app.describing.problem.as_deref().unwrap_or("Say what you'd like to hear, like “fast arpeggios from 1987”.");
    let style = if app.describing.problem.is_some() { Style::new().fg(palette::accent()) } else { dim() };
    lines.extend(wrapped(intro, width).into_iter().map(|line| Line::styled(format!(" {line}"), style)));
    lines.push(Line::raw(""));
    lines.push(Line::styled(" Or start from one of these", Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD)));
    let choosing = app.focus == Focus::List && matches!(app.mode, Mode::Normal);
    for (n, (name, _, what)) in SUGGESTIONS.iter().enumerate() {
        let line = Line::from(vec![Span::raw(format!(" {name:<20}")), Span::styled(*what, dim())]);
        lines.push(if choosing && n == app.cursor { line.style(cursor_style(true)) } else { line });
    }
    frame.render_widget(Paragraph::new(lines), area);
}

/// Text on as many lines of `width` as it needs, split between words.
fn wrapped(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let word: String = word.chars().take(width.max(1)).collect();
        if !line.is_empty() && line.chars().count() + 1 + word.chars().count() > width {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(&word);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// The tune under the cursor: how it sounds, and what it sounds like.
fn draw_rail(frame: &mut Frame, app: &App, area: Rect) {
    let [title, area] = Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).areas(area);
    let name = if matches!(app.view, View::Hvsc("musicians")) { "▓▒░ This composer" } else if matches!(app.view, View::Hvsc(_)) { "▓▒░ This folder" } else { "▓▒░ This tune" };
    frame.render_widget(heading(name.into(), true), title);
    let Some(tune) = app.rows.get(app.cursor) else { return };
    let lines = if matches!(app.view, View::Hvsc(_)) { composer_lines(app, tune) } else { rail_lines(app, tune, area.width as usize, area.height as usize) };
    frame.render_widget(Paragraph::new(lines), area);
}

/// The panel beside a section's composers.
fn composer_lines(app: &App, composer: &Tune) -> Vec<Line<'static>> {
    let mut lines = vec![Line::styled(composer.title.clone(), Style::new().add_modifier(Modifier::BOLD))];
    if !composer.author.is_empty() {
        lines.push(Line::styled(composer.author.clone(), dim()));
    }
    let plural = if composer.songs == 1 { "" } else { "s" };
    lines.push(Line::styled(format!("{} tune{plural}  {}", composer.songs, composer.released), dim()));
    if let Some(Some(traits)) = app.prints.get(&composer.path) {
        lines.push(Line::raw(""));
        lines.push(Line::styled("Their sound, on average", Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD)));
        lines.extend(fingerprint::tall(traits, 3));
    }
    lines.push(Line::raw(""));
    lines.push(Line::styled("↵ opens their tunes", dim()));
    lines
}

/// What's in the panel, for its size. Who and how it sounds in words always, then
/// what it sounds like, then as much of the fingerprint as there's room for, from
/// the barcode to the voices.
fn rail_lines(app: &App, tune: &Tune, width: usize, height: usize) -> Vec<Line<'static>> {
    let details = app.details.get(&tune.path);
    let label = Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD);
    let length = tune.secs.map(|s| format!("  {}", clock(f64::from(s)))).unwrap_or_default();

    let mut about: Vec<Line> = wrapped(&tune.title, width)
        .into_iter()
        .map(|line| Line::styled(line, Style::new().add_modifier(Modifier::BOLD)))
        .collect();
    about.push(Line::styled(tune.author.clone(), dim()));
    about.push(Line::styled(format!("{}{length}", tune.released), dim()));
    about.push(Line::raw(""));
    about.push(Line::styled("Sound", label));
    match details.and_then(|d| d.summary.as_deref()) {
        Some(summary) => about.extend(wrapped(summary, width).into_iter().map(Line::raw)),
        None => about.push(Line::styled("Listening…", dim())),
    }

    let more = app.keys.scheme.choose("l", "L", "l");
    let mut likes = vec![Line::raw(""), Line::from(vec![Span::styled("Sounds like", label), Span::styled(format!("   {more} for more"), dim())])];
    let with_bars = app.showing_prints();
    match details.and_then(|d| d.likes.as_ref()) {
        Some(found) if found.is_empty() => likes.push(Line::styled("Nothing yet.", dim())),
        Some(found) => {
            let bar_room = if with_bars { fingerprint::SMALL_WIDTH as usize + 1 } else { 0 };
            let wide = width.saturating_sub(5 + bar_room);
            for like in found {
                let score = like.score.map_or(String::new(), |s| format!("{:>4.0}%", s * 100.0));
                let title: String = like.title.chars().take(wide).collect();
                let mut spans = if with_bars { app.barcode(&like.path).spans } else { Vec::new() };
                if with_bars {
                    spans.push(Span::raw(" "));
                }
                spans.push(Span::raw(format!("{title:<wide$}")));
                spans.push(Span::styled(score, dim()));
                likes.push(Line::from(spans));
            }
        }
        None => likes.push(Line::styled("Listening…", dim())),
    }

    // The panel keeps its place for the likes, so it doesn't jump as they arrive.
    let mut room = height.saturating_sub(about.len() + 2 + LIKE_SHOWN);
    let mut lines = about;
    if let Some(print) = details.and_then(|d| d.print.as_ref()).filter(|_| with_bars) {
        let rows = if room >= 5 { 3 } else { 2 };
        if room >= 4 {
            lines.push(Line::raw(""));
            lines.extend(fingerprint::tall(&print.traits, rows));
            room -= rows + 2;
        }
        if let Some(mix) = print.mix.as_ref().filter(|_| room >= 3) {
            lines.push(Line::raw(""));
            lines.extend(fingerprint::mix_lines(mix, width));
            room -= 3;
        }
        if let Some(activity) = print.activity.as_ref().filter(|_| room >= 5) {
            lines.push(Line::raw(""));
            lines.extend(fingerprint::voice_lines(activity, width, |voice| viz::ink(voice, 3, app.skull.truecolor)));
        }
    }
    lines.extend(likes);
    lines
}

fn now_line(app: &App) -> Line<'static> {
    match app.status.as_ref().and_then(|s| s.now.as_ref().map(|n| (s, n))) {
        Some((status, now)) => {
            let color = if status.state == "paused" { palette::muted() } else { palette::accent() };
            let mut spans = vec![
                Span::styled(format!("♪ {}", now.title), Style::new().fg(color).add_modifier(Modifier::BOLD)),
                Span::raw(format!(" · {}", now.author)),
                Span::styled(format!("  {}", now.released), dim()),
            ];
            if now.songs > 1 {
                spans.push(Span::styled(format!("  subtune {} of {}", now.song, now.songs), dim()));
            }
            if status.favourite {
                spans.push(Span::styled("  ♥", Style::new().fg(palette::red())));
            }
            if status.state == "paused" {
                spans.push(Span::styled("  paused", dim()));
            }
            Line::from(spans)
        }
        None => Line::styled("Nothing is playing. Press r for Surprise Me.", dim()),
    }
}

/// What's playing, over a slim bar with the time beside it.
fn draw_now(frame: &mut Frame, app: &App, area: Rect) {
    let [title, bar] = Layout::vertical([Constraint::Length(1), Constraint::Length(1)]).areas(area);
    frame.render_widget(Paragraph::new(now_line(app)), title);
    frame.render_widget(Paragraph::new("RESONANCE").style(Style::new().fg(palette::frame()).add_modifier(Modifier::BOLD)).alignment(Alignment::Right), title);
    draw_progress(frame, app, bar);
}

fn draw_progress(frame: &mut Frame, app: &App, area: Rect) {
    let Some(status) = app.status.as_ref().filter(|s| s.now.is_some()) else { return };
    let [strip, _, time] = Layout::horizontal([Constraint::Min(1), Constraint::Length(2), Constraint::Length(13)]).areas(area);
    let loudest = app.ears.latest().iter().fold(0.0_f32, |most, voice| most.max(voice.level));
    viz::progress(frame.buffer_mut(), strip, app.progress().unwrap_or(0.0), loudest, app.ears.heard);
    let elapsed = app.elapsed();
    let words = match status.duration {
        Some(duration) => format!("{} / {}", clock(elapsed), clock(duration)),
        None => clock(elapsed),
    };
    frame.render_widget(Paragraph::new(words).alignment(Alignment::Right), time);
}

/// The page's name, and each voice's note and level.
/// Only the keys that matter right now; `?` has them all.
fn draw_keys(frame: &mut Frame, app: &App, area: Rect) {
    if let Some(message) = &app.message {
        frame.render_widget(Paragraph::new(Line::styled(message.clone(), Style::new().fg(palette::accent()))), area);
        return;
    }
    let key_style = Style::new().fg(palette::accent());
    let mut spans = Vec::new();
    for (key, what) in fit_bar(bar_keys(app), area.width, "?") {
        spans.push(Span::styled(key, key_style));
        spans.push(Span::styled(format!(" {what}  "), dim()));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// As many whole hints as fit, in the order given, and always the one for the
/// `keep` key: `?` is how to find those left out, Esc the way back.
fn fit_bar(keys: Vec<(&'static str, &'static str)>, width: u16, keep: &str) -> Vec<(&'static str, &'static str)> {
    let wide = |(key, what): &(&str, &str)| key.chars().count() + what.chars().count() + 3;
    let mut room = (width as usize).saturating_sub(keys.iter().filter(|k| k.0 == keep).map(wide).sum());
    let mut fits = true;
    keys.into_iter()
        .filter(|entry| {
            if entry.0 == keep {
                return true;
            }
            fits = fits && wide(entry) <= room;
            if fits {
                room -= wide(entry);
            }
            fits
        })
        .collect()
}

/// The bottom bar, in the keys of the set in use, the most useful first.
fn bar_keys(app: &App) -> Vec<(&'static str, &'static str)> {
    let scheme = app.keys.scheme;
    let movement = (scheme.choose("↑ ↓", "j k", "⌃N ⌃P"), "move");
    if matches!(app.mode, Mode::Reading(_)) {
        return vec![("↑ ↓", "read"), ("esc", "close")];
    }
    if matches!(app.mode, Mode::Drawer(_) | Mode::DrawerClosing(_)) {
        let mut keys = if app.tracker.tab == 0 {
            vec![("tab", "next view"), (scheme.choose("↑ ↓", "j k", "⌃N ⌃P"), "look around"), ("f", "follow"), ("p", "pause"), (". ,", "next, previous"), ("esc", "close"), ("q", "quit")]
        } else {
            vec![("tab", "next view"), ("p", "pause"), (". ,", "next, previous"), ("esc", "close"), ("q", "quit")]
        };
        if app.tracker.position.chips > 1 && app.tracker.one_chip_shows() {
            keys.insert(1, ("s", "next SID"));
        }
        return keys;
    }
    if app.focus == Focus::List {
        match app.view {
            View::HvscHome => return vec![movement, ("↵", "open"), ("S", "shuffle the collection"), ("T", "play the Top 100"), ("tab", "library"), ("?", "all keys"), ("q", "quit")],
            View::Hvsc(_) if matches!(app.mode, Mode::Jump(_)) => return vec![("type", "to find"), ("↵", "done"), ("esc", "done")],
            View::Hvsc(_) => return vec![movement, ("↵", "open"), ("/", "find"), ("p", "pause"), ("tab", "library"), ("?", "all keys"), ("q", "quit")],
            View::Describe if matches!(app.mode, Mode::Describing(_)) => return vec![("type", "what you'd like to hear"), ("↵", "make the list"), ("↓", "suggestions"), ("esc", "done")],
            View::Describe if app.rows.is_empty() => return vec![movement, ("↵", "try it"), ("/", "say it"), ("tab", "library"), ("?", "all keys"), ("q", "quit")],
            View::Describe if app.marked.is_empty() => return vec![movement, ("↵", "play"), ("/", "change it"), ("n", "save as playlist"), (scheme.choose("l", "L", "l"), "sounds like"), ("esc", "start over"), ("?", "all keys"), ("q", "quit")],
            View::Composer { .. } | View::Curated { .. } => return vec![movement, ("↵", "play"), (scheme.choose("l", "L", "l"), "sounds like"), ("f", "favourite"), ("esc", "back"), ("?", "all keys"), ("q", "quit")],
            _ => {}
        }
    }
    match (&app.mode, app.focus) {
        (Mode::Search, _) => vec![("type", "to search"), ("↵", "go to the list"), ("esc", "back")],
        (_, Focus::Sidebar) => vec![movement, ("↵", "open"), ("tab", "list"), ("/", "search"), ("p", "pause"), ("?", "all keys"), ("q", "quit")],
        _ if !app.marked.is_empty() => vec![("a", "add to playlist"), ("n", "new playlist"), (scheme.choose("x", "dd", "⌃D"), "remove"), ("f", "favourite"), ("␣", "mark"), ("?", "all keys")],
        _ => vec![
            movement,
            ("↵", "play"),
            ("p", "pause"),
            (scheme.choose("l", "L", "l"), "sounds like"),
            (scheme.choose("d", "D", "d"), "drift"),
            ("f", "favourite"),
            ("/", "search"),
            ("v", "visuals"),
            ("tab", "library"),
            ("?", "all keys"),
            ("q", "quit"),
        ],
    }
}

fn centred(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect::new(area.x + (area.width - width) / 2, area.y + (area.height - height) / 2, width, height)
}

fn draw_add_to(frame: &mut Frame, app: &App, cursor: usize) {
    let area = centred(frame.area(), 40, 14);
    frame.render_widget(Clear, area);
    let items: Vec<ListItem> = app.lists.iter().map(|l| ListItem::new(l.name.clone())).collect();
    let mut state = ListState::default().with_selected(Some(cursor));
    let title = format!(" Add {} to ", count(app.chosen().len()));
    frame.render_stateful_widget(
        List::new(items).block(pane(title, true)).highlight_style(cursor_style(true)),
        area,
        &mut state,
    );
}

fn draw_prompt(frame: &mut Frame, title: &str, text: &str) {
    let area = centred(frame.area(), 46, 3);
    frame.render_widget(Clear, area);
    frame.render_widget(Paragraph::new(format!("{text}▏")).block(pane(format!(" {title} "), true)), area);
}

fn draw_browser(frame: &mut Frame, browser: &Browser, scheme: KeyScheme) {
    let area = centred(frame.area(), 70, 22);
    frame.render_widget(Clear, area);
    let items: Vec<ListItem> = browser
        .entries
        .iter()
        .map(|(name, is_dir)| {
            let mark = if browser.marked.contains(&browser.dir.join(name)) { "✓ " } else { "  " };
            let shown = if *is_dir { format!("{name}/") } else { name.clone() };
            let style = if *is_dir { Style::new().fg(palette::cyan()) } else { Style::new() };
            ListItem::new(Line::from(vec![Span::raw(mark), Span::styled(shown, style)]))
        })
        .collect();
    let mut state = ListState::default().with_selected(Some(browser.cursor));
    let up = scheme.choose("←", "h", "⌃B");
    let block = pane(format!(" {} ", browser.dir.display()), true)
        .title_bottom(Line::from(format!(" ␣ mark  ↵ open or use  {up} up  esc cancel ")).alignment(Alignment::Right));
    frame.render_stateful_widget(List::new(items).block(block).highlight_style(cursor_style(true)), area, &mut state);
}

fn help_lines(scheme: KeyScheme) -> [(&'static str, &'static str); 21] {
    // Only what differs between the sets.
    let pick = |normal, vim, emacs| scheme.choose(normal, vim, emacs);
    [
        (pick("↑ ↓  j k", "j k  ↑ ↓", "⌃N ⌃P  j k  ↑ ↓"), "Move"),
        (pick("PgUp PgDn Home End", "⌃U ⌃D  gg G", "⌥V ⌃V  ⌥< ⌥>"), "Page up or down, top, end"),
        (pick("Tab  ← →", "Tab  h l", "Tab  ⌃B ⌃F"), "Sidebar or list"),
        ("↵", "Open, or play from here"),
        (pick("/", "/", "/  ⌃S"), "Search the collection"),
        ("p", "Pause or carry on"),
        (". ,", "Next or previous tune"),
        ("r  S  T", "Surprise Me; Home: shuffle, Top 100"),
        ("␣", "Mark a tune"),
        (pick("l", "L", "l"), "Sounds Like this tune"),
        (pick("d", "D", "d"), "Sound Drift from this tune"),
        ("f", "Add to Favourites"),
        ("a", "Add to a playlist"),
        ("n", "New playlist, with what's marked"),
        (pick("x", "x  dd", "x  ⌃D"), "Take out of this playlist"),
        ("⇧↑ ⇧↓  K J", "Move a tune in the playlist"),
        ("o", "Find files: add or play them"),
        ("s", "Show in the Resonance window"),
        ("v  u", "Visuals, or Under the hood: the tracker"),
        ("?  c", "This help, or the credits"),
        ("q", "Quit; the music carries on"),
    ]
}

fn draw_help(frame: &mut Frame, choice: Choice) {
    // The legend goes beside the keys, or under them, or waits for a bigger window.
    let window = frame.area();
    let legend = fingerprint::legend();
    let legend_rows = legend.len() as u16 + 1;
    let beside = window.width >= HELP_WIDTH + LEGEND_WIDTH;
    let under = !beside && window.height >= HELP_HEIGHT + legend_rows;
    let (width, height) = match (beside, under) {
        (true, _) => (HELP_WIDTH + LEGEND_WIDTH, HELP_HEIGHT),
        (_, true) => (HELP_WIDTH, HELP_HEIGHT + legend_rows),
        _ => (HELP_WIDTH, HELP_HEIGHT),
    };
    let area = centred(window, width, height);
    frame.render_widget(Clear, area);
    let mut lines: Vec<Line> = help_lines(choice.scheme)
        .iter()
        .map(|(key, what)| {
            Line::from(vec![
                // By characters, as the keys' symbols are wider in bytes.
                Span::styled(format!("{key:<19}"), Style::new().fg(palette::accent())),
                Span::raw(*what),
            ])
        })
        .collect();
    lines.push(Line::styled("Set RESONANCE_KEYS, or use --keys, to change these.", dim()));
    let title = format!(" {} keys, {} ", choice.scheme.name(), choice.reason);
    let block = pane(title, true);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if beside {
        let [keys, gap] = Layout::horizontal([Constraint::Length(HELP_WIDTH - 2), Constraint::Min(0)]).areas(inner);
        frame.render_widget(Paragraph::new(lines), keys);
        frame.render_widget(Paragraph::new(legend), inside(gap));
    } else {
        if under {
            lines.push(Line::raw(""));
            lines.extend(legend);
        }
        frame.render_widget(Paragraph::new(lines), inner);
    }
}

// MARK: Running

impl Request {
    /// Reads that can take seconds: a composer's sound reads all their tunes, the first
    /// look at a section reads every folder, and the first sentence reads every header.
    /// Pause shouldn't wait behind those.
    fn is_bulk(&self) -> bool {
        matches!(self.tag, Tag::Prints(_) | Tag::Described { .. } | Tag::TrackerSong) || self.cmd == "hvsc.authors"
    }
}

/// A connection on its own thread, so a slow search never holds up the screen.
struct Worker {
    tx: mpsc::Sender<Request>,
}

impl Worker {
    fn spawn(mut client: Client, replies: mpsc::Sender<(Tag, Result<Value, String>)>) -> Worker {
        let (tx, rx) = mpsc::channel::<Request>();
        std::thread::spawn(move || {
            for request in rx {
                let answer = client.call(request.cmd, request.args);
                if replies.send((request.tag, answer)).is_err() {
                    return;
                }
            }
        });
        Worker { tx }
    }
}

pub fn run(keys: Choice, only_credits: bool) -> Result<(), String> {
    // Before the screen changes, as it may have to start the app.
    let slow_client = Client::connect()?;
    let bulk_client = Client::connect()?;
    let fast_client = Client::connect()?;
    let (reply_tx, replies) = mpsc::channel();
    let bulk = Worker::spawn(bulk_client, reply_tx.clone());
    let slow = Worker::spawn(slow_client, reply_tx.clone());
    // Polling apart from everything else, so the voices keep moving.
    let fast = Worker::spawn(fast_client, reply_tx);

    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, keys, only_credits, &slow, &bulk, &fast, &replies);
    ratatui::restore();
    result.map_err(|e| e.to_string())
}

fn event_loop(
    terminal: &mut ratatui::DefaultTerminal,
    keys: Choice,
    only_credits: bool,
    slow: &Worker,
    bulk: &Worker,
    fast: &Worker,
    replies: &mpsc::Receiver<(Tag, Result<Value, String>)>,
) -> std::io::Result<()> {
    let mut app = App::new();
    app.use_keys(keys);
    app.prints_wanted = true;
    app.ask_about_hvsc();
    if only_credits {
        app.leave_after_credits = true;
        app.open_credits();
    } else if header::plan(terminal.size()?.width, terminal.size()?.height).rows > 1 {
        app.mode = Mode::Splash(Instant::now());
    }
    let mut last_status = Instant::now() - STATUS_EVERY;
    let mut last_scope = Instant::now() - SCOPE_EVERY;
    let mut last_position = Instant::now() - POSITION_EVERY;
    let (mut status_pending, mut scope_pending, mut position_pending) = (false, false, false);
    while !app.quit {
        let size = terminal.size()?;
        app.rail_showing = size.width >= RAIL_FROM && matches!(app.mode, Mode::Normal | Mode::Search | Mode::Describing(_));
        app.prepare_visual(Instant::now(), size.width, size.height);
        terminal.draw(|frame| draw(frame, &app))?;
        if event::poll(Duration::from_millis(16))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    app.key(key);
                }
            }
        }
        let now = Instant::now();
        app.tick(now);
        while let Ok((tag, answer)) = replies.try_recv() {
            match tag {
                Tag::Status => status_pending = false,
                Tag::Scope => scope_pending = false,
                Tag::TrackerPosition => position_pending = false,
                _ => {}
            }
            app.reply(tag, answer);
        }
        for request in app.outbox.drain(..) {
            let lane = if request.is_bulk() { bulk } else { slow };
            let _ = lane.tx.send(request);
        }
        if !status_pending && now.duration_since(last_status) >= STATUS_EVERY {
            last_status = now;
            status_pending = true;
            let _ = fast.tx.send(Request { tag: Tag::Status, cmd: "status", args: json!({}) });
        }
        if app.wants_position() && !position_pending && now.duration_since(last_position) >= POSITION_EVERY {
            last_position = now;
            position_pending = true;
            let _ = fast.tx.send(Request { tag: Tag::TrackerPosition, cmd: "tracker.position", args: app.position_args() });
        }
        let playing = app.status.as_ref().is_some_and(|s| s.state == "playing");
        if playing && !scope_pending && now.duration_since(last_scope) >= SCOPE_EVERY {
            last_scope = now;
            scope_pending = true;
            let args = json!({ "count": SCOPE_SAMPLES });
            let _ = fast.tx.send(Request { tag: Tag::Scope, cmd: "scope", args });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::style::Color;
    use ratatui::Terminal;

    fn tune(name: &str) -> Tune {
        Tune {
            path: format!("/{name}.sid"),
            title: name.into(),
            author: "Rob Hubbard".into(),
            released: "1985".into(),
            songs: 1,
            secs: Some(252),
            score: None,
            played_at: None,
        }
    }

    fn press(app: &mut App, code: KeyCode) {
        app.key(KeyEvent::new(code, KeyModifiers::NONE));
    }

    fn app() -> App {
        let mut app = App::new();
        app.outbox.clear();
        app.lists = vec![
            PlaylistInfo { name: "Favourites".into(), count: 2, is_favourites: true },
            PlaylistInfo { name: "Late Night".into(), count: 3, is_favourites: false },
        ];
        app.view = View::Playlist("Late Night".into());
        app.sidebar = 4;
        app.rows = vec![tune("A"), tune("B"), tune("C")];
        app
    }

    fn sent(app: &mut App) -> Vec<(&'static str, Value)> {
        app.outbox.drain(..).map(|r| (r.cmd, r.args)).collect()
    }

    fn screen(app: &App) -> String {
        let mut terminal = Terminal::new(TestBackend::new(110, 30)).unwrap();
        terminal.draw(|frame| draw(frame, app)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        buffer.content.iter().map(|c| c.symbol()).collect::<Vec<_>>().chunks(110).map(|l| l.concat()).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn starts_by_asking_for_the_lists_and_favourites() {
        let mut app = App::new();
        let asked: Vec<&str> = sent(&mut app).iter().map(|s| s.0).collect();
        assert_eq!(asked, ["playlist.list", "playlist.show"]);
    }

    #[test]
    fn enter_plays_the_playlist_from_there() {
        let mut app = app();
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Enter);
        assert_eq!(sent(&mut app), [("playlist.play", json!({ "name": "Late Night", "start": "/B.sid" }))]);
    }

    #[test]
    fn a_search_plays_with_its_query_named() {
        let mut app = app();
        app.view = View::Search;
        app.query = "com".into();
        press(&mut app, KeyCode::Enter);
        let (cmd, args) = sent(&mut app).remove(0);
        assert_eq!(cmd, "play");
        assert_eq!(args["text"], "com");
        assert_eq!(args["paths"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn typing_a_search_waits_a_moment_then_asks_once() {
        let mut app = app();
        press(&mut app, KeyCode::Char('/'));
        app.outbox.clear();
        press(&mut app, KeyCode::Char('c'));
        press(&mut app, KeyCode::Char('o'));
        assert!(app.outbox.is_empty());
        app.tick(Instant::now() + DEBOUNCE * 2);
        assert_eq!(sent(&mut app), [("search", json!({ "text": "co", "limit": 200 }))]);
    }

    #[test]
    fn letters_in_a_search_arent_commands() {
        let mut app = app();
        press(&mut app, KeyCode::Char('/'));
        press(&mut app, KeyCode::Char('q'));
        assert!(!app.quit);
        assert_eq!(app.query, "q");
    }

    #[test]
    fn an_old_search_answer_is_ignored() {
        let mut app = app();
        app.view = View::Search;
        app.query = "a".into();
        app.reload();
        let old = match app.outbox.last().unwrap().tag {
            Tag::Rows(n) => n,
            _ => panic!(),
        };
        app.reload();
        app.reply(Tag::Rows(old), Ok(json!([])));
        assert_eq!(app.rows.len(), 3);
    }

    #[test]
    fn marks_decide_what_actions_are_about() {
        let mut app = app();
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Char(' '));
        assert_eq!(app.chosen(), ["/A.sid", "/C.sid"]);
        press(&mut app, KeyCode::Char('x'));
        assert_eq!(sent(&mut app)[0].1["paths"], json!(["/A.sid", "/C.sid"]));
        assert!(app.marked.is_empty());
    }

    #[test]
    fn removing_only_works_in_a_playlist() {
        let mut app = app();
        app.view = View::Recent;
        press(&mut app, KeyCode::Char('x'));
        assert!(app.outbox.is_empty());
        assert!(app.message.is_some());
    }

    #[test]
    fn moving_a_tune_goes_before_the_right_one() {
        let mut app = app();
        press(&mut app, KeyCode::Char('J'));
        assert_eq!(app.rows.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), ["B", "A", "C"]);
        assert_eq!(app.cursor, 1);
        assert_eq!(sent(&mut app)[0].1, json!({ "name": "Late Night", "paths": ["/A.sid"], "before": "/C.sid" }));
        press(&mut app, KeyCode::Char('J'));
        assert_eq!(sent(&mut app)[0].1["before"], Value::Null, "to the end");
        press(&mut app, KeyCode::Char('J'));
        assert!(app.outbox.is_empty(), "no further");
    }

    #[test]
    fn favourites_keeps_its_order() {
        let mut app = app();
        app.view = View::Playlist("Favourites".into());
        press(&mut app, KeyCode::Char('J'));
        assert!(app.outbox.is_empty());
        assert_eq!(app.rows[0].title, "A");
    }

    #[test]
    fn adding_asks_which_playlist() {
        let mut app = app();
        press(&mut app, KeyCode::Char('a'));
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Enter);
        assert_eq!(sent(&mut app), [("playlist.add", json!({ "name": "Late Night", "paths": ["/A.sid"] }))]);
    }

    #[test]
    fn a_new_playlist_takes_a_name_and_whats_marked() {
        let mut app = app();
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('n'));
        for c in "Mix".chars() {
            press(&mut app, KeyCode::Char(c));
        }
        press(&mut app, KeyCode::Enter);
        assert_eq!(sent(&mut app), [("playlist.new", json!({ "name": "Mix", "paths": ["/A.sid"] }))]);
    }

    #[test]
    fn sounds_like_asks_about_the_tune_under_the_cursor() {
        let mut app = app();
        press(&mut app, KeyCode::Char('l'));
        assert_eq!(app.view, View::Like("A".into()));
        assert_eq!(sent(&mut app), [("like", json!({ "path": "/A.sid", "limit": 30 }))]);
    }

    #[test]
    fn a_failed_poll_stays_quiet_but_a_failed_action_speaks() {
        let mut app = app();
        app.reply(Tag::Status, Err("no".into()));
        assert_eq!(app.message, None);
        app.reply(Tag::Ack { message: None, reload: false }, Err("Nothing is playing.".into()));
        assert_eq!(app.message.as_deref(), Some("Nothing is playing."));
    }

    #[test]
    fn browser_shows_folders_first_and_only_tunes() {
        let dir = std::env::temp_dir().join(format!("resonance-browser-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("Zed")).unwrap();
        for name in ["a.sid", "b.txt", ".hidden.sid"] {
            std::fs::write(dir.join(name), "").unwrap();
        }
        let browser = Browser::open(dir.clone());
        assert_eq!(browser.entries, [("Zed".to_string(), true), ("a.sid".to_string(), false)]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn browser_files_go_into_the_playlist_showing() {
        let mut app = app();
        app.use_files(vec![PathBuf::from("/x.sid")]);
        assert_eq!(sent(&mut app)[0].0, "playlist.add");
        app.view = View::Recent;
        app.use_files(vec![PathBuf::from("/x.sid")]);
        assert_eq!(sent(&mut app)[0].0, "play");
    }

    #[test]
    fn q_quits_and_control_c_always_does() {
        let mut app = app();
        press(&mut app, KeyCode::Char('q'));
        assert!(app.quit);
        let mut app = self::app();
        press(&mut app, KeyCode::Char('/'));
        app.key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(app.quit);
    }

    #[test]
    fn draws_the_sidebar_list_and_now_playing() {
        let mut app = app();
        app.status = Some(Status {
            state: "playing".into(),
            now: Some(crate::model::Now {
                path: "/B.sid".into(),
                title: "B".into(),
                author: "Rob Hubbard".into(),
                released: "1985".into(),
                song: 1,
                songs: 3,
            }),
            elapsed: 84.0,
            duration: Some(252.0),
            has_collection: true,
            favourite: true,
            source: None,
        });
        let shown = screen(&app);
        for expected in ["Favourites", "Late Night", "Recently Played", "Composer", "♪ B", "subtune 1 of 3", "1:24 / 4:12", "♥"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
    }

    #[test]
    fn draws_every_mode_even_in_a_tiny_terminal() {
        let mut app = app();
        for code in [KeyCode::Char('?'), KeyCode::Esc, KeyCode::Char('a'), KeyCode::Esc, KeyCode::Char('n'), KeyCode::Esc, KeyCode::Char('o'), KeyCode::Esc, KeyCode::Char('v')] {
            press(&mut app, code);
            app.prepare_visual(Instant::now(), 20, 6);
            let mut terminal = Terminal::new(TestBackend::new(20, 6)).unwrap();
            terminal.draw(|frame| draw(frame, &app)).unwrap();
            let _ = screen(&app);
        }
    }

    fn playing(state: &str) -> Status {
        serde_json::from_value(json!({
            "state": state,
            "elapsed": 10.0,
            "duration": 100.0,
            "favourite": false,
            "hasCollection": true,
            "now": { "path": "/A.sid", "title": "Commando", "author": "Rob Hubbard", "released": "1985", "song": 1, "songs": 1 },
        }))
        .unwrap()
    }

    #[test]
    fn v_opens_the_visuals_and_esc_closes_them_without_quitting() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        assert!(matches!(app.mode, Mode::Visual));
        press(&mut app, KeyCode::Esc);
        assert!(matches!(app.mode, Mode::Normal));
        assert!(!app.quit);
    }

    #[test]
    fn the_skull_keeps_the_musics_keys_and_ignores_the_lists() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        for code in [KeyCode::Char('p'), KeyCode::Char('.'), KeyCode::Char(','), KeyCode::Char('r')] {
            press(&mut app, code);
            assert!(matches!(app.mode, Mode::Visual));
        }
        let asked: Vec<&str> = sent(&mut app).iter().map(|s| s.0).collect();
        assert_eq!(asked, ["toggle", "next", "prev", "surprise"]);
        for code in [KeyCode::Down, KeyCode::Enter, KeyCode::Char('x'), KeyCode::Char('f')] {
            press(&mut app, code);
        }
        assert_eq!(app.cursor, 0);
        assert!(sent(&mut app).is_empty());
    }

    #[test]
    fn q_quits_from_the_skull_too() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        press(&mut app, KeyCode::Char('q'));
        assert!(app.quit);
    }

    #[test]
    fn the_arrows_change_the_skulls_spin() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        let before = app.skull.spin;
        press(&mut app, KeyCode::Right);
        assert!(app.skull.spin > before);
        press(&mut app, KeyCode::Left);
        press(&mut app, KeyCode::Left);
        assert!(app.skull.spin < before);
    }

    #[test]
    fn f_and_s_switch_between_fire_and_skull_and_v_goes_through_them_all() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        assert_eq!(app.page, Page::Skull);
        press(&mut app, KeyCode::Char('f'));
        assert_eq!(app.page, Page::Fire);
        press(&mut app, KeyCode::Char('t'));
        assert_eq!(app.page, Page::Tesla);
        press(&mut app, KeyCode::Char('w'));
        assert_eq!(app.page, Page::Water);
        press(&mut app, KeyCode::Char('o'));
        assert_eq!(app.page, Page::Sphere);
        press(&mut app, KeyCode::Char('s'));
        assert_eq!(app.page, Page::Skull);
        for expected in [Page::Fire, Page::Tesla, Page::Water, Page::Sphere, Page::Skull] {
            press(&mut app, KeyCode::Char('v'));
            assert_eq!(app.page, expected);
        }
        assert!(matches!(app.mode, Mode::Visual));
    }

    #[test]
    fn c_switches_the_fires_colours_and_only_on_the_fire() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        press(&mut app, KeyCode::Char('c'));
        assert!(!app.channels, "the skull has no such colours");
        press(&mut app, KeyCode::Char('f'));
        press(&mut app, KeyCode::Char('c'));
        assert!(app.channels);
        press(&mut app, KeyCode::Char('c'));
        assert!(!app.channels);
    }

    #[test]
    fn the_last_visual_is_the_one_that_comes_back() {
        let mut app = app();
        press(&mut app, KeyCode::Char('v'));
        press(&mut app, KeyCode::Char('f'));
        press(&mut app, KeyCode::Esc);
        press(&mut app, KeyCode::Char('v'));
        assert_eq!(app.page, Page::Fire);
    }

    #[test]
    fn every_visual_draws_at_any_size() {
        let mut app = app();
        app.status = Some(playing("playing"));
        press(&mut app, KeyCode::Char('v'));
        for _ in 0..8 {
            for (width, height) in [(132_u16, 40_u16), (80, 24), (20, 6), (10, 3)] {
                app.prepare_visual(Instant::now(), width, height);
                let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
                terminal.draw(|frame| draw(frame, &app)).unwrap();
            }
            press(&mut app, KeyCode::Char('v'));
        }
    }

    #[test]
    fn the_voices_reach_the_views_while_playing_but_not_while_paused() {
        let scope = || Ok(json!({ "voices": [[0.5, -0.5], [0.0], [0.0]] }));
        let mut app = app();
        app.status = Some(playing("paused"));
        app.reply(Tag::Scope, scope());
        assert_eq!(app.ears.heard, 0);
        app.status = Some(playing("playing"));
        app.reply(Tag::Scope, scope());
        assert_eq!(app.ears.heard, 1);
        assert!(app.ears.latest()[0].level > 0.0);
    }

    #[test]
    fn the_panel_asks_about_a_tune_only_once_the_cursor_rests() {
        let start = Instant::now();
        let mut app = app();
        app.rail_showing = true;
        app.tick(start);
        assert!(sent(&mut app).is_empty(), "asked before the cursor rested");
        app.tick(start + DETAILS_AFTER / 2);
        press(&mut app, KeyCode::Down);
        app.tick(start + DETAILS_AFTER);
        assert!(sent(&mut app).is_empty(), "moving should start the wait again");
        app.tick(start + DETAILS_AFTER * 2);
        let asked = sent(&mut app);
        assert_eq!(asked[0], ("sound", json!({ "path": "/B.sid" })));
        assert_eq!(asked[1], ("like", json!({ "path": "/B.sid", "limit": LIKE_SHOWN })));
        app.tick(start + DETAILS_AFTER * 3);
        assert!(sent(&mut app).is_empty(), "asked twice");
    }

    #[test]
    fn the_panel_asks_nothing_when_it_is_not_showing() {
        let start = Instant::now();
        let mut app = app();
        app.tick(start);
        app.tick(start + DETAILS_AFTER * 2);
        assert!(sent(&mut app).is_empty());
    }

    #[test]
    fn the_panel_shows_the_answers_and_a_tune_with_no_fingerprint_quietly() {
        let mut app = app();
        app.reply(Tag::Sound("/A.sid".into()), Ok(json!({ "summary": "Mostly pulse.", "tags": [] })));
        let mut like = tune("Lightforce");
        like.score = Some(0.81);
        app.reply(Tag::Alike("/A.sid".into()), Ok(json!([like])));
        let shown = screen(&app);
        for expected in ["Mostly pulse.", "Sounds like", "Lightforce", "81%"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
        app.reply(Tag::Sound("/B.sid".into()), Err("Resonance hasn't fingerprinted this tune yet.".into()));
        assert_eq!(app.message, None);
        assert_eq!(app.details["/B.sid"].summary.as_deref(), Some("No fingerprint yet."));
    }

    #[test]
    fn the_time_runs_on_between_the_apps_answers_and_stops_at_the_end() {
        let start = Instant::now();
        let mut app = app();
        app.tick(start);
        app.reply(Tag::Status, Ok(serde_json::to_value(playing("playing")).unwrap()));
        app.tick(start + Duration::from_secs(2));
        assert!((app.elapsed() - 12.0).abs() < 0.01);
        app.tick(start + Duration::from_secs(1000));
        assert_eq!(app.elapsed(), 100.0);
    }

    #[test]
    fn the_header_sits_on_top_with_the_player_below_it_in_every_size() {
        for (width, height) in [(180_u16, 70_u16), (110, 40), (110, 30), (80, 24), (60, 20)] {
            let mut app = app();
            app.status = Some(playing("playing"));
            let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| draw(frame, &app)).unwrap();
            let buffer = terminal.backend().buffer();
            let text: Vec<&str> = buffer.content.iter().map(|c| c.symbol()).collect();
            let shown = text.concat();
            assert!(shown.contains("Commando"), "no tune at {width}x{height}");
            assert!(shown.contains('█') || shown.contains("RESONANCE"), "no header at {width}x{height}");
            let last: String = text[(width as usize) * (height as usize - 1)..].concat();
            assert!(last.contains("play"), "no keys at {width}x{height}: {last}");
            press(&mut app, KeyCode::Tab);
            terminal.draw(|frame| draw(frame, &app)).unwrap();
        }
    }

    #[test]
    fn the_columns_scale_with_the_window_within_their_limits() {
        assert_eq!(column_width(100, SIDEBAR_SHARE), 28);
        assert_eq!(column_width(250, SIDEBAR_SHARE), 40);
        assert_eq!(column_width(600, SIDEBAR_SHARE), 48);
        assert_eq!(column_width(120, RAIL_SHARE), 40);
        assert_eq!(column_width(250, RAIL_SHARE), 60);
        assert_eq!(column_width(600, RAIL_SHARE), 72);
    }

    #[test]
    fn every_window_from_tiny_to_huge_draws_the_player() {
        for (width, height) in [(5_u16, 3_u16), (40, 10), (69, 20), (70, 20), (109, 30), (110, 30), (195, 51), (240, 95), (400, 130)] {
            let mut app = app();
            app.status = Some(playing("playing"));
            let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| draw(frame, &app)).unwrap();
        }
    }

    #[test]
    fn a_window_of_forty_rows_gives_the_room_to_the_tunes() {
        let mut app = app();
        app.status = Some(playing("playing"));
        app.lists[1].name = "HVSC Top 100 in 2000".into();
        app.lists[1].count = 98;
        app.rows = (0..10).map(|n| tune(&format!("Tune {n}"))).collect();
        let mut terminal = Terminal::new(TestBackend::new(195, 40)).unwrap();
        terminal.draw(|frame| draw(frame, &app)).unwrap();
        let shown: String = terminal.backend().buffer().content.iter().map(|c| c.symbol()).collect();
        assert!(!shown.contains("T H E   S O U N D"), "the logo belongs to the splash");
        assert!(shown.contains("Tune 9"), "the list should have the room now");
        assert!(shown.contains("▓▒░ This tune"), "no third column");
        assert!(shown.contains("in 2000  98"), "a playlist's count was cut off");
    }

    /// `cargo test -p resonance-cli show_hvsc -- --ignored --nocapture`, to look at it.
    #[test]
    #[ignore = "prints screens to look at"]
    fn show_hvsc() {
        let mut home = home_app();
        home.status = Some(playing("playing"));
        home.rows = vec![tune("Commando"), tune("Monty on the Run")];
        home.cursor = 1;
        for (w, h) in [(160, 48), (100, 30)] {
            println!("--- home {w}x{h}\n{}", screen_of(&home, w, h));
        }
        let mut composers = composers_app();
        composers.status = Some(playing("playing"));
        composers.prints.insert(composers.rows[0].path.clone(), Some(vec![0.5; 9]));
        println!("--- composers\n{}", screen_of(&composers, 160, 40));
    }

    /// `cargo test -p resonance-cli show_screen -- --ignored --nocapture`, to look at it.
    #[test]
    #[ignore = "prints a screen to look at"]
    fn show_screen() {
        let mut app = app();
        app.status = Some(playing("playing"));
        for n in 0..300 {
            let tone = |hertz: f32, level: f32| -> Vec<f32> {
                (0..2048).map(|i| if (i as f32 * hertz / 44_800.0).fract() < 0.5 { level } else { -level }).collect()
            };
            let arp = [262.0, 330.0, 392.0, 523.0][n / 2 % 4];
            let voices = [tone(arp, 0.9 - (n % 8) as f32 * 0.08), tone(65.0 + (n / 16 % 4) as f32 * 15.0, 0.8), tone(784.0, 0.4)];
            app.ears.hear(&voices);
        }
        let mut like = tune("Lightforce");
        like.score = Some(0.81);
        app.reply(Tag::Sound("/A.sid".into()), Ok(json!({ "summary": "Mostly pulse, with arpeggios, filter sweeps and noise drums.", "tags": [] })));
        app.reply(Tag::Alike("/A.sid".into()), Ok(json!([like])));
        for (width, height) in [(170_u16, 70_u16)] {
            let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| draw(frame, &app)).unwrap();
            let buffer = terminal.backend().buffer();
            for row in buffer.content.chunks(width as usize) {
                println!("{}", row.iter().map(|c| c.symbol()).collect::<String>().trim_end());
            }
        }
    }

    #[test]
    fn the_voices_reach_the_skull_while_playing_but_not_while_paused() {
        let scope = || Ok(json!({ "voices": [[0.5, -0.5], [0.0], [0.0]] }));
        let mut app = app();
        app.status = Some(playing("paused"));
        app.reply(Tag::Scope, scope());
        assert_eq!(app.skull.reaction.eyes, 0.0);
        app.status = Some(playing("playing"));
        app.reply(Tag::Scope, scope());
        assert!(app.skull.reaction.eyes > 0.1);
    }

    #[test]
    fn the_skull_fills_the_screen_with_the_tune_and_keys_around_it() {
        let mut app = app();
        app.status = Some(playing("playing"));
        press(&mut app, KeyCode::Char('v'));
        app.prepare_visual(Instant::now(), 110, 30);
        let body = visual_layout(Rect::new(0, 0, 110, 30)).body;
        assert_eq!((app.skull.picture.width, app.skull.picture.height), (body.width, body.height));
        let text = screen(&app);
        let lines: Vec<&str> = text.lines().collect();
        assert!(text.contains("Commando") && text.contains("Rob Hubbard"), "{text}");
        assert!(lines[28].contains("esc back"), "{text}");
        let middle = usize::from(body.y + body.height / 2);
        assert!(lines[middle].trim().len() > 10, "nothing drawn in the middle: {:?}", lines[middle]);
    }

    #[test]
    fn no_picture_is_drawn_for_a_view_that_is_not_showing() {
        let mut app = app();
        app.prepare_visual(Instant::now(), 110, 30);
        assert_eq!(app.skull.picture.width, 0);
    }

    fn app_with(scheme: KeyScheme) -> App {
        let mut app = app();
        app.use_keys(Choice { scheme, reason: "for a test" });
        app.rows = (0..40).map(|n| { let mut t = tune("x"); t.path = format!("/{n}.sid"); t }).collect();
        app
    }

    #[test]
    fn vim_moves_through_the_list_and_keeps_its_commands_on_other_keys() {
        let mut app = app_with(KeyScheme::Vim);
        press(&mut app, KeyCode::Char('G'));
        assert_eq!(app.cursor, 39);
        press(&mut app, KeyCode::Char('g'));
        assert_eq!(app.cursor, 39);
        press(&mut app, KeyCode::Char('g'));
        assert_eq!(app.cursor, 0);
        press(&mut app, KeyCode::Char('h'));
        assert!(app.focus == Focus::Sidebar);
        press(&mut app, KeyCode::Char('l'));
        assert!(app.focus == Focus::List);
        press(&mut app, KeyCode::Char('L'));
        assert!(matches!(app.view, View::Like(_)));
    }

    #[test]
    fn vim_dd_takes_a_tune_out_of_a_playlist() {
        let mut app = app_with(KeyScheme::Vim);
        press(&mut app, KeyCode::Char('d'));
        assert!(app.outbox.iter().all(|r| r.cmd != "playlist.rm" && r.cmd != "drift"));
        press(&mut app, KeyCode::Char('d'));
        assert!(app.outbox.iter().any(|r| r.cmd == "playlist.rm"));
    }

    #[test]
    fn emacs_moves_with_control_and_keeps_the_plain_letters() {
        let mut app = app_with(KeyScheme::Emacs);
        app.key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::CONTROL));
        assert_eq!(app.cursor, 1);
        app.key(KeyEvent::new(KeyCode::Char('v'), KeyModifiers::CONTROL));
        assert_eq!(app.cursor, 16);
        press(&mut app, KeyCode::Char('j'));
        assert_eq!(app.cursor, 17);
        press(&mut app, KeyCode::Char('l'));
        assert!(matches!(app.view, View::Like(_)));
    }

    #[test]
    fn control_g_cancels_but_never_quits() {
        let mut app = app_with(KeyScheme::Emacs);
        let cancel = KeyEvent::new(KeyCode::Char('g'), KeyModifiers::CONTROL);
        app.key(cancel);
        assert!(!app.quit);
        app.key(KeyEvent::new(KeyCode::Char('s'), KeyModifiers::CONTROL));
        assert!(matches!(app.mode, Mode::Search));
        app.key(cancel);
        assert!(matches!(app.mode, Mode::Normal));
        assert!(!app.quit);
    }

    /// Press the key the bar shows, and see that it does what the bar says.
    #[test]
    fn the_bar_shows_keys_that_do_what_it_says() {
        for scheme in [KeyScheme::Normal, KeyScheme::Vim, KeyScheme::Emacs] {
            let bar = bar_keys(&app_with(scheme));
            let shown = |what: &str| bar.iter().find(|(_, w)| *w == what).unwrap().0;

            let mut app = app_with(scheme);
            press(&mut app, KeyCode::Char(shown("sounds like").chars().next().unwrap()));
            assert!(matches!(app.view, View::Like(_)), "{scheme:?}");

            let mut app = app_with(scheme);
            press(&mut app, KeyCode::Char(shown("drift").chars().next().unwrap()));
            assert!(app.outbox.iter().any(|r| r.cmd == "drift"), "{scheme:?}");
        }
    }

    #[test]
    fn the_bar_names_each_sets_movement_and_removal() {
        for (scheme, movement, remove) in [
            (KeyScheme::Normal, "↑ ↓", "x"),
            (KeyScheme::Vim, "j k", "dd"),
            (KeyScheme::Emacs, "⌃N ⌃P", "⌃D"),
        ] {
            let mut app = app_with(scheme);
            assert!(bar_keys(&app).contains(&(movement, "move")), "{scheme:?}");
            press(&mut app, KeyCode::Char(' '));
            assert!(bar_keys(&app).contains(&(remove, "remove")), "{scheme:?}");
        }
    }

    #[test]
    fn a_narrow_bar_keeps_help_and_only_whole_hints() {
        let line = |keys: &[(&str, &str)]| keys.iter().map(|(k, w)| format!("{k} {w}  ")).collect::<String>();
        for scheme in [KeyScheme::Normal, KeyScheme::Vim, KeyScheme::Emacs] {
            let all = bar_keys(&app_with(scheme));
            for width in [12u16, 40, 77, 100] {
                let fitted = fit_bar(all.clone(), width, "?");
                assert!(fitted.contains(&("?", "all keys")), "{scheme:?} at {width}");
                assert!(line(&fitted).chars().count() <= width as usize, "{scheme:?} at {width}: {}", line(&fitted));
            }
            // The most useful stay, in their order.
            let at_77 = fit_bar(all.clone(), 77, "?");
            assert_eq!(at_77[0], all[0], "{scheme:?}");
            assert!(at_77.contains(&("↵", "play")), "{scheme:?}");
            // With room, nothing goes.
            assert_eq!(fit_bar(all.clone(), 200, "?"), all, "{scheme:?}");
        }
    }

    #[test]
    fn a_narrow_visuals_bar_keeps_the_way_back_and_what_this_page_does() {
        let line = |keys: &[(&str, &str)]| keys.iter().map(|(k, w)| format!("{k} {w}  ")).collect::<String>();
        let mut app = app_with(KeyScheme::Emacs);
        press(&mut app, KeyCode::Char('v'));
        let fitted = fit_bar(visual_keys(&app), 77, "esc");
        assert_eq!(fitted[..2], [("esc", "back"), ("⌃B ⌃F", "spin")]);
        assert!(line(&fitted).chars().count() <= 77, "{}", line(&fitted));
        assert_eq!(fit_bar(visual_keys(&app), 10, "esc"), [("esc", "back")]);

        press(&mut app, KeyCode::Char('f'));
        assert_eq!(fit_bar(visual_keys(&app), 77, "esc")[1], ("c", "channel colours"));
        press(&mut app, KeyCode::Char('c'));
        assert_eq!(fit_bar(visual_keys(&app), 77, "esc")[1], ("c", "flame colours"));
        // A page with nothing of its own.
        press(&mut app, KeyCode::Char('t'));
        assert_eq!(fit_bar(visual_keys(&app), 77, "esc")[1], ("v", "next view"));
    }

    #[test]
    fn a_bar_with_no_help_hint_still_fits() {
        let mut app = app_with(KeyScheme::Normal);
        press(&mut app, KeyCode::Char('/'));
        let fitted = fit_bar(bar_keys(&app), 20, "?");
        assert_eq!(fitted, [("type", "to search")]);
    }

    #[test]
    fn a_chord_no_set_uses_does_not_run_the_plain_letter() {
        for scheme in [KeyScheme::Normal, KeyScheme::Vim, KeyScheme::Emacs] {
            for modifiers in [KeyModifiers::CONTROL, KeyModifiers::ALT] {
                // Each is a plain key that does something, in a playlist.
                for c in ['x', 'r', 'o', 'q'] {
                    let mut app = app_with(scheme);
                    app.outbox.clear();
                    app.key(KeyEvent::new(KeyCode::Char(c), modifiers));
                    assert!(app.outbox.is_empty(), "{scheme:?} {modifiers:?} {c}");
                    assert!(matches!(app.mode, Mode::Normal), "{scheme:?} {modifiers:?} {c}");
                    assert!(!app.quit, "{scheme:?} {modifiers:?} {c}");
                }
            }
        }
    }

    #[test]
    fn a_chord_on_the_visuals_stays_on_the_page() {
        let mut app = app_with(KeyScheme::Emacs);
        press(&mut app, KeyCode::Char('v'));
        let page = app.page;
        app.key(KeyEvent::new(KeyCode::Char('t'), KeyModifiers::CONTROL));
        assert_eq!(app.page, page);
        assert!(matches!(app.mode, Mode::Visual));
    }

    #[test]
    fn the_visuals_answer_to_the_keys_their_hint_shows() {
        let turn = [
            (KeyScheme::Normal, KeyEvent::new(KeyCode::Right, KeyModifiers::NONE), "← →"),
            (KeyScheme::Vim, KeyEvent::new(KeyCode::Char('l'), KeyModifiers::NONE), "h l"),
            (KeyScheme::Emacs, KeyEvent::new(KeyCode::Char('f'), KeyModifiers::CONTROL), "⌃B ⌃F"),
        ];
        for (scheme, right, shown) in turn {
            let mut app = app_with(scheme);
            press(&mut app, KeyCode::Char('v'));
            assert_eq!(app.page, Page::Skull);
            assert!(visual_keys(&app).contains(&(shown, "spin")), "{scheme:?}");
            let before = app.skull.spin;
            app.key(right);
            assert!(app.skull.spin > before, "{scheme:?}");
            assert_eq!(app.page, Page::Skull, "{scheme:?}");

            // The hint's plain letters are the same in every set.
            for (c, page) in [('f', Page::Fire), ('t', Page::Tesla), ('w', Page::Water), ('o', Page::Sphere), ('s', Page::Skull)] {
                press(&mut app, KeyCode::Char(c));
                assert_eq!(app.page, page, "{scheme:?} {c}");
            }
            press(&mut app, KeyCode::Esc);
            assert!(matches!(app.mode, Mode::Normal), "{scheme:?}");
            assert!(!app.quit, "{scheme:?}");
        }
    }

    #[test]
    fn vim_two_press_starts_do_nothing_on_the_visuals() {
        let mut app = app_with(KeyScheme::Vim);
        press(&mut app, KeyCode::Char('v'));
        press(&mut app, KeyCode::Char('d'));
        press(&mut app, KeyCode::Char('f'));
        assert_eq!(app.page, Page::Fire);
        assert!(matches!(app.mode, Mode::Visual));
    }

    fn with_prints(mut app: App) -> App {
        app.prints_wanted = true;
        app
    }

    const NINE: [f32; 9] = [0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.25, 0.75];

    fn print_answer(path: &str) -> Value {
        json!([{ "path": path, "traits": NINE, "mix": { "triangle": 0.1, "saw": 0.0, "pulse": 0.6, "noise": 0.3 },
                 "activity": [[10, 200], [200, 10], [0, 255]] }])
    }

    fn screen_of(app: &App, width: u16, height: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, app)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        buffer.content.iter().map(|c| c.symbol()).collect::<Vec<_>>().chunks(width as usize).map(|l| l.concat()).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn prints_are_asked_for_once_near_the_cursor() {
        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.outbox.clear();
        let now = Instant::now();
        app.tick(now);
        let asked: Vec<Request> = app.outbox.drain(..).filter(|r| r.cmd == "prints").collect();
        assert_eq!(asked.len(), 1);
        let paths = asked[0].args["paths"].as_array().unwrap();
        assert!(!paths.is_empty() && paths.len() <= PRINTS_AROUND * 2);
        app.tick(now + PRINTS_EVERY * 2);
        assert!(app.outbox.iter().all(|r| r.cmd != "prints"), "known ones aren't asked for again");
    }

    #[test]
    fn nothing_is_asked_for_a_full_screen_or_without_barcodes() {
        let mut app = app_with(KeyScheme::Normal);
        app.outbox.clear();
        app.tick(Instant::now());
        assert!(app.outbox.iter().all(|r| r.cmd != "prints"));

        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.outbox.clear();
        press(&mut app, KeyCode::Char('v'));
        app.tick(Instant::now());
        assert!(app.outbox.iter().all(|r| r.cmd != "prints"));
    }

    #[test]
    fn a_tune_with_a_print_shows_its_barcode_and_one_without_a_placeholder() {
        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.rows.truncate(2);
        app.rows[0].path = "/a.sid".into();
        app.rows[1].path = "/b.sid".into();
        app.reply(Tag::Prints(vec!["/a.sid".into(), "/b.sid".into()]), Ok(print_answer("/a.sid")));
        let shown = screen_of(&app, 160, 40);
        assert!(shown.contains("▄▁█▁▁▁▁▂▆"), "{shown}");
        assert!(shown.contains("·········"), "{shown}");
    }

    #[test]
    fn an_app_too_old_to_answer_goes_back_to_the_plain_list_quietly() {
        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.reply(Tag::Prints(vec![]), Err("Unknown command: prints".into()));
        assert_eq!(app.message, None);
        assert!(!screen_of(&app, 160, 40).contains("·········"));
        app.outbox.clear();
        app.tick(Instant::now());
        assert!(app.outbox.iter().all(|r| r.cmd != "prints"));
    }

    #[test]
    fn the_panel_shows_the_fingerprint_and_gives_way_when_short() {
        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.rows[0].path = "/a.sid".into();
        app.reply(Tag::Sound("/a.sid".into()), Ok(json!({ "summary": "Pulse and noise.", "tags": [] })));
        app.reply(Tag::Detail("/a.sid".into()), Ok(print_answer("/a.sid")));
        app.reply(Tag::Alike("/a.sid".into()), Ok(json!([])));
        let tune = app.rows[0].clone();
        let text = |lines: Vec<Line>| lines.iter().map(ToString::to_string).collect::<Vec<_>>().join("\n");

        let roomy = text(rail_lines(&app, &tune, 38, 40));
        for expected in ["Nt Ar Vb", "Pulse 60", "V1 ", "start", "Sounds like"] {
            assert!(roomy.contains(expected), "missing {expected}\n{roomy}");
        }
        let short = text(rail_lines(&app, &tune, 38, 20));
        assert!(short.contains("Nt Ar Vb") && !short.contains("V1 "), "{short}");
        let shortest = text(rail_lines(&app, &tune, 38, 10));
        assert!(shortest.contains("Pulse and noise.") && shortest.contains("Sounds like"), "{shortest}");
        assert!(!shortest.contains("Nt Ar Vb"), "{shortest}");
    }

    #[test]
    fn the_panel_never_wants_more_rows_than_it_has_when_it_can_help_it() {
        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.rows[0].path = "/a.sid".into();
        app.reply(Tag::Sound("/a.sid".into()), Ok(json!({ "summary": "Pulse.", "tags": [] })));
        app.reply(Tag::Detail("/a.sid".into()), Ok(print_answer("/a.sid")));
        let mut like = tune("Lightforce");
        like.score = Some(0.81);
        app.reply(Tag::Alike("/a.sid".into()), Ok(json!([like.clone(), like.clone(), like.clone(), like])));
        let tune = app.rows[0].clone();
        for height in 13..45 {
            assert!(rail_lines(&app, &tune, 38, height).len() <= height, "at {height}");
        }
    }

    #[test]
    fn sounds_like_shows_the_tune_it_compares_with_over_the_barcodes() {
        let mut app = with_prints(app_with(KeyScheme::Normal));
        app.rows[0].path = "/a.sid".into();
        app.reply(Tag::Prints(vec!["/a.sid".into()]), Ok(print_answer("/a.sid")));
        press(&mut app, KeyCode::Char('l'));
        assert_eq!(app.like_seed.as_deref(), Some("/a.sid"));
        let mut like = tune("Lightforce");
        like.score = Some(0.81);
        app.rows = vec![like];
        let shown = screen_of(&app, 160, 40);
        let header = shown.lines().find(|l| l.contains("Title")).unwrap();
        assert!(header.contains("▄▁█▁▁▁▁▂▆"), "{header}");
    }

    #[test]
    fn the_panel_names_the_key_for_more_in_each_set() {
        for (scheme, words) in [(KeyScheme::Normal, "l for more"), (KeyScheme::Vim, "L for more"), (KeyScheme::Emacs, "l for more")] {
            let app = app_with(scheme);
            let tune = app.rows[0].clone();
            let all = rail_lines(&app, &tune, 38, 30).iter().map(ToString::to_string).collect::<Vec<_>>().join("\n");
            assert!(all.contains(words), "{scheme:?}\n{all}");
        }
    }

    #[test]
    fn help_fits_a_small_window_and_adds_the_legend_when_it_can() {
        let mut app = app_with(KeyScheme::Emacs);
        press(&mut app, KeyCode::Char('?'));
        let small = screen_of(&app, 80, 24);
        assert!(small.contains("Quit; the music carries on") && !small.contains("Reading a fingerprint"), "{small}");
        let tall = screen_of(&app, 80, 42);
        assert!(tall.contains("Reading a fingerprint") && tall.contains("Ring modulation"), "{tall}");
        let wide = screen_of(&app, 120, 30);
        assert!(wide.contains("Reading a fingerprint") && wide.contains("Quit; the music carries on"), "{wide}");
    }

    #[test]
    fn every_cell_has_the_windows_colours_or_its_own() {
        let mut app = app_with(KeyScheme::Normal);
        for mode in ['?', 'q'] {
            let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
            terminal.draw(|frame| draw(frame, &app)).unwrap();
            let buffer = terminal.backend().buffer();
            assert!(buffer.content.iter().all(|c| c.bg != Color::Reset && c.fg != Color::Reset), "before {mode}");
            press(&mut app, KeyCode::Char(mode));
        }
    }

    #[test]
    fn the_visuals_keep_room_around_the_music_at_any_size() {
        for (width, height) in [(200, 60), (160, 48), (120, 38), (110, 30), (80, 24), (40, 12)] {
            let area = Rect::new(0, 0, width, height);
            let layout = visual_layout(area);
            assert!(layout.body.x > 0, "{width}x{height}");
            assert!(layout.body.right() < width, "{width}x{height}");
            assert!(layout.body.y >= layout.top.bottom(), "{width}x{height}");
            assert!(layout.body.bottom() <= layout.info.y, "{width}x{height}");
            assert!(layout.keys.bottom() <= height, "{width}x{height}");
        }
        let layout = visual_layout(Rect::new(0, 0, 160, 48));
        assert!(layout.body.width <= 160 * 8 / 10, "{:?}", layout.body);
    }

    fn visuals_with_a_tune() -> App {
        let mut app = app();
        let mut status = playing("playing");
        status.source = Some("Favourites".into());
        app.status = Some(status);
        press(&mut app, KeyCode::Char('v'));
        app
    }

    #[test]
    fn the_visuals_are_set_out_like_the_apps_now_playing() {
        let app = visuals_with_a_tune();
        let shown = screen_of(&app, 160, 48);
        let row = |text: &str| shown.lines().position(|line| line.contains(text)).unwrap_or_else(|| panic!("no {text}\n{shown}"));
        assert!(row("s Skull") < row("PLAYING FROM FAVOURITES"));
        assert!(row("PLAYING FROM FAVOURITES") < row("◀◀"));
        assert!(row("◀◀") < row("esc back"));
        assert_eq!(row("✕"), row("s Skull"));
        assert!(shown.contains("r Surprise Me"));
        assert!(shown.contains("V1 ") && shown.contains("V3 "));
    }

    #[test]
    fn the_extras_go_when_the_keys_are_left_alone_and_a_key_brings_them_back() {
        let mut app = visuals_with_a_tune();
        let start = Instant::now();
        app.tick(start);
        press(&mut app, KeyCode::Char('f'));
        assert!(screen_of(&app, 160, 48).contains("f Fire"));

        app.tick(start + EXTRAS_FOR + Duration::from_secs(1));
        let idle = screen_of(&app, 160, 48);
        assert!(!idle.contains("f Fire") && !idle.contains("esc back"), "{idle}");
        assert!(idle.contains("✕") && idle.contains("◀◀"), "{idle}");

        press(&mut app, KeyCode::Char('t'));
        assert!(screen_of(&app, 160, 48).contains("t Tesla"));
    }

    #[test]
    fn the_picker_shows_only_the_page_when_narrow() {
        let app = visuals_with_a_tune();
        let wide: String = picker_spans(&app, 160).iter().map(|s| s.content.to_string()).collect();
        assert!(wide.contains("o Sphere") && wide.contains("s Skull"));
        let narrow: String = picker_spans(&app, 30).iter().map(|s| s.content.to_string()).collect();
        assert_eq!(narrow.trim(), "Skull");
    }

    #[test]
    fn released_reads_as_in_the_app() {
        assert_eq!(released_line("1988 Epyx"), "1988 · Epyx");
        assert_eq!(released_line("198? Unknown Crew"), "198? · Unknown Crew");
        assert_eq!(released_line("Epyx Games"), "Epyx Games");
        assert_eq!(released_line(""), "");
    }

    #[test]
    fn an_app_that_does_not_say_where_it_plays_from_still_reads_right() {
        let mut app = visuals_with_a_tune();
        app.status.as_mut().unwrap().source = None;
        assert!(screen_of(&app, 160, 48).contains("NOW PLAYING"));
    }

    #[test]
    fn c_opens_the_credits_and_esc_goes_back_to_the_list() {
        for scheme in [KeyScheme::Normal, KeyScheme::Vim, KeyScheme::Emacs] {
            let mut app = app_with(scheme);
            press(&mut app, KeyCode::Char('c'));
            assert!(matches!(app.mode, Mode::Credits(_)), "{scheme:?}");
            press(&mut app, KeyCode::Esc);
            assert!(matches!(app.mode, Mode::Normal), "{scheme:?}");
            assert!(!app.quit, "{scheme:?}");
        }
    }

    #[test]
    fn the_credits_keep_the_musics_keys_and_ignore_the_lists() {
        let mut app = app_with(KeyScheme::Normal);
        press(&mut app, KeyCode::Char('c'));
        app.outbox.clear();
        for code in [KeyCode::Char('p'), KeyCode::Char('.'), KeyCode::Char(',')] {
            press(&mut app, code);
            assert!(matches!(app.mode, Mode::Credits(_)));
        }
        let asked: Vec<&str> = app.outbox.iter().map(|r| r.cmd).collect();
        assert_eq!(asked, ["toggle", "next", "prev"]);
        for code in [KeyCode::Down, KeyCode::Enter, KeyCode::Char('x')] {
            press(&mut app, code);
        }
        assert_eq!(app.cursor, 0);
        assert_eq!(app.outbox.len(), 3);
        press(&mut app, KeyCode::Char('q'));
        assert!(app.quit);
    }

    #[test]
    fn the_credits_close_themselves_at_the_end() {
        let mut app = app_with(KeyScheme::Normal);
        let start = Instant::now();
        app.tick(start);
        press(&mut app, KeyCode::Char('c'));
        app.tick(start + Duration::from_secs(5));
        assert!(matches!(app.mode, Mode::Credits(_)));
        app.tick(start + Duration::from_secs_f64(credits::length(None) + 1.0));
        assert!(matches!(app.mode, Mode::Normal));
        assert!(!app.quit);
    }

    #[test]
    fn resonance_credits_leaves_when_they_are_done_or_closed() {
        let start = Instant::now();
        let mut app = app_with(KeyScheme::Normal);
        app.leave_after_credits = true;
        app.tick(start);
        app.open_credits();
        app.tick(start + Duration::from_secs_f64(credits::length(None) + 1.0));
        assert!(app.quit);

        let mut app = app_with(KeyScheme::Normal);
        app.leave_after_credits = true;
        app.open_credits();
        press(&mut app, KeyCode::Esc);
        assert!(app.quit);
    }

    #[test]
    fn the_credits_draw_and_the_help_mentions_them() {
        let mut app = app_with(KeyScheme::Normal);
        press(&mut app, KeyCode::Char('?'));
        assert!(screen_of(&app, 120, 30).contains("This help, or the credits"));
        press(&mut app, KeyCode::Char('q'));
        press(&mut app, KeyCode::Char('c'));
        let shown = screen_of(&app, 120, 38);
        assert!(shown.contains("esc back"), "{shown}");
        assert!(shown.chars().all(|c| !c.is_control() || c == '\n'));
    }

    fn stopped() -> Status {
        let mut status = playing("stopped");
        status.now = None;
        status
    }

    #[test]
    fn the_credits_start_favourites_when_nothing_is_playing() {
        let mut app = app_with(KeyScheme::Normal);
        app.status = Some(stopped());
        app.outbox.clear();
        press(&mut app, KeyCode::Char('c'));
        let asked = sent(&mut app);
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].0, "playlist.play");
        assert_eq!(asked[0].1["name"], "Favourites");
    }

    #[test]
    fn the_credits_fall_back_to_surprise_me_quietly() {
        let mut app = app_with(KeyScheme::Normal);
        app.status = Some(stopped());
        press(&mut app, KeyCode::Char('c'));
        app.outbox.clear();
        app.reply(Tag::CreditsMusic, Err("Favourites has no tunes in it.".into()));
        assert_eq!(app.message, None);
        assert_eq!(sent(&mut app).iter().map(|s| s.0).collect::<Vec<_>>(), ["surprise"]);
    }

    #[test]
    fn the_credits_leave_what_is_playing_or_paused_alone() {
        for state in ["playing", "paused"] {
            let mut app = app_with(KeyScheme::Normal);
            app.status = Some(playing(state));
            app.outbox.clear();
            press(&mut app, KeyCode::Char('c'));
            assert!(app.outbox.iter().all(|r| r.cmd != "playlist.play" && r.cmd != "surprise"), "{state}");
        }
    }

    #[test]
    fn resonance_credits_waits_to_hear_what_is_playing_and_asks_once() {
        let mut app = app_with(KeyScheme::Normal);
        app.open_credits();
        app.outbox.clear();
        let quiet = serde_json::to_value(stopped()).unwrap();
        app.reply(Tag::Status, Ok(quiet.clone()));
        assert_eq!(sent(&mut app).iter().filter(|s| s.0 == "playlist.play").count(), 1);
        app.reply(Tag::Status, Ok(quiet));
        assert!(sent(&mut app).iter().all(|s| s.0 != "playlist.play"), "only once, or it would restart");
    }

    #[test]
    fn closing_the_credits_first_starts_nothing() {
        let mut app = app_with(KeyScheme::Normal);
        app.open_credits();
        press(&mut app, KeyCode::Esc);
        app.outbox.clear();
        app.reply(Tag::Status, Ok(serde_json::to_value(stopped()).unwrap()));
        assert!(sent(&mut app).iter().all(|s| s.0 != "playlist.play"));
    }

    fn overview() -> HvscOverview {
        serde_json::from_value(json!({
            "version": "85", "releaseDate": "June 28, 2026", "totalTunes": 61157, "musicianTunes": 56568,
            "gameTunes": 1531, "demoTunes": 3058, "composers": 1854, "songlengthEntries": 61157, "documents": 12,
            "update": { "number": 85, "newSids": 587, "fixedRips": 42, "creditFixes": 312, "moved": 20, "text": "Update #85\nLine two" },
            "disks": [{ "name": "HVSC Intro", "images": 4 }],
            "playlists": [{ "name": "HVSC Top 100 in 2000", "file": "top.m3u", "tracks": 98 }, { "name": "Long Tunes", "file": "long.m3u", "tracks": 12 }],
        })).unwrap()
    }

    fn home_app() -> App {
        let mut app = app();
        app.hvsc = Some(overview());
        app.sidebar = app.library_rows();
        app.open_sidebar();
        app.focus = Focus::List;
        app.outbox.clear();
        app
    }

    fn composers_app() -> App {
        let mut app = home_app();
        app.view = View::Hvsc("musicians");
        app.rows = vec![tune("Rob Hubbard"), tune("Martin Galway")];
        app.cursor = 0;
        app.outbox.clear();
        app
    }

    #[test]
    fn the_splash_holds_then_gives_way_and_any_key_skips_it() {
        let mut app = app();
        let start = Instant::now();
        app.mode = Mode::Splash(start);
        app.tick(start + SPLASH_FOR);
        assert!(matches!(app.mode, Mode::Splash(_)));
        app.tick(start + SPLASH_FOR + SPLASH_LEAVES);
        assert!(matches!(app.mode, Mode::Normal));

        let mut app = self::app();
        app.mode = Mode::Splash(start);
        press(&mut app, KeyCode::Char('q'));
        assert!(matches!(app.mode, Mode::Normal));
        assert!(!app.quit, "skipping it isn't quitting");
    }

    #[test]
    fn the_splash_shows_the_logo_and_the_list_has_the_room_after() {
        let mut app = app();
        let start = Instant::now();
        app.now = Some(start);
        app.mode = Mode::Splash(start);
        let splash = screen_of(&app, 160, 48);
        assert!(splash.contains("any key to start") && splash.contains('█'), "{splash}");
        assert!(splash.contains("T H E   S O U N D"), "{splash}");
        app.mode = Mode::Normal;
        let list = screen_of(&app, 160, 48);
        assert!(!list.contains("T H E   S O U N D"), "the logo has gone");
        assert!(list.lines().next().unwrap().contains("RESONANCE"), "{list}");
    }

    #[test]
    fn the_splash_never_leaves_a_small_window_broken() {
        for (w, h) in [(160, 48), (120, 38), (80, 26), (60, 25)] {
            for ms in [0, 2100, 2400, 2590] {
                let mut app = app();
                let start = Instant::now();
                app.mode = Mode::Splash(start);
                app.now = Some(start + Duration::from_millis(ms));
                let _ = screen_of(&app, w, h);
            }
        }
    }

    #[test]
    fn hvsc_rows_come_after_the_library_and_open_what_they_say() {
        let mut app = app();
        let first = app.library_rows();
        for (row, view) in [(0, View::HvscHome), (1, View::Hvsc("musicians")), (2, View::Hvsc("demos")), (3, View::Hvsc("games"))] {
            app.sidebar = first + row;
            app.open_sidebar();
            assert_eq!(app.view, view);
        }
        app.outbox.clear();
        app.sidebar = first + 1;
        app.open_sidebar();
        let asked = sent(&mut app);
        assert_eq!(asked[0].0, "hvsc.authors");
        assert_eq!(asked[0].1["name"], "musicians");
    }

    #[test]
    fn home_shows_the_release_and_opens_what_is_chosen() {
        let mut app = home_app();
        let shown = screen_of(&app, 160, 48);
        for expected in ["Release 85", "June 28, 2026", "61,157", "Musicians", "56,568", "+587", "HVSC Top 100 in 2000", "HVSC Intro"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
        assert_eq!(app.home_items().len(), 6);
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.view, View::Hvsc("musicians"));
    }

    #[test]
    fn home_opens_the_announcement_and_a_curated_playlist() {
        let mut app = home_app();
        app.cursor = 3;
        press(&mut app, KeyCode::Enter);
        assert!(matches!(app.mode, Mode::Reading(0)));
        let reading = screen_of(&app, 160, 48);
        assert!(reading.contains("Update #85") && !reading.contains("play the Top 100"), "{reading}");
        press(&mut app, KeyCode::Down);
        assert!(matches!(app.mode, Mode::Reading(1)));
        press(&mut app, KeyCode::Esc);
        assert!(matches!(app.mode, Mode::Normal));
        assert!(!app.quit);

        app.cursor = 4;
        app.outbox.clear();
        press(&mut app, KeyCode::Enter);
        assert!(matches!(&app.view, View::Curated { file, .. } if file == "top.m3u"));
        assert_eq!(sent(&mut app)[0].1["name"], "top.m3u");
        press(&mut app, KeyCode::Esc);
        assert_eq!(app.view, View::HvscHome);
        assert!(!app.quit);
    }

    #[test]
    fn home_shuffles_and_plays_the_top_100() {
        let mut app = home_app();
        press(&mut app, KeyCode::Char('S'));
        assert_eq!(sent(&mut app)[0].0, "hvsc.shuffle");
        press(&mut app, KeyCode::Char('T'));
        let asked = sent(&mut app);
        assert_eq!(asked[0].0, "hvsc.playlist.play");
        assert_eq!(asked[0].1["name"], "top.m3u");
    }

    #[test]
    fn home_says_when_there_is_no_collection() {
        let mut app = home_app();
        app.hvsc = None;
        assert!(screen_of(&app, 160, 48).contains("No collection yet"));
    }

    #[test]
    fn home_keeps_its_cursor_when_recent_tunes_arrive() {
        let mut app = home_app();
        app.cursor = 4;
        app.reply(Tag::Rows(app.generation), Ok(json!([tune("Commando")])));
        assert_eq!(app.cursor, 4);
    }

    #[test]
    fn a_composer_opens_and_esc_comes_back_to_the_same_row() {
        let mut app = composers_app();
        app.cursor = 1;
        press(&mut app, KeyCode::Enter);
        let asked = sent(&mut app);
        assert_eq!(asked[0].0, "hvsc.tunes");
        assert_eq!(asked[0].1["path"], "/Martin Galway.sid");
        assert!(matches!(&app.view, View::Composer { title, .. } if title == "Martin Galway"));
        press(&mut app, KeyCode::Esc);
        assert_eq!(app.view, View::Hvsc("musicians"));
        assert_eq!(app.cursor, 1);
        assert!(!app.quit);
    }

    #[test]
    fn a_narrow_home_keeps_what_can_be_chosen_on_screen() {
        let mut app = home_app();
        app.hvsc.as_mut().unwrap().playlists = (0..30).map(|n| HvscPlaylist { name: format!("List {n}"), file: format!("{n}.m3u"), tracks: 5 }).collect();
        for (width, height) in [(100, 30), (100, 24), (160, 30)] {
            for cursor in [4, 12, 33] {
                app.cursor = cursor;
                let chosen = format!("List {}", cursor - 4);
                let shown = screen_of(&app, width, height);
                assert!(shown.contains(&format!("{chosen} ")), "{width}x{height} lost {chosen}\n{shown}");
            }
        }
    }

    #[test]
    fn many_playlists_leave_hvsc_in_the_sidebar() {
        let mut app = app();
        let list = app.lists[0].clone();
        app.lists = (0..40).map(|n| PlaylistInfo { name: format!("List {n}"), ..list.clone() }).collect();
        let shown = screen_of(&app, 120, 30);
        assert!(shown.contains("Musicians") && shown.contains("Games"), "{shown}");
        app.sidebar = 30;
        assert!(screen_of(&app, 120, 30).contains("List 27"), "the library should scroll");
    }

    #[test]
    fn long_reads_stay_out_of_the_way_of_the_keys() {
        let mut app = composers_app();
        app.prints_wanted = true;
        app.tick(Instant::now());
        let prints = app.outbox.iter().find(|r| r.cmd == "prints.composers").unwrap();
        assert!(prints.is_bulk());
        app.outbox.clear();
        app.sidebar = app.library_rows() + 1;
        app.open_sidebar();
        assert!(app.outbox.iter().find(|r| r.cmd == "hvsc.authors").unwrap().is_bulk());
        assert!(screen_of(&app, 160, 40).contains("Reading the collection"));
        app.outbox.clear();
        press(&mut app, KeyCode::Char('p'));
        assert!(app.outbox.iter().all(|r| !r.is_bulk()));
    }

    #[test]
    fn how_alike_is_a_number_and_nothing_more() {
        let mut app = app();
        app.view = View::Like("Commando".into());
        let mut like = tune("Lightforce");
        like.score = Some(0.71);
        app.rows = vec![like];
        let shown = screen_of(&app, 160, 40);
        assert!(shown.contains("Alike") && shown.contains("71%"), "{shown}");
        assert!(!shown.contains("███████"), "{shown}");
    }

    fn describe_app() -> App {
        let mut app = app();
        app.sidebar = 1;
        app.focus = Focus::Sidebar;
        press(&mut app, KeyCode::Enter);
        app.outbox.clear();
        app
    }

    fn made(tunes: &[&str]) -> Value {
        json!({
            "title": "fast from 1987", "note": null, "understood": "Fast tunes, from 1987.", "facts": "2 tunes, 7 minutes",
            "tunes": tunes.iter().map(|t| tune(t)).collect::<Vec<_>>(),
        })
    }

    fn type_in(app: &mut App, text: &str) {
        for letter in text.chars() {
            press(app, KeyCode::Char(letter));
        }
    }

    fn asked_tag(app: &App) -> Tag {
        app.outbox.iter().rev().find(|r| matches!(r.tag, Tag::Described { .. })).unwrap().tag.clone()
    }

    #[test]
    fn describe_opens_ready_to_type_and_sends_the_sentence_without_playing() {
        let mut app = describe_app();
        assert_eq!(app.view, View::Describe);
        assert!(matches!(app.mode, Mode::Describing(_)));
        type_in(&mut app, "fast from 1987");
        assert!(screen_of(&app, 160, 40).contains("Describe: fast from 1987"));
        press(&mut app, KeyCode::Enter);
        assert!(screen_of(&app, 160, 40).contains("Making the list"));
        let asked = app.outbox.last().unwrap();
        assert_eq!(asked.cmd, "describe");
        assert_eq!(asked.args["text"], "fast from 1987");
        assert_eq!(asked.args["play"], false);
        assert!(asked.is_bulk());
    }

    #[test]
    fn a_described_list_says_what_it_understood_and_plays_as_a_smart_playlist() {
        let mut app = describe_app();
        type_in(&mut app, "fast from 1987");
        press(&mut app, KeyCode::Enter);
        let tag = asked_tag(&app);
        app.reply(tag, Ok(made(&["Commando", "Lightforce"])));
        let shown = screen_of(&app, 160, 40);
        for expected in ["“fast from 1987”", "Fast tunes, from 1987 · 2 tunes, 7 minutes", "Lightforce"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
        app.outbox.clear();
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Enter);
        let played = app.outbox.iter().find(|r| r.cmd == "play").unwrap();
        assert_eq!(played.args["name"], "fast from 1987");
        assert_eq!(played.args["start"], "/Lightforce.sid");
    }

    #[test]
    fn a_described_list_saves_whole_and_survives_looking_elsewhere() {
        let mut app = describe_app();
        type_in(&mut app, "fast");
        press(&mut app, KeyCode::Enter);
        let tag = asked_tag(&app);
        app.reply(tag, Ok(made(&["Commando", "Lightforce"])));
        press(&mut app, KeyCode::Char('n'));
        assert!(matches!(&app.mode, Mode::NewPlaylist(name) if name == "fast from 1987"));
        app.outbox.clear();
        press(&mut app, KeyCode::Enter);
        let saved = app.outbox.iter().find(|r| r.cmd == "playlist.new").unwrap();
        assert_eq!(saved.args["paths"].as_array().unwrap().len(), 2);

        app.sidebar = 2;
        app.open_sidebar();
        app.rows.clear();
        app.sidebar = 1;
        app.open_sidebar();
        assert_eq!(app.rows.len(), 2);
    }

    #[test]
    fn describe_offers_suggestions_and_esc_goes_back_to_them() {
        let mut app = describe_app();
        press(&mut app, KeyCode::Esc);
        let shown = screen_of(&app, 160, 40);
        for (name, _, _) in SUGGESTIONS {
            assert!(shown.contains(name), "{shown}");
        }
        press(&mut app, KeyCode::Down);
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.outbox.last().unwrap().args["text"], "never heard");
        let tag = asked_tag(&app);
        app.reply(tag, Ok(made(&["Commando"])));
        press(&mut app, KeyCode::Esc);
        assert!(app.rows.is_empty() && app.describing.sentence.is_empty() && !app.quit);
        press(&mut app, KeyCode::Esc);
        assert!(app.quit, "with nothing to go back from, esc leaves as elsewhere");
    }

    #[test]
    fn similar_to_a_tune_uses_whats_playing_and_otherwise_asks_for_a_name() {
        let mut app = describe_app();
        press(&mut app, KeyCode::Esc);
        app.cursor = 2;
        press(&mut app, KeyCode::Enter);
        assert_eq!(app.outbox.last().unwrap().cmd, "describe.playing");
        let tag = asked_tag(&app);
        app.reply(tag, Err("Nothing from the collection is playing.".into()));
        assert!(matches!(&app.mode, Mode::Describing(text) if text == "like "));
        assert!(screen_of(&app, 160, 40).contains("Nothing from the collection"));
    }

    #[test]
    fn an_old_answer_to_describe_no_longer_counts() {
        let mut app = describe_app();
        type_in(&mut app, "fast");
        press(&mut app, KeyCode::Enter);
        let old = asked_tag(&app);
        press(&mut app, KeyCode::Char('/'));
        type_in(&mut app, "er");
        press(&mut app, KeyCode::Enter);
        app.reply(old, Ok(made(&["Old"])));
        assert!(app.rows.is_empty() && app.describing.busy);
    }

    #[test]
    fn the_sidebar_has_three_sections_in_order() {
        let app = app();
        let shown = screen_of(&app, 160, 40);
        let at = |what: &str| shown.find(what).unwrap_or_else(|| panic!("no {what}\n{shown}"));
        let order = ["▓▒░ Library", " Search", " Describe", " Recently Played", "▓▒░ Playlists", " Favourites", "▓▒░ HVSC", " Home"].map(at);
        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{shown}");
    }

    fn tracker_song() -> Value {
        json!({
            "path": "/A.sid", "song": 1, "chip": 0, "frameRate": 50.0, "framesPerRow": 6.0, "hasGrid": true, "chips": 1,
            "instruments": [{ "name": "Saw", "ad": 9, "sr": 169 }, { "name": "Noise › Pulse", "ad": 10, "sr": 9 }],
            "rows": (0..200).map(|n| json!({
                "f": n * 6,
                "v": [if n % 4 == 0 { format!("C-{} 01 ARP", n % 8) } else { String::new() }, if n % 8 == 2 { "A#2 02 ...".to_string() } else { String::new() }, if n % 8 == 3 { "--- 00 ...".to_string() } else { String::new() }],
                "c": 1024, "r": 7, "ro": 3, "m": 1,
            })).collect::<Vec<_>>(),
        })
    }

    fn drawer_app() -> App {
        let mut app = app();
        press(&mut app, KeyCode::Char('u'));
        let start = Instant::now();
        app.mode = Mode::Drawer(start - DRAWER_SLIDES);
        app.now = Some(start);
        app.outbox.clear();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "heard": 2.4, "levels": [0.9, 0.1, 0.0], "notes": ["C-4", null, null] })));
        app
    }

    #[test]
    fn the_drawer_asks_for_the_tune_once_and_says_it_is_working() {
        let mut app = drawer_app();
        assert!(matches!(app.mode, Mode::Drawer(_)) && app.wants_position());
        let asked = app.outbox.iter().filter(|r| r.cmd == "tracker.song").count();
        assert_eq!(asked, 1);
        assert!(app.outbox[0].is_bulk());
        assert!(screen_of(&app, 160, 40).contains("Rebuilding the tune"));
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "heard": 2.5, "levels": [], "notes": [] })));
        assert_eq!(app.outbox.iter().filter(|r| r.cmd == "tracker.song").count(), 1, "not again for the same tune");
    }

    #[test]
    fn the_playhead_follows_what_is_heard_with_rows_to_come_below_it() {
        let mut app = drawer_app();
        app.reply(Tag::TrackerSong, Ok(tracker_song()));
        assert_eq!(app.tracker_row(), 20);
        let shown = screen_of(&app, 160, 40);
        let lines: Vec<&str> = shown.lines().collect();
        let at = |text: &str| lines.iter().position(|line| line.contains(text)).unwrap_or_else(|| panic!("no {text}\n{shown}"));
        assert!(at("0014 ") < at("0018 "), "{shown}");
        assert!(at("0010 ") < at("0014 "), "{shown}");
        for expected in ["Under the hood", "V1 Saw", "C-4 01 ARP", "A#2 02", "---", "INSTRUMENTS", "FILTER", "LP ", "RES 7", "V1 V2 --", "6 frames a row, 8.3 rows a second"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
    }

    #[test]
    fn looking_around_stops_following_until_asked() {
        let mut app = drawer_app();
        app.reply(Tag::TrackerSong, Ok(tracker_song()));
        press(&mut app, KeyCode::Down);
        assert_eq!(app.tracker.looking_at, Some(21));
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "heard": 10.0, "levels": [], "notes": [] })));
        assert_eq!(app.tracker_row(), 21);
        assert!(screen_of(&app, 160, 40).contains("f follows"));
        press(&mut app, KeyCode::Char('f'));
        assert_eq!(app.tracker_row(), 83);
    }

    #[test]
    fn a_new_tune_means_a_new_rebuild() {
        let mut app = drawer_app();
        app.reply(Tag::TrackerSong, Ok(tracker_song()));
        app.outbox.clear();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/B.sid", "song": 1, "heard": 0.0, "levels": [], "notes": [] })));
        assert!(app.tracker.song.is_none());
        assert_eq!(app.outbox.iter().filter(|r| r.cmd == "tracker.song").count(), 1);
        // The old answer arriving late doesn't count for it.
        app.reply(Tag::TrackerSong, Ok(tracker_song()));
        assert!(app.tracker.song.is_none());
    }

    #[test]
    fn the_drawer_slides_away_and_leaves_the_list() {
        let mut app = drawer_app();
        press(&mut app, KeyCode::Esc);
        assert!(matches!(app.mode, Mode::DrawerClosing(_)) && !app.quit);
        app.tick(app.now.unwrap() + DRAWER_SLIDES);
        assert!(matches!(app.mode, Mode::Normal));
    }

    #[test]
    fn the_drawer_draws_at_every_size_and_every_moment_of_its_slide() {
        for (w, h) in [(5, 3), (20, 8), (60, 24), (83, 24), (84, 24), (120, 30), (240, 90)] {
            for ms in [0, 40, 110, 219, 400] {
                let mut app = drawer_app();
                app.reply(Tag::TrackerSong, Ok(tracker_song()));
                let start = Instant::now();
                app.now = Some(start + Duration::from_millis(ms));
                app.mode = Mode::Drawer(start);
                let _ = screen_of(&app, w, h);
                app.mode = Mode::DrawerClosing(start);
                let _ = screen_of(&app, w, h);
            }
        }
    }

    fn frame_hex(i: u64, set: &[(usize, u8)]) -> Value {
        let mut registers = [0u8; 29];
        for (n, value) in set {
            registers[*n] = *value;
        }
        json!({ "i": i, "r": registers.iter().map(|b| format!("{b:02X}")).collect::<String>() })
    }

    fn drawer_with_frames() -> App {
        let mut app = drawer_app();
        let frames: Vec<Value> = (1..=200u64).map(|i| frame_hex(i, &[(0, 0x67), (1, 0x11), (2, (i % 200) as u8), (3, 8), (4, 0x41), (0x12, 0x81), (0x16, (i / 2) as u8), (0x17, 0x73), (0x18, 0x1F)])).collect();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "heard": 4.0, "chips": 1, "levels": [0.9, 0.0, 0.2], "notes": ["C-4", null, "D-3"], "frames": frames })));
        app
    }

    #[test]
    fn tab_steps_through_the_drawer_and_comes_round() {
        let mut app = drawer_app();
        for expected in [1, 2, 3, 0] {
            press(&mut app, KeyCode::Tab);
            assert_eq!(app.tracker.tab, expected);
            assert!(matches!(app.mode, Mode::Drawer(_)));
        }
        assert!(screen_of(&app, 160, 40).contains("Registers"));
    }

    #[test]
    fn registers_decode_the_control_byte_and_light_what_changed() {
        let mut app = drawer_with_frames();
        app.tracker.tab = 1;
        let shown = screen_of(&app, 160, 40);
        for expected in ["VOICE 1", "VOICE 3", "$D404", "CTRL", "41", "GATE", "PUL", "NOI", "FILTER", "$D417", "RES/ROUT", "73", "ENV 3"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
        assert!(app.tracker.lit(2), "pulse width low changes every frame");
        assert!(!app.tracker.lit(0), "frequency hasn't changed");
    }

    #[test]
    fn sweeps_draw_the_voice_on_a_pulse_wave_and_the_gates() {
        let mut app = drawer_with_frames();
        app.tracker.tab = 2;
        let shown = screen_of(&app, 160, 40);
        for expected in ["PULSE WIDTH V1", "FILTER CUTOFF", "RESONANCE  7", "GATES", "━"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
    }

    #[test]
    fn pitch_shows_octaves_voices_and_the_note_now() {
        let mut app = drawer_with_frames();
        app.tracker.tab = 3;
        let shown = screen_of(&app, 160, 40);
        for expected in ["C4", "C1", "V1 C-4", "V2 —", "━"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
    }

    #[test]
    fn frames_are_kept_once_and_a_rewind_starts_over() {
        let mut app = drawer_with_frames();
        assert_eq!(app.tracker.history.len(), 200);
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "frames": [frame_hex(200, &[]), frame_hex(201, &[])] })));
        assert_eq!(app.tracker.history.len(), 201);
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "frames": [frame_hex(3, &[])] })));
        assert_eq!(app.tracker.history.len(), 1);
    }

    #[test]
    fn answers_that_overlap_build_up_the_history() {
        let mut app = drawer_app();
        app.tracker.history.clear();
        app.tracker.last_frame = None;
        // Each answer is the last eight frames, moving on by a few, as the app sends them.
        for end in (8..=400u64).step_by(3) {
            let frames: Vec<Value> = (end - 7..=end).map(|i| frame_hex(i, &[(2, (i / 40) as u8)])).collect();
            app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "frames": frames })));
        }
        assert_eq!(app.tracker.history.len(), 398, "every frame, once");
        // The value next changes on frame 400.
        assert!(!app.tracker.lit(2));
        let changed: Vec<Value> = (399..=402u64).map(|i| frame_hex(i, &[(2, (i / 40) as u8)])).collect();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "frames": changed })));
        assert!(app.tracker.lit(2));
        let later: Vec<Value> = (403..=420u64).map(|i| frame_hex(i, &[(2, 10)])).collect();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "frames": later })));
        assert!(!app.tracker.lit(2), "goes out once it stops changing");
    }

    #[test]
    fn the_first_ask_wants_all_the_history_and_later_ones_only_whats_new() {
        let mut app = drawer_app();
        app.tracker.history.clear();
        assert_eq!(app.position_args()["count"], DRAWER_HISTORY);
        let mut app = drawer_with_frames();
        assert_eq!(app.position_args()["count"], 8);
        app.tracker.chip = 1;
        assert_eq!(app.position_args()["chip"], 1);
    }

    #[test]
    fn a_multi_sid_tune_switches_chip_and_rebuilds() {
        let mut app = drawer_with_frames();
        // One chip: nothing to switch to.
        press(&mut app, KeyCode::Char('2'));
        assert_eq!(app.tracker.chip, 0);
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "chips": 2, "frames": [] })));
        assert!(screen_of(&app, 160, 40).contains("SID 1 of 2, s to switch"));
        assert!(screen_of(&app, 160, 40).contains("s next SID"));
        app.outbox.clear();
        press(&mut app, KeyCode::Char('2'));
        assert_eq!(app.tracker.chip, 1);
        assert_eq!(app.tracker.history.len(), 200, "the frames hold every chip, so they stay");
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "chip": 1, "chips": 2, "frames": [] })));
        let asked = app.outbox.iter().find(|r| r.cmd == "tracker.song").unwrap();
        assert_eq!(asked.args["chip"], 1);
    }

    #[test]
    fn chips_switch_by_number_or_s_in_every_key_set() {
        for scheme in [KeyScheme::Normal, KeyScheme::Vim, KeyScheme::Emacs] {
            let mut app = app_with(scheme);
            press(&mut app, KeyCode::Char('u'));
            app.tracker.position.chips = 2;
            press(&mut app, KeyCode::Char('2'));
            assert_eq!(app.tracker.chip, 1, "{scheme:?}");
            press(&mut app, KeyCode::Char('1'));
            assert_eq!(app.tracker.chip, 0, "{scheme:?}");
            press(&mut app, KeyCode::Char('s'));
            assert_eq!(app.tracker.chip, 1, "{scheme:?}");
            press(&mut app, KeyCode::Char('s'));
            assert_eq!(app.tracker.chip, 0, "{scheme:?}");
            assert!(matches!(app.mode, Mode::Drawer(_)), "{scheme:?}");
        }
    }

    #[test]
    fn an_answer_about_the_old_chip_keeps_its_frames_but_not_its_notes() {
        let mut app = drawer_with_frames();
        app.tracker.position.chips = 2;
        press(&mut app, KeyCode::Char('2'));
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "chip": 0, "chips": 2, "notes": ["F-1"], "frames": [frame_hex(500, &[])] })));
        assert_eq!(app.tracker.last_frame, Some(500));
        assert_ne!(app.tracker.position.notes.first().cloned().flatten().as_deref(), Some("F-1"));
    }

    /// Two chips playing different things: the second's filter and first voice stand apart.
    fn drawer_with_two_chips() -> App {
        let mut app = drawer_app();
        let frames: Vec<Value> = (1..=200u64)
            .map(|i| {
                let mut hex = String::new();
                for chip in 0..2u8 {
                    let mut registers = [0u8; 29];
                    registers[0] = 0x67;
                    registers[1] = 0x11;
                    registers[4] = if chip == 0 { 0x41 } else { 0x21 };
                    registers[2] = if chip == 0 { i as u8 } else { 5 };
                    registers[0x17] = if chip == 0 { 0x71 } else { 0x92 };
                    registers.iter().for_each(|b| hex.push_str(&format!("{b:02X}")));
                }
                json!({ "i": i, "r": hex })
            })
            .collect();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/A.sid", "song": 1, "chips": 2, "notes": ["C-4", null, null], "allNotes": [["C-4", null, null], ["G-2", null, null]], "allLevels": [[1.0, 0.0, 0.0], [0.5, 0.0, 0.0]], "frames": frames })));
        app
    }

    #[test]
    fn voice_lines_show_every_chip_and_light_each_on_its_own() {
        let mut app = drawer_with_two_chips();
        app.tracker.tab = 1;
        assert!(app.tracker.lit(2), "the first chip's pulse width moves");
        assert!(!app.tracker.lit(CHIP_REGISTERS + 2), "the second's doesn't");
        let shown = screen_of(&app, 160, 40);
        for expected in ["SID 1", "SID 2", "NOTE", "FREQ", "1167", "PUL", "SAW", "C-4", "G-2", "cutoff", "res 7", "res 9", "through V1", "osc3", "env3"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
    }

    #[test]
    fn bars_show_only_where_there_is_room_for_them() {
        let mut app = drawer_with_two_chips();
        app.tracker.tab = 1;
        let wide = screen_of(&app, 120, 40);
        for expected in ["LEVEL", "PULSE WIDTH", "██████████", "cutoff", "res 7", "env3"] {
            assert!(wide.contains(expected), "missing {expected}\n{wide}");
        }
        let plain = screen_of(&app, 80, 40);
        for missing in ["LEVEL", "PULSE WIDTH", "█"] {
            assert!(!plain.contains(missing), "{missing} shouldn't show\n{plain}");
        }
        assert!(plain.contains("cutoff 000"), "{plain}");
    }

    #[test]
    fn with_no_room_it_collapses_to_the_chosen_chip_and_can_switch() {
        for (tab, w, h) in [(1, 50, 40), (1, 160, 16), (2, 40, 40), (3, 160, 14)] {
            let mut app = drawer_with_two_chips();
            app.tracker.tab = tab;
            let shown = screen_of(&app, w, h);
            assert!(!shown.contains("SID 2 ") || shown.contains("SID 1 of 2"), "tab {tab} at {w}x{h}\n{shown}");
            assert!(app.tracker.collapsed.get(), "tab {tab} at {w}x{h}");
            press(&mut app, KeyCode::Char('s'));
            assert_eq!(app.tracker.chip, 1, "tab {tab} at {w}x{h}");
            let switched = screen_of(&app, w, h);
            assert!(switched.contains("SID 2 of 2, s to switch"), "tab {tab} at {w}x{h}\n{switched}");
            assert!(switched.contains("Pitch"), "every tab's name fits, tab {tab} at {w}x{h}\n{switched}");
            assert!(!screen_of(&app, 160, 40).contains("s to switch"), "back to every chip, tab {tab}");
            assert_eq!(app.tracker.chip, 1, "the choice stays for next time");
        }
    }

    #[test]
    fn a_collapsed_tab_shows_the_notes_and_filter_of_the_chosen_chip() {
        let mut app = drawer_with_two_chips();
        app.tracker.tab = 1;
        app.tracker.chip = 1;
        let shown = screen_of(&app, 60, 40);
        assert!(shown.contains("G-2") && shown.contains("res 9"), "{shown}");
        assert!(!shown.contains("C-4") && !shown.contains("res 7"), "{shown}");
    }

    #[test]
    fn control_bytes_read_as_words() {
        assert_eq!(wave_name(0), "—");
        assert_eq!(wave_name(0x40), "PUL");
        assert_eq!(wave_name(0x50), "T+P");
        assert_eq!(bits_name(0x10), "—");
        assert_eq!(bits_name(1), "GATE");
        assert_eq!(bits_name(3), "GATE SYNC");
        assert_eq!(bits_name(7), "G S R");
    }

    #[test]
    fn sweeps_and_pitch_show_every_chip() {
        let mut app = drawer_with_two_chips();
        app.tracker.tab = 2;
        let sweeps = screen_of(&app, 120, 40);
        for expected in ["SID 1", "SID 2", "PULSE V1", "PULSE none", "CUTOFF", "RES 7", "RES 9", "GATES"] {
            assert!(sweeps.contains(expected), "missing {expected}\n{sweeps}");
        }
        app.tracker.tab = 3;
        let pitch = screen_of(&app, 120, 40);
        for expected in ["SID 1", "SID 2", "V1 C-4", "V1 G-2"] {
            assert!(pitch.contains(expected), "missing {expected}\n{pitch}");
        }
    }

    #[test]
    fn chips_switch_only_where_one_chip_shows() {
        let mut app = drawer_with_two_chips();
        app.tracker.tab = 2;
        assert!(!screen_of(&app, 160, 40).contains("s to switch"));
        press(&mut app, KeyCode::Char('s'));
        assert_eq!(app.tracker.chip, 0);
        app.tracker.tab = 0;
        assert!(screen_of(&app, 160, 40).contains("s to switch"));
        press(&mut app, KeyCode::Char('s'));
        assert_eq!(app.tracker.chip, 1);
    }

    #[test]
    fn another_number_of_chips_starts_over() {
        let mut app = drawer_with_two_chips();
        app.reply(Tag::TrackerPosition, Ok(json!({ "path": "/B.sid", "song": 1, "chips": 1, "frames": [frame_hex(201, &[])] })));
        assert_eq!(app.tracker.history.len(), 1);
        assert_eq!(app.tracker.chips(), 1);
    }

    #[test]
    fn every_tab_draws_at_every_size_with_and_without_frames() {
        for (w, h) in [(5, 3), (20, 8), (30, 12), (60, 24), (84, 24), (120, 30), (240, 90)] {
            for tab in 0..DRAWER_TABS.len() {
                for frames in [false, true] {
                    let mut app = if frames { drawer_with_frames() } else { drawer_app() };
                    app.tracker.tab = tab;
                    let _ = screen_of(&app, w, h);
                    let mut two = drawer_with_two_chips();
                    two.tracker.tab = tab;
                    let _ = screen_of(&two, w, h);
                }
            }
        }
    }

    #[test]
    fn cells_come_apart_with_dots_for_what_is_missing() {
        assert_eq!(cell_parts("C-4 02 ARP"), ("C-4", "02", "ARP"));
        assert_eq!(cell_parts("--- 00 ..."), ("---", "··", "···"));
        assert_eq!(cell_parts("... 00 VIB"), ("···", "··", "VIB"));
        assert_eq!(cell_parts(""), ("···", "··", "···"));
    }

    #[test]
    fn composers_ignore_the_keys_for_tunes() {
        let mut app = composers_app();
        for key in ['l', 'd', 's', 'f', 'a', 'n', 'x', ' '] {
            press(&mut app, KeyCode::Char(key));
            assert!(matches!(app.mode, Mode::Normal), "{key}");
        }
        assert!(app.outbox.is_empty());
        assert!(matches!(app.view, View::Hvsc(_)));
    }

    #[test]
    fn composers_are_found_by_typing() {
        let mut app = composers_app();
        press(&mut app, KeyCode::Char('/'));
        for letter in "gal".chars() {
            press(&mut app, KeyCode::Char(letter));
        }
        assert_eq!(app.cursor, 1);
        assert!(screen_of(&app, 160, 48).contains("Find: gal"));
        press(&mut app, KeyCode::Enter);
        assert!(matches!(app.mode, Mode::Normal));
        assert_eq!(app.cursor, 1);
    }

    #[test]
    fn a_composers_sound_is_asked_for_from_their_own_command() {
        let mut app = composers_app();
        app.prints_wanted = true;
        app.tick(Instant::now());
        assert!(app.outbox.iter().any(|r| r.cmd == "prints.composers"));
        assert!(app.outbox.iter().all(|r| r.cmd != "sound" && r.cmd != "like"), "a folder has no sound of its own");
    }

    #[test]
    fn the_composer_panel_has_their_sound_when_known() {
        let mut app = composers_app();
        app.prints.insert(app.rows[0].path.clone(), Some(vec![0.5; 9]));
        let text = screen_of(&app, 160, 48);
        assert!(text.contains("Their sound, on average") && text.contains("Nt Ar Vb"), "{text}");
    }

    #[test]
    fn typing_keeps_every_letter_in_every_set() {
        for scheme in [KeyScheme::Normal, KeyScheme::Vim, KeyScheme::Emacs] {
            let mut app = app_with(scheme);
            press(&mut app, KeyCode::Char('/'));
            for c in "gdhl".chars() {
                press(&mut app, KeyCode::Char(c));
            }
            assert_eq!(app.query, "gdhl", "{scheme:?}");
            app.key(KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL));
            assert_eq!(app.query, "", "{scheme:?}");
        }
    }

    #[test]
    fn help_closes_with_any_key_and_does_nothing_else() {
        let mut app = app();
        press(&mut app, KeyCode::Char('?'));
        press(&mut app, KeyCode::Char('q'));
        assert!(!app.quit);
        assert!(matches!(app.mode, Mode::Normal));
    }
}
