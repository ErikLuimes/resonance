//! The terminal app: `resonance` on its own. Sidebar, tune list, what's playing
//! and the three voices. `App` holds the state and answers keys and replies with
//! requests to send, so it can be tested with no terminal and no Resonance.

use crate::client::Client;
use crate::model::{clock, PlaylistInfo, Scope, Status, Tune};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::symbols::Marker;
use ratatui::text::{Line, Span};
use ratatui::widgets::canvas::{Canvas, Line as CanvasLine};
use ratatui::widgets::{Block, Borders, Cell, Clear, Gauge, List, ListItem, ListState, Paragraph, Row, Table, TableState};
use ratatui::Frame;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const DEBOUNCE: Duration = Duration::from_millis(120);
const SCOPE_EVERY: Duration = Duration::from_millis(50);
const STATUS_EVERY: Duration = Duration::from_millis(500);
/// The voices' colours, as in the app's icon.
const VOICES: [Color; 3] = [Color::Cyan, Color::Magenta, Color::LightRed];
const DIM: Style = Style::new().add_modifier(Modifier::DIM);
const SELECTED: Style = Style::new().add_modifier(Modifier::REVERSED);

#[derive(Debug, Clone, PartialEq)]
pub enum View {
    Search,
    Recent,
    Playlist(String),
    /// Sounds Like, by the seed's title.
    Like(String),
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
    pub scope: Scope,
    pub message: Option<String>,
    pub quit: bool,
    pub outbox: Vec<Request>,
    pub search_due: Option<Instant>,
    generation: u64,
}

impl App {
    pub fn new() -> App {
        let mut app = App {
            lists: Vec::new(),
            sidebar: 2,
            view: View::Playlist("Favourites".into()),
            rows: Vec::new(),
            cursor: 0,
            marked: BTreeSet::new(),
            focus: Focus::List,
            mode: Mode::Normal,
            query: String::new(),
            status: None,
            scope: Scope::default(),
            message: None,
            quit: false,
            outbox: Vec::new(),
            search_due: None,
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
        let mut entries = vec!["Search".to_string(), "Recently Played".to_string()];
        entries.extend(self.lists.iter().map(|l| l.name.clone()));
        entries
    }

    fn open_sidebar(&mut self) {
        self.view = match self.sidebar {
            0 => View::Search,
            1 => View::Recent,
            n => match self.lists.get(n - 2) {
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
        }
    }

    pub fn tick(&mut self, now: Instant) {
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
                if !matches!(tag, Tag::Scope | Tag::Status) {
                    self.message = Some(error);
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
                    self.cursor = self.cursor.min(self.rows.len().saturating_sub(1));
                }
            }
            Tag::Rows(_) => {}
            Tag::Status => self.status = serde_json::from_value(value).ok(),
            Tag::Scope => {
                if let Ok(scope) = serde_json::from_value(value) {
                    self.scope = scope;
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

    pub fn key(&mut self, key: KeyEvent) {
        self.message = None;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && key.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        match std::mem::replace(&mut self.mode, Mode::Normal) {
            Mode::Normal => self.key_normal(key),
            Mode::Help => {}
            Mode::Search => self.key_search(key),
            Mode::NewPlaylist(name) => self.key_new_playlist(key, name),
            Mode::AddTo(cursor) => self.key_add_to(key, cursor),
            Mode::Browser(browser) => self.key_browser(key, browser),
        }
    }

    fn move_cursor(&mut self, by: isize) {
        match self.focus {
            Focus::Sidebar => {
                let last = self.sidebar_entries().len().saturating_sub(1);
                self.sidebar = self.sidebar.saturating_add_signed(by).min(last);
            }
            Focus::List => {
                self.cursor = self.cursor.saturating_add_signed(by).min(self.rows.len().saturating_sub(1));
            }
        }
    }

    fn key_normal(&mut self, key: KeyEvent) {
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => self.quit = true,
            KeyCode::Up if shift => self.move_tune(-1),
            KeyCode::Down if shift => self.move_tune(1),
            KeyCode::Char('K') => self.move_tune(-1),
            KeyCode::Char('J') => self.move_tune(1),
            KeyCode::Up | KeyCode::Char('k') => self.move_cursor(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_cursor(1),
            KeyCode::PageUp => self.move_cursor(-15),
            KeyCode::PageDown => self.move_cursor(15),
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
            }
            KeyCode::Enter => self.play_cursor(),
            KeyCode::Char(' ') if self.focus == Focus::List => {
                if let Some(tune) = self.rows.get(self.cursor) {
                    let path = tune.path.clone();
                    if !self.marked.remove(&path) {
                        self.marked.insert(path);
                    }
                    self.move_cursor(1);
                }
            }
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
            KeyCode::Char('n') => self.mode = Mode::NewPlaylist(String::new()),
            KeyCode::Char('x') => self.remove_chosen(),
            KeyCode::Char('o') => {
                let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
                let start = std::env::current_dir().unwrap_or(home);
                self.mode = Mode::Browser(Browser::open(start));
            }
            KeyCode::Char('?') => self.mode = Mode::Help,
            _ => {}
        }
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
                self.ack(None, false, "play", args);
            }
        }
    }

    fn sounds_like(&mut self) {
        let Some(tune) = self.rows.get(self.cursor).cloned() else { return };
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
            KeyCode::Backspace => {
                self.query.pop();
            }
            KeyCode::Char(c) => self.query.push(c),
            _ => {}
        }
        self.search_due = Some(Instant::now() + DEBOUNCE);
        self.mode = Mode::Search;
    }

