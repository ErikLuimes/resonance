//! The terminal app's key sets. Vim and Emacs turn their keys into the ones the
//! app already answers to, so everything else stays in one place. A flag or
//! `RESONANCE_KEYS` chooses; otherwise the editor you've set says which you're
//! used to; otherwise Emacs, as macOS's own text fields and shells have it.

use clap::ValueEnum;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

pub const ENV_VAR: &str = "RESONANCE_KEYS";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, ValueEnum)]
pub enum KeyScheme {
    /// The terminal app's own keys, with nothing added
    #[default]
    Normal,
    /// Adds h l, gg G, dd and the like
    Vim,
    /// Adds ⌃N ⌃P, ⌃F ⌃B, ⌃S and the like
    Emacs,
}

impl KeyScheme {
    pub fn name(self) -> &'static str {
        match self {
            KeyScheme::Normal => "Normal",
            KeyScheme::Vim => "Vim",
            KeyScheme::Emacs => "Emacs",
        }
    }

    /// What to show in this set: a key that differs between them.
    pub fn choose<T>(self, normal: T, vim: T, emacs: T) -> T {
        match self {
            KeyScheme::Normal => normal,
            KeyScheme::Vim => vim,
            KeyScheme::Emacs => emacs,
        }
    }

    fn parse(text: &str) -> Option<KeyScheme> {
        <KeyScheme as ValueEnum>::from_str(text.trim(), true).ok()
    }

    /// What an editor command is used to: `nvim`, `/usr/bin/vim -p`, `emacsclient -t`.
    fn of_editor(command: &str) -> Option<KeyScheme> {
        let program = command.split_whitespace().next()?;
        match program.rsplit('/').next()? {
            "vi" | "vim" | "nvim" | "gvim" | "mvim" | "lvim" | "vimx" => Some(KeyScheme::Vim),
            "emacs" | "emacsclient" => Some(KeyScheme::Emacs),
            _ => None,
        }
    }
}

/// The set in use, and how it came to be for the help screen to say.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Choice {
    pub scheme: KeyScheme,
    pub reason: &'static str,
}

impl Choice {
    pub fn resolve(flag: Option<KeyScheme>) -> Choice {
        Choice::from(flag, |name| std::env::var(name).ok())
    }

    fn from(flag: Option<KeyScheme>, env: impl Fn(&str) -> Option<String>) -> Choice {
        if let Some(scheme) = flag {
            return Choice { scheme, reason: "chosen with --keys" };
        }
        if let Some(scheme) = env(ENV_VAR).and_then(|value| KeyScheme::parse(&value)) {
            return Choice { scheme, reason: "from RESONANCE_KEYS" };
        }
        for (name, reason) in [("VISUAL", "from $VISUAL"), ("EDITOR", "from $EDITOR")] {
            if let Some(scheme) = env(name).and_then(|value| KeyScheme::of_editor(&value)) {
                return Choice { scheme, reason };
            }
        }
        Choice { scheme: KeyScheme::Emacs, reason: "the default on a Mac" }
    }
}

/// Follows the keys pressed, as Vim's take two presses.
#[derive(Debug, Default)]
pub struct KeyMap {
    pub scheme: KeyScheme,
    pending: Option<char>,
}

impl KeyMap {
    pub fn new(scheme: KeyScheme) -> KeyMap {
        KeyMap { scheme, pending: None }
    }

    /// The key the app knows this as. None while waiting for a second press.
    pub fn translate(&mut self, key: KeyEvent) -> Option<KeyEvent> {
        match self.scheme {
            KeyScheme::Normal => Some(key),
            KeyScheme::Vim => self.vim(key),
            KeyScheme::Emacs => Some(emacs(key)),
        }
    }

