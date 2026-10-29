//! Session playlist persistence (main.rs `maybe_save_session` and the
//! session half of `playlist::parse_startup`).
//!
//! Uses the app's own M3U path rather than `Playlist::save_session` /
//! `load_session`, which hard-code the Iced app's
//! `phosphor/session_playlist.m3u` — the two apps must not overwrite each
//! other's playlist.

use std::path::{Path, PathBuf};

use crate::playlist::{self, LoadingProgress, Playlist, PlaylistEntry};

/// Write the playlist atomically (temp file + rename) so a crash mid-write
/// can't leave a truncated session. An empty playlist removes the file.
pub fn save(playlist: &Playlist, path: &Path) -> Result<(), String> {
    if playlist.is_empty() {
        match std::fs::remove_file(path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                return Err(format!("Cannot remove {}: {e}", path.display()))
            }
            _ => return Ok(()),
        }
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("Cannot create {}: {e}", dir.display()))?;
    }
    let tmp = tmp_path(path);
    playlist.save_m3u(&tmp)?;
    std::fs::rename(&tmp, path).map_err(|e| format!("Cannot replace {}: {e}", path.display()))
}

/// Read the saved session. `save_m3u` stores every header field (md5
/// included), so the skeleton parse rebuilds entries without opening a
/// single SID file; only entries missing an md5 are read from disk.
pub fn load(path: &Path, progress: LoadingProgress) -> Result<Vec<PlaylistEntry>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let base = path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let skeleton = playlist::parse_playlist_skeleton_with_base(path.to_path_buf(), base, progress)?;
    Ok(playlist::enrich_skeleton_entries(skeleton))
}

fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
}