    fn key_new_playlist(&mut self, key: KeyEvent, mut name: String) {
        match key.code {
            KeyCode::Esc => return,
            KeyCode::Enter => {
                if !name.trim().is_empty() {
                    let paths = self.chosen();
                    let message = format!("Made {name}.");
                    self.marked.clear();
                    self.ack(Some(message), true, "playlist.new", json!({ "name": name.trim(), "paths": paths }));
                }
                return;
            }
            KeyCode::Backspace => {
                name.pop();
            }
            KeyCode::Char(c) => name.push(c),
            _ => {}
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
    let area = frame.area();
    let [main, now, keys] =
        Layout::vertical([Constraint::Min(5), Constraint::Length(7), Constraint::Length(1)]).areas(area);
    let [side, list] = Layout::horizontal([Constraint::Length(24), Constraint::Min(20)]).areas(main);
    draw_sidebar(frame, app, side);
    draw_list(frame, app, list);
    draw_now(frame, app, now);
    draw_keys(frame, app, keys);
    match &app.mode {
        Mode::AddTo(cursor) => draw_add_to(frame, app, *cursor),
        Mode::NewPlaylist(name) => draw_prompt(frame, "New playlist", name),
        Mode::Browser(browser) => draw_browser(frame, browser),
        Mode::Help => draw_help(frame),
        Mode::Normal | Mode::Search => {}
    }
}

fn pane(title: String, focused: bool) -> Block<'static> {
    let block = Block::default().borders(Borders::ALL).title(title);
    if focused {
        block.border_style(Style::new().fg(Color::Cyan))
    } else {
        block.border_style(DIM)
    }
}

fn draw_sidebar(frame: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = app
        .sidebar_entries()
        .into_iter()
        .enumerate()
        .map(|(i, name)| {
            let count = i.checked_sub(2).and_then(|n| app.lists.get(n)).map(|l| l.count);
            let line = match count {
                Some(count) => Line::from(vec![Span::raw(name), Span::styled(format!("  {count}"), DIM)]),
                None => Line::from(name),
            };
            ListItem::new(line)
        })
        .collect();
    let mut state = ListState::default().with_selected(Some(app.sidebar));
    let highlight = if app.focus == Focus::Sidebar { SELECTED } else { Style::new().add_modifier(Modifier::BOLD) };
    frame.render_stateful_widget(
        List::new(items).block(pane(" Resonance ".into(), app.focus == Focus::Sidebar)).highlight_style(highlight),
        area,
        &mut state,
    );
}

fn list_title(app: &App) -> String {
    match &app.view {
        View::Search if matches!(app.mode, Mode::Search) => format!(" / {}▏ ", app.query),
        View::Search if app.query.is_empty() => " Search: press / ".into(),
        View::Search => format!(" Search “{}” ", app.query),
        View::Recent => " Recently Played ".into(),
        View::Playlist(name) => format!(" {name} "),
        View::Like(title) => format!(" Sounds like {title} "),
    }
}

fn draw_list(frame: &mut Frame, app: &App, area: Rect) {
    let playing = app.status.as_ref().and_then(|s| s.now.as_ref()).map(|n| n.path.as_str());
    let rows: Vec<Row> = app
        .rows
        .iter()
        .map(|t| {
            let mark = if playing == Some(t.path.as_str()) {
                "♪"
            } else if app.marked.contains(&t.path) {
                "✓"
            } else {
                " "
            };
            let last = match t.score {
                Some(score) => format!("{:.0}%", score * 100.0),
                None => t.secs.map(|s| clock(f64::from(s))).unwrap_or_default(),
            };
            Row::new(vec![
                Cell::from(mark),
                Cell::from(t.title.clone()),
                Cell::from(t.author.clone()),
                Cell::from(last),
            ])
        })
        .collect();
    let last_column = if matches!(app.view, View::Like(_)) { "Alike" } else { "Length" };
    let table = Table::new(
        rows,
        [Constraint::Length(1), Constraint::Percentage(55), Constraint::Percentage(35), Constraint::Length(6)],
    )
    .header(Row::new(vec!["", "Title", "Composer", last_column]).style(DIM))
    .row_highlight_style(if app.focus == Focus::List { SELECTED } else { Style::new() })
    .block(pane(list_title(app), app.focus == Focus::List));
    let mut state = TableState::default().with_selected(Some(app.cursor));
    frame.render_stateful_widget(table, area, &mut state);
}

fn draw_now(frame: &mut Frame, app: &App, area: Rect) {
    let block = pane(" Now Playing ".into(), false);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let [title, bar, scopes] =
        Layout::vertical([Constraint::Length(1), Constraint::Length(1), Constraint::Min(1)]).areas(inner);
    let status = app.status.as_ref();
    let line = match status.and_then(|s| s.now.as_ref().map(|n| (s, n))) {
        Some((status, now)) => {
            let mut spans = vec![
                Span::styled(format!("♪ {}", now.title), Style::new().add_modifier(Modifier::BOLD)),
                Span::raw(format!(" · {}", now.author)),
            ];
            if now.songs > 1 {
                spans.push(Span::styled(format!("  subtune {} of {}", now.song, now.songs), DIM));
            }
            if status.favourite {
                spans.push(Span::styled("  ♥", Style::new().fg(Color::Red)));
            }
            if status.state == "paused" {
                spans.push(Span::styled("  paused", DIM));
            }
            Line::from(spans)
        }
        None => Line::styled("Nothing is playing. Press r for Surprise Me.", DIM),
    };
    frame.render_widget(Paragraph::new(line), title);
    if let Some(status) = status.filter(|s| s.now.is_some()) {
        let ratio = status.duration.filter(|d| *d > 0.0).map_or(0.0, |d| (status.elapsed / d).clamp(0.0, 1.0));
        let label = match status.duration {
            Some(duration) => format!("{} / {}", clock(status.elapsed), clock(duration)),
            None => clock(status.elapsed),
        };
        frame.render_widget(
            Gauge::default().ratio(ratio).label(label).gauge_style(Style::new().fg(Color::Cyan)).use_unicode(true),
            bar,
        );
    }
    let cells = Layout::horizontal([Constraint::Ratio(1, 3); 3]).split(scopes);
    for (voice, cell) in cells.iter().enumerate() {
        draw_voice(frame, app.scope.voices.get(voice).map_or(&[][..], Vec::as_slice), voice, *cell);
    }
}

/// One voice's waveform in braille: what it's actually doing, not a decoration.
fn draw_voice(frame: &mut Frame, samples: &[f32], voice: usize, area: Rect) {
    if area.height == 0 || area.width == 0 {
        return;
    }
    let width = samples.len().max(1) as f64;
    let canvas = Canvas::default()
        .marker(Marker::Braille)
        .x_bounds([0.0, width])
        .y_bounds([-1.0, 1.0])
        .paint(move |ctx| {
            for (i, pair) in samples.windows(2).enumerate() {
                ctx.draw(&CanvasLine {
                    x1: i as f64,
                    y1: f64::from(pair[0]),
                    x2: i as f64 + 1.0,
                    y2: f64::from(pair[1]),
                    color: VOICES[voice % VOICES.len()],
                });
            }
        });
    frame.render_widget(canvas, area);
}

fn draw_keys(frame: &mut Frame, app: &App, area: Rect) {
    let line = match (&app.message, &app.mode) {
        (Some(message), _) => Line::from(message.clone()),
        (None, Mode::Search) => Line::styled("Type to search  ↵ or esc to go to the list", DIM),
        _ => Line::styled(
            "/ search  ↵ play  p pause  ␣ mark  l sounds like  f favourite  a add  n new  x remove  o files  ? help  q quit",
            DIM,
        ),
    };
    frame.render_widget(Paragraph::new(line), area);
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
        List::new(items).block(pane(title, true)).highlight_style(SELECTED),
        area,
        &mut state,
    );
}

