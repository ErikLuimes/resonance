//! The core's logging, into macOS's unified log under the app's subsystem.
//! `oslog.c` does the writing.
//!
//! ```ignore
//! logging::error!(Category::Library, "saving learned song lengths: {e}");
//! ```
//!
//! The format string's literal text goes public and the filled-in message
//! private, so `log show` reads `saving learned song lengths: {e} <private>`
//! until private data is turned on. A message without arguments is public.

use std::ffi::{c_char, c_void, CString};
use std::fmt;
use std::sync::OnceLock;

pub(crate) const SUBSYSTEM: &str = "app.useresonance.resonance";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Category {
    Playback,
    Library,
    /// What the Phosphor sources in `src/` print.
    Core,
}

impl Category {
    const ALL: [Category; 3] = [Category::Playback, Category::Library, Category::Core];

    fn name(self) -> &'static str {
        match self {
            Category::Playback => "playback",
            Category::Library => "library",
            Category::Core => "core",
        }
    }
}

/// os_log_type_t's values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
#[allow(dead_code)]
pub(crate) enum Level {
    Debug = 0x02,
    Info = 0x01,
    Default = 0x00,
    Error = 0x10,
    Fault = 0x11,
}

extern "C" {
    fn resonance_log_create(subsystem: *const c_char, category: *const c_char) -> *mut c_void;
    fn resonance_log_enabled(log: *mut c_void, level: u8) -> bool;
    fn resonance_log(log: *mut c_void, level: u8, public_part: *const c_char, private_part: *const c_char);
}

/// An os_log_t: made once, never freed, and safe to use from any thread.
#[derive(Clone, Copy)]
struct Handle(*mut c_void);
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}

fn handle(category: Category) -> Handle {
    static HANDLES: OnceLock<[Handle; 3]> = OnceLock::new();
    let handles = HANDLES.get_or_init(|| {
        let subsystem = CString::new(SUBSYSTEM).unwrap();
        Category::ALL.map(|category| {
            let name = CString::new(category.name()).unwrap();
            Handle(unsafe { resonance_log_create(subsystem.as_ptr(), name.as_ptr()) })
        })
    });
    handles[Category::ALL.iter().position(|c| *c == category).unwrap()]
}

/// Whether anything listens at `level`, so a debug line costs no formatting
/// when nobody streams it.
pub(crate) fn enabled(category: Category, level: Level) -> bool {
    unsafe { resonance_log_enabled(handle(category).0, level as u8) }
}

/// One line. `template` is the format string, `message` it filled in.
pub(crate) fn write(category: Category, level: Level, template: &str, message: fmt::Arguments) {
    if !enabled(category, level) {
        return;
    }
    let (public, private) = split(template, message);
    let public = c_string(&public);
    let private = private.map(|text| c_string(&text));
    unsafe {
        resonance_log(
            handle(category).0,
            level as u8,
            public.as_ptr(),
            private.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
        );
    }
}

/// The public and private halves: a message with nothing filled in is all
/// public.
fn split(template: &str, message: fmt::Arguments) -> (String, Option<String>) {
    match message.as_str() {
        Some(text) => (text.to_owned(), None),
        None => (template.to_owned(), Some(message.to_string())),
    }
}

fn c_string(text: &str) -> CString {
    CString::new(text.replace('\0', "")).unwrap_or_default()
}

/// A line the Phosphor sources print (lib.rs routes their `eprintln!` here):
/// category `core`, at error when it says something failed, info otherwise,
/// so it's kept on disk with the error that follows it.
pub(crate) fn engine_line(template: &str, message: fmt::Arguments) {
    write(Category::Core, engine_level(template), template, message);
}

fn engine_level(template: &str) -> Level {
    let lower = template.to_lowercase();
    if ["fail", "error", "panic"].iter().any(|word| lower.contains(word)) {
        Level::Error
    } else {
        Level::Info
    }
}

macro_rules! log_at {
    ($level:expr, $category:expr, $fmt:literal $(, $($arg:tt)*)?) => {
        $crate::logging::write($category, $level, $fmt, ::std::format_args!($fmt $(, $($arg)*)?))
    };
}

#[allow(unused_macros)]
macro_rules! log_debug {
    ($($t:tt)*) => { $crate::logging::log_at!($crate::logging::Level::Debug, $($t)*) };
}
macro_rules! log_info {
    ($($t:tt)*) => { $crate::logging::log_at!($crate::logging::Level::Info, $($t)*) };
}
/// os_log's default level: something happened.
macro_rules! log_notice {
    ($($t:tt)*) => { $crate::logging::log_at!($crate::logging::Level::Default, $($t)*) };
}
macro_rules! log_error {
    ($($t:tt)*) => { $crate::logging::log_at!($crate::logging::Level::Error, $($t)*) };
}
macro_rules! log_fault {
    ($($t:tt)*) => { $crate::logging::log_at!($crate::logging::Level::Fault, $($t)*) };
}

#[allow(unused_imports)]
pub(crate) use {
    log_at, log_debug as debug, log_error as error, log_fault as fault, log_info as info,
    log_notice as notice,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_without_arguments_is_public() {
        assert_eq!(split("player thread exited", format_args!("player thread exited")), ("player thread exited".into(), None));
    }

    #[test]
    fn arguments_go_private_and_the_template_public() {
        let path = "/Users/someone/C64Music/Commando.sid";
        let e = "no such file";
        assert_eq!(
            split("skipping {}: {e}", format_args!("skipping {}: {e}", path)),
            ("skipping {}: {e}".into(), Some(format!("skipping {path}: {e}")))
        );
    }

    #[test]
    fn engine_lines_that_fail_are_errors() {
        assert_eq!(engine_level("[phosphor] libsidplayfp failed: {e}"), Level::Error);
        assert_eq!(engine_level("[sidlite] Audio error: {err}"), Level::Error);
        assert_eq!(engine_level("[phosphor] Engine switch → '{name}'"), Level::Info);
    }

    #[test]
    fn writing_from_tests_does_not_crash() {
        logging_smoke();
    }

    fn logging_smoke() {
        let n = 3;
        crate::logging::debug!(Category::Library, "smoke test {n}");
        crate::logging::notice!(Category::Core, "smoke test");
        engine_line("[test] {}", format_args!("[test] {}", 1));
        let _ = Level::Fault;
    }
}