    fn vim(&mut self, key: KeyEvent) -> Option<KeyEvent> {
        let plain = !key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT);
        let first = self.pending.take();
        if let (KeyCode::Char(c @ ('g' | 'd')), true) = (key.code, plain) {
            if first == Some(c) {
                return Some(if c == 'g' { named(KeyCode::Home) } else { named(KeyCode::Char('x')) });
            }
            self.pending = Some(c);
            return None;
        }
        let code = match key.code {
            KeyCode::Char('h') if plain => KeyCode::Left,
            KeyCode::Char('l') if plain => KeyCode::Right,
            KeyCode::Char('G') if plain => KeyCode::End,
            // Their own keys moved aside for the above.
            KeyCode::Char('L') if plain => KeyCode::Char('l'),
            KeyCode::Char('D') if plain => KeyCode::Char('d'),
            KeyCode::Char('d' | 'f') if !plain => KeyCode::PageDown,
            KeyCode::Char('u' | 'b') if !plain => KeyCode::PageUp,
            _ => return Some(key),
        };
        Some(named(code))
    }
}

fn emacs(key: KeyEvent) -> KeyEvent {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    let code = match key.code {
        KeyCode::Char('n') if ctrl => KeyCode::Down,
        KeyCode::Char('p') if ctrl => KeyCode::Up,
        KeyCode::Char('f') if ctrl => KeyCode::Right,
        KeyCode::Char('b') if ctrl => KeyCode::Left,
        KeyCode::Char('v') if ctrl => KeyCode::PageDown,
        KeyCode::Char('v') if alt => KeyCode::PageUp,
        KeyCode::Char('<') if alt => KeyCode::Home,
        KeyCode::Char('>') if alt => KeyCode::End,
        KeyCode::Char('s') if ctrl => KeyCode::Char('/'),
        KeyCode::Char('d') if ctrl => KeyCode::Char('x'),
        KeyCode::Char('g') if ctrl => KeyCode::Esc,
        _ => return key,
    };
    named(code)
}