fn draw_prompt(frame: &mut Frame, title: &str, text: &str) {
    let area = centred(frame.area(), 46, 3);
    frame.render_widget(Clear, area);
    frame.render_widget(Paragraph::new(format!("{text}▏")).block(pane(format!(" {title} "), true)), area);
}

fn draw_browser(frame: &mut Frame, browser: &Browser) {
    let area = centred(frame.area(), 70, 22);
    frame.render_widget(Clear, area);
    let items: Vec<ListItem> = browser
        .entries
        .iter()
        .map(|(name, is_dir)| {
            let mark = if browser.marked.contains(&browser.dir.join(name)) { "✓ " } else { "  " };
            let shown = if *is_dir { format!("{name}/") } else { name.clone() };
            let style = if *is_dir { Style::new().fg(Color::Cyan) } else { Style::new() };
            ListItem::new(Line::from(vec![Span::raw(mark), Span::styled(shown, style)]))
        })
        .collect();
    let mut state = ListState::default().with_selected(Some(browser.cursor));
    let block = pane(format!(" {} ", browser.dir.display()), true)
        .title_bottom(Line::from(" ␣ mark  ↵ open or use  ← up  esc cancel ").alignment(Alignment::Right));
    frame.render_stateful_widget(List::new(items).block(block).highlight_style(SELECTED), area, &mut state);
}

