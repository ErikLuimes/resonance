//! `resonance pick`: a small list right where you are in the terminal, to choose
//! tunes from for another command: `resonance playlist add X $(resonance pick)`.
//! It draws on stderr, as stdout is for the paths it prints.

use crate::client::Client;
use crate::model::Tune;
use crate::palette;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Layout};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
use ratatui::{Terminal, TerminalOptions, Viewport};
use serde_json::json;
use std::collections::BTreeSet;
use std::time::{Duration, Instant};

const HEIGHT: u16 = 14;
const DEBOUNCE: Duration = Duration::from_millis(120);

/// The list's state, apart from the terminal.
#[derive(Default)]
pub struct Picker {
    pub query: String,
    pub tunes: Vec<Tune>,
    pub cursor: usize,
    pub marked: BTreeSet<String>,
    pub multi: bool,
    pub from_playlist: bool,
}

pub enum Outcome {
    Going,
    QueryChanged,
    Done,
    Cancelled,
}

impl Picker {
    pub fn key(&mut self, code: KeyCode, ctrl: bool) -> Outcome {
        match code {
            KeyCode::Esc => return Outcome::Cancelled,
            KeyCode::Char('c' | 'g') if ctrl => return Outcome::Cancelled,
            KeyCode::Enter => return Outcome::Done,
            // Letters are for typing here, so these work in every key set, as in fzf.
            KeyCode::Up => self.cursor = self.cursor.saturating_sub(1),
            KeyCode::Char('p' | 'k') if ctrl => self.cursor = self.cursor.saturating_sub(1),
            KeyCode::Down => self.cursor = (self.cursor + 1).min(self.tunes.len().saturating_sub(1)),
            KeyCode::Char('n' | 'j') if ctrl => self.cursor = (self.cursor + 1).min(self.tunes.len().saturating_sub(1)),
            KeyCode::Char('u') if ctrl && !self.query.is_empty() => {
                self.query.clear();
                return Outcome::QueryChanged;
            }
            KeyCode::Char(' ') if self.multi => {
                if let Some(tune) = self.tunes.get(self.cursor) {
                    if !self.marked.remove(&tune.path) {
                        self.marked.insert(tune.path.clone());
                    }
                }
                self.cursor = (self.cursor + 1).min(self.tunes.len().saturating_sub(1));
            }
            KeyCode::Backspace if !self.query.is_empty() => {
                self.query.pop();
                return Outcome::QueryChanged;
            }
            KeyCode::Char(c) if !ctrl => {
                self.query.push(c);
                return Outcome::QueryChanged;
            }
            _ => {}
        }
        Outcome::Going
    }

    /// What Enter chooses: what's marked, else the tune under the cursor.
    pub fn chosen(&self) -> Vec<String> {
        if !self.marked.is_empty() {
            // In the order they're listed, then any no longer shown.
            let mut chosen: Vec<String> =
                self.tunes.iter().filter(|t| self.marked.contains(&t.path)).map(|t| t.path.clone()).collect();
            chosen.extend(self.marked.iter().filter(|p| !chosen.contains(p)).cloned().collect::<Vec<_>>());
            return chosen;
        }
        self.tunes.get(self.cursor).map(|t| vec![t.path.clone()]).unwrap_or_default()
    }

    /// Filter a playlist's tunes; a search asks the app instead.
    pub fn shown(&self, all: &[Tune]) -> Vec<Tune> {
        let query = self.query.to_lowercase();
        all.iter()
            .filter(|t| t.title.to_lowercase().contains(&query) || t.author.to_lowercase().contains(&query))
            .cloned()
            .collect()
    }
}