fn named(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

/// Typing into a line, the way a shell does it in every key set: ⌃U clears, ⌃W
/// takes a word, ⌃H takes a letter. True if the line changed.
pub fn edit_line(text: &mut String, key: KeyEvent) -> bool {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    match key.code {
        KeyCode::Backspace => text.pop().is_some(),
        KeyCode::Char('h') if ctrl => text.pop().is_some(),
        KeyCode::Char('u') if ctrl => {
            let had = !text.is_empty();
            text.clear();
            had
        }
        KeyCode::Char('w') if ctrl => {
            let had = !text.is_empty();
            let kept = text.trim_end().trim_end_matches(|c: char| !c.is_whitespace()).len();
            text.truncate(kept);
            had
        }
        KeyCode::Char(c) if !ctrl && !alt => {
            text.push(c);
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn choice(flag: Option<KeyScheme>, vars: &[(&str, &str)]) -> Choice {
        let vars: HashMap<String, String> = vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        Choice::from(flag, |name| vars.get(name).cloned())
    }

    fn key(code: KeyCode) -> KeyEvent {
        named(code)
    }

    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    fn alt(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::ALT)
    }

    #[test]
    fn the_default_on_a_mac_is_emacs() {
        assert_eq!(choice(None, &[]).scheme, KeyScheme::Emacs);
        assert_eq!(choice(None, &[("EDITOR", "nano")]).scheme, KeyScheme::Emacs);
    }

    #[test]
    fn the_editor_says_what_you_are_used_to() {
        for editor in ["vi", "vim", "nvim", "/opt/homebrew/bin/nvim", "vim -p"] {
            assert_eq!(choice(None, &[("EDITOR", editor)]).scheme, KeyScheme::Vim, "{editor}");
        }
        assert_eq!(choice(None, &[("EDITOR", "emacsclient -t")]).scheme, KeyScheme::Emacs);
        assert_eq!(choice(None, &[("EDITOR", "nvim")]).reason, "from $EDITOR");
    }

    #[test]
    fn visual_comes_before_editor_unless_it_says_nothing() {
        let both = [("VISUAL", "emacs"), ("EDITOR", "nvim")];
        assert_eq!(choice(None, &both).scheme, KeyScheme::Emacs);
        let gui = [("VISUAL", "code --wait"), ("EDITOR", "nvim")];
        assert_eq!(choice(None, &gui).scheme, KeyScheme::Vim);
    }

    #[test]
    fn asking_beats_guessing() {
        let vars = [("RESONANCE_KEYS", "normal"), ("EDITOR", "nvim")];
        assert_eq!(choice(None, &vars).scheme, KeyScheme::Normal);
        assert_eq!(choice(Some(KeyScheme::Emacs), &vars).scheme, KeyScheme::Emacs);
    }

    #[test]
    fn the_variable_ignores_case_and_a_value_it_does_not_know() {
        assert_eq!(choice(None, &[("RESONANCE_KEYS", "VIM")]).scheme, KeyScheme::Vim);
        assert_eq!(choice(None, &[("RESONANCE_KEYS", "dvorak"), ("EDITOR", "nvim")]).scheme, KeyScheme::Vim);
    }

    #[test]
    fn normal_changes_nothing() {
        let mut map = KeyMap::new(KeyScheme::Normal);
        for pressed in [key(KeyCode::Char('l')), key(KeyCode::Char('g')), ctrl('n')] {
            assert_eq!(map.translate(pressed), Some(pressed));
        }
    }

    #[test]
    fn vim_takes_two_presses_for_gg_and_dd() {
        let mut map = KeyMap::new(KeyScheme::Vim);
        assert_eq!(map.translate(key(KeyCode::Char('g'))), None);
        assert_eq!(map.translate(key(KeyCode::Char('g'))), Some(key(KeyCode::Home)));
        assert_eq!(map.translate(key(KeyCode::Char('d'))), None);
        assert_eq!(map.translate(key(KeyCode::Char('d'))), Some(key(KeyCode::Char('x'))));
    }

    #[test]
    fn vim_forgets_a_first_press_when_another_key_follows() {
        let mut map = KeyMap::new(KeyScheme::Vim);
        assert_eq!(map.translate(key(KeyCode::Char('d'))), None);
        assert_eq!(map.translate(key(KeyCode::Char('j'))), Some(key(KeyCode::Char('j'))));
        assert_eq!(map.translate(key(KeyCode::Char('d'))), None);
        assert_eq!(map.translate(key(KeyCode::Char('g'))), None);
        assert_eq!(map.translate(key(KeyCode::Char('d'))), None);
    }

    #[test]
    fn vim_moves_the_keys_it_takes_over_aside() {
        let mut map = KeyMap::new(KeyScheme::Vim);
        assert_eq!(map.translate(key(KeyCode::Char('l'))), Some(key(KeyCode::Right)));
        assert_eq!(map.translate(key(KeyCode::Char('L'))), Some(key(KeyCode::Char('l'))));
        assert_eq!(map.translate(key(KeyCode::Char('D'))), Some(key(KeyCode::Char('d'))));
        assert_eq!(map.translate(ctrl('d')), Some(key(KeyCode::PageDown)));
        assert_eq!(map.translate(ctrl('u')), Some(key(KeyCode::PageUp)));
    }

    #[test]
    fn emacs_keys_become_the_apps_own() {
        let mut map = KeyMap::new(KeyScheme::Emacs);
        assert_eq!(map.translate(ctrl('n')), Some(key(KeyCode::Down)));
        assert_eq!(map.translate(ctrl('p')), Some(key(KeyCode::Up)));
        assert_eq!(map.translate(ctrl('s')), Some(key(KeyCode::Char('/'))));
        assert_eq!(map.translate(alt('v')), Some(key(KeyCode::PageUp)));
        assert_eq!(map.translate(alt('<')), Some(key(KeyCode::Home)));
        // The app's plain letters stay as they are.
        let letter = key(KeyCode::Char('l'));
        assert_eq!(map.translate(letter), Some(letter));
    }

    #[test]
    fn a_line_edits_like_a_shell_and_ignores_other_chords() {
        let mut line = String::from("last ninja  ");
        assert!(edit_line(&mut line, ctrl('w')));
        assert_eq!(line, "last ");
        assert!(edit_line(&mut line, ctrl('h')));
        assert_eq!(line, "last");
        assert!(!edit_line(&mut line, ctrl('n')));
        assert!(!edit_line(&mut line, alt('v')));
        assert_eq!(line, "last");
        assert!(edit_line(&mut line, ctrl('u')));
        assert!(line.is_empty());
        assert!(!edit_line(&mut line, ctrl('u')));
    }
}