fn draw_help(frame: &mut Frame) {
    const LINES: [(&str, &str); 19] = [
        ("↑ ↓  j k", "Move"),
        ("Tab  ← →", "Sidebar or list"),
        ("↵", "Open, or play from here"),
        ("/", "Search the collection"),
        ("p", "Pause or carry on"),
        (". ,", "Next or previous tune"),
        ("r", "Surprise Me"),
        ("␣", "Mark a tune"),
        ("l", "Sounds Like this tune"),
        ("f", "Add to Favourites"),
        ("a", "Add to a playlist"),
        ("n", "New playlist, with what's marked"),
        ("x", "Take out of this playlist"),
        ("⇧↑ ⇧↓  K J", "Move a tune in the playlist"),
        ("o", "Find files: add or play them"),
        ("s", "Show in the Resonance window"),
        ("?", "This help (any key closes it)"),
        ("q", "Quit; the music carries on"),
        ("", ""),
    ];
    let area = centred(frame.area(), 52, 21);
    frame.render_widget(Clear, area);
    let lines: Vec<Line> = LINES
        .iter()
        .map(|(key, what)| Line::from(vec![Span::styled(format!("{key:<12}"), Style::new().fg(Color::Cyan)), Span::raw(*what)]))
        .collect();
    frame.render_widget(Paragraph::new(lines).block(pane(" Keys ".into(), true)), area);
}

// MARK: Running

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

pub fn run() -> Result<(), String> {
    // Before the screen changes, as it may have to start the app.
    let slow_client = Client::connect()?;
    let fast_client = Client::connect()?;
    let (reply_tx, replies) = mpsc::channel();
    let slow = Worker::spawn(slow_client, reply_tx.clone());
    // Polling apart from everything else, so the voices keep moving.
    let fast = Worker::spawn(fast_client, reply_tx);

    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, &slow, &fast, &replies);
    ratatui::restore();
    result.map_err(|e| e.to_string())
}

fn event_loop(
    terminal: &mut ratatui::DefaultTerminal,
    slow: &Worker,
    fast: &Worker,
    replies: &mpsc::Receiver<(Tag, Result<Value, String>)>,
) -> std::io::Result<()> {
    let mut app = App::new();
    let mut last_status = Instant::now() - STATUS_EVERY;
    let mut last_scope = Instant::now() - SCOPE_EVERY;
    let (mut status_pending, mut scope_pending) = (false, false);
    while !app.quit {
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
                _ => {}
            }
            app.reply(tag, answer);
        }
        for request in app.outbox.drain(..) {
            let _ = slow.tx.send(request);
        }
        if !status_pending && now.duration_since(last_status) >= STATUS_EVERY {
            last_status = now;
            status_pending = true;
            let _ = fast.tx.send(Request { tag: Tag::Status, cmd: "status", args: json!({}) });
        }
        let playing = app.status.as_ref().is_some_and(|s| s.state == "playing");
        if playing && !scope_pending && now.duration_since(last_scope) >= SCOPE_EVERY {
            last_scope = now;
            scope_pending = true;
            let _ = fast.tx.send(Request { tag: Tag::Scope, cmd: "scope", args: json!({ "count": 256 }) });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
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
        app.sidebar = 3;
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
        });
        app.scope = Scope { voices: vec![vec![0.0, 1.0, -1.0, 0.5]; 3] };
        let shown = screen(&app);
        for expected in ["Favourites", "Late Night", "Recently Played", "Composer", "♪ B", "subtune 1 of 3", "1:24 / 4:12", "♥"] {
            assert!(shown.contains(expected), "missing {expected}\n{shown}");
        }
    }

    #[test]
    fn draws_every_mode_even_in_a_tiny_terminal() {
        let mut app = app();
        for code in [KeyCode::Char('?'), KeyCode::Esc, KeyCode::Char('a'), KeyCode::Esc, KeyCode::Char('n'), KeyCode::Esc, KeyCode::Char('o')] {
            press(&mut app, code);
            let mut terminal = Terminal::new(TestBackend::new(20, 6)).unwrap();
            terminal.draw(|frame| draw(frame, &app)).unwrap();
            let _ = screen(&app);
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