pub fn run(client: &mut Client, multi: bool, playlist: Option<&str>, query: &str) -> Result<Vec<String>, String> {
    let mut picker =
        Picker { query: query.to_string(), multi, from_playlist: playlist.is_some(), ..Picker::default() };
    let all: Vec<Tune> = match playlist {
        Some(name) => client.get("playlist.show", json!({ "name": name }))?,
        None => Vec::new(),
    };
    let fetch = |client: &mut Client, picker: &mut Picker| -> Result<(), String> {
        picker.tunes = if picker.from_playlist {
            picker.shown(&all)
        } else if picker.query.is_empty() {
            Vec::new()
        } else {
            client.get("search", json!({ "text": picker.query, "limit": 100 }))?
        };
        picker.cursor = picker.cursor.min(picker.tunes.len().saturating_sub(1));
        Ok(())
    };
    fetch(client, &mut picker)?;

    enable_raw_mode().map_err(|e| e.to_string())?;
    let result = (|| -> std::io::Result<Option<Vec<String>>> {
        let mut terminal = Terminal::with_options(
            CrosstermBackend::new(std::io::stderr()),
            TerminalOptions { viewport: Viewport::Inline(HEIGHT) },
        )?;
        let mut due: Option<Instant> = None;
        let outcome = loop {
            terminal.draw(|frame| draw(frame, &picker))?;
            if event::poll(Duration::from_millis(40))? {
                if let Event::Key(key) = event::read()? {
                    if key.kind != KeyEventKind::Press {
                        continue;
                    }
                    match picker.key(key.code, key.modifiers.contains(KeyModifiers::CONTROL)) {
                        Outcome::Done => break Some(picker.chosen()),
                        Outcome::Cancelled => break None,
                        Outcome::QueryChanged => due = Some(Instant::now() + DEBOUNCE),
                        Outcome::Going => {}
                    }
                }
            }
            if due.is_some_and(|d| Instant::now() >= d) {
                due = None;
                // A failed search just leaves the last results up.
                let _ = fetch(client, &mut picker);
            }
        };
        terminal.clear()?;
        Ok(outcome)
    })();
    let _ = disable_raw_mode();
    match result.map_err(|e| e.to_string())? {
        Some(chosen) => Ok(chosen),
        None => Err("Nothing chosen.".into()),
    }
}

fn draw(frame: &mut ratatui::Frame, picker: &Picker) {
    let [input, list, hint] =
        Layout::vertical([Constraint::Length(1), Constraint::Min(1), Constraint::Length(1)]).areas(frame.area());
    frame.render_widget(Paragraph::new(format!("❯ {}▏", picker.query)), input);
    let items: Vec<ListItem> = picker
        .tunes
        .iter()
        .map(|t| {
            let mark = if picker.marked.contains(&t.path) { "✓ " } else { "  " };
            ListItem::new(Line::from(vec![
                Span::raw(mark),
                Span::raw(t.title.clone()),
                Span::styled(format!("  {}", t.author), palette::dim()),
            ]))
        })
        .collect();
    let mut state = ListState::default().with_selected(Some(picker.cursor));
    frame.render_stateful_widget(
        List::new(items).highlight_style(Style::new().bg(palette::selection())),
        list,
        &mut state,
    );
    let keys = if picker.multi { "↵ choose  ␣ mark  esc cancel" } else { "↵ choose  esc cancel" };
    frame.render_widget(Paragraph::new(keys).style(palette::dim()), hint);
    palette::paint(frame.buffer_mut());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tune(name: &str) -> Tune {
        Tune {
            path: format!("/{name}.sid"),
            title: name.into(),
            author: "Rob Hubbard".into(),
            released: "".into(),
            songs: 1,
            secs: None,
            score: None,
            played_at: None,
        }
    }

    fn picker(multi: bool) -> Picker {
        Picker { tunes: vec![tune("A"), tune("B"), tune("C")], multi, ..Picker::default() }
    }

    #[test]
    fn enter_chooses_the_cursor_without_marks() {
        let mut p = picker(false);
        p.key(KeyCode::Down, false);
        assert_eq!(p.chosen(), ["/B.sid"]);
    }

    #[test]
    fn space_marks_and_moves_on_in_multi() {
        let mut p = picker(true);
        p.key(KeyCode::Char(' '), false);
        p.key(KeyCode::Char(' '), false);
        assert_eq!(p.chosen(), ["/A.sid", "/B.sid"]);
    }

    #[test]
    fn space_is_a_letter_when_choosing_one() {
        let mut p = picker(false);
        assert!(matches!(p.key(KeyCode::Char(' '), false), Outcome::QueryChanged));
        assert_eq!(p.query, " ");
    }

    #[test]
    fn marks_outlast_the_search_that_showed_them() {
        let mut p = picker(true);
        p.key(KeyCode::Char(' '), false);
        p.tunes = vec![tune("Z")];
        assert_eq!(p.chosen(), ["/A.sid"]);
    }

    #[test]
    fn a_playlist_filters_by_title_or_composer() {
        let mut p = picker(false);
        p.query = "hubb".into();
        assert_eq!(p.shown(&[tune("A")]).len(), 1);
        p.query = "zzz".into();
        assert!(p.shown(&[tune("A")]).is_empty());
    }

    #[test]
    fn the_cursor_stays_on_the_list() {
        let mut p = picker(false);
        for _ in 0..9 {
            p.key(KeyCode::Down, false);
        }
        assert_eq!(p.cursor, 2);
        for _ in 0..9 {
            p.key(KeyCode::Up, false);
        }
        assert_eq!(p.cursor, 0);
    }

    #[test]
    fn escape_cancels() {
        assert!(matches!(picker(false).key(KeyCode::Esc, false), Outcome::Cancelled));
        assert!(matches!(picker(false).key(KeyCode::Char('c'), true), Outcome::Cancelled));
    }
}
