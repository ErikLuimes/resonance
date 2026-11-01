//! Headless Phosphor engine for the Resonance macOS app.
//!
//! The engine modules are compiled straight from the upstream sources in
//! `../../src` via `#[path]`, so they stay byte-identical with what the Iced
//! app builds and upstream merges never conflict. They sit at the crate root
//! under their upstream names because they refer to each other as
//! `crate::config`, `crate::player`, and so on.
//!
//! Only the software-emulation and HVSC-library paths are included. The USB
//! modules (`sid_direct`, `usb_bridge`, `daemon_installer`) are absent and the
//! `usb` feature is never enabled, so `sid_device::create_engine` can't reach
//! the bridge daemon or its osascript install prompt.

// ── Upstream engine sources ──────────────────────────────────────────────────

#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/audio_stream.rs"]
pub(crate) mod audio_stream;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/audio_volume.rs"]
pub(crate) mod audio_volume;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/c64_emu/mod.rs"]
pub(crate) mod c64_emu;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/config.rs"]
pub(crate) mod config;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/debug_log.rs"]
pub(crate) mod debug_log;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/dsp/mod.rs"]
pub(crate) mod dsp;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/favorites.rs"]
pub(crate) mod favorites;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/hvsc_browser.rs"]
pub(crate) mod hvsc_browser;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/hvsc_index_cache.rs"]
pub(crate) mod hvsc_index_cache;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/hvsc_sync.rs"]
pub(crate) mod hvsc_sync;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/player/mod.rs"]
pub(crate) mod player;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/playlist.rs"]
pub(crate) mod playlist;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/sid_device.rs"]
pub(crate) mod sid_device;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/sid_emulated.rs"]
pub(crate) mod sid_emulated;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/sid_sidlite.rs"]
pub(crate) mod sid_sidlite;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/sid_u64.rs"]
pub(crate) mod sid_u64;
#[allow(dead_code, unused, clippy::all)]
#[path = "../../../src/stil.rs"]
pub(crate) mod stil;

uniffi::setup_scaffolding!();

mod databases;
mod driver;
mod ffi;
mod library;
pub(crate) mod session;
mod viz;

pub use ffi::*;

// ── Stand-ins for items the engine sources borrow from the Iced app ─────────

pub(crate) mod ui {
    /// `player` and `sid_device` name `crate::ui::DeviceConfigSnapshot` in
    /// USB device-config signatures. Values are only ever built by the USB
    /// backends, which aren't compiled here, so an uninhabitable placeholder
    /// is enough and can't drift from the real struct.
    #[derive(Debug, Clone)]
    pub struct DeviceConfigSnapshot {
        _never: (),
    }

    /// `hvsc_browser` sorts with `crate::ui::SortDirection`. Same variants
    /// and derives as src/ui/mod.rs (its `flip`/`arrow` helpers are UI-only);
    /// if upstream changes the enum, hvsc_browser fails to compile here.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum SortDirection {
        Ascending,
        Descending,
    }
}

/// A `player` unit test calls `crate::parse_sid4_from_args()`, which lives in
/// the Iced app's main.rs. That test asserts the no-argument default.
#[cfg(test)]
pub(crate) fn parse_sid4_from_args() -> u16 {
    0
}
