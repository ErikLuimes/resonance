//! The curated playlists (Phosphor's published playlists), from Resonance's
//! own repository rather than Phosphor's: the same `playlists/` folder, which
//! merges in from upstream, so Resonance doesn't depend on another project's
//! repository at run time. The app also ships a copy, which seeds the cache
//! on the first launch, offline included.
//!
//! Upstream's `PublishedPlaylistsClient` has Phosphor's address built in, so
//! this is a small client of its own; the cache folder and the manifest
//! format are upstream's.

use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use crate::published_playlists::Manifest;

/// The `playlists/` folder at the top of Resonance's repository.
const BASE_URL: &str = "https://raw.githubusercontent.com/ErikLuimes/resonance/main/playlists";

/// Copy the app's bundled playlists into `dir` when it has none yet (no
/// `index.json`). Never overwrites: a synced set is newer than the bundle.
/// Returns whether it copied anything.
pub(crate) fn seed(bundled: &Path, dir: &Path) -> std::io::Result<bool> {
    if dir.join("index.json").exists() || !bundled.join("index.json").exists() {
        return Ok(false);
    }
    std::fs::create_dir_all(dir)?;
    // The playlists first and the index last, as a sync writes them: an
    // interrupted copy leaves no index, and is redone.
    for entry in std::fs::read_dir(bundled)? {
        let path = entry?.path();
        if path.extension().is_some_and(|e| e == "m3u") {
            if let Some(name) = path.file_name() {
                std::fs::copy(&path, dir.join(name))?;
            }
        }
    }
    std::fs::copy(bundled.join("index.json"), dir.join("index.json"))?;
    Ok(true)
}

/// Bring `dir` up to date with the published index: download the playlists
/// that are new or changed (by the index's checksum), then write the index.
/// Returns how many playlists were downloaded.
pub(crate) async fn sync(dir: &Path) -> Result<u32, String> {
    let builder = reqwest::Client::builder()
        .user_agent("Resonance")
        .timeout(Duration::from_secs(30));
    let http = crate::config::apply_proxy(builder).build().map_err(|e| e.to_string())?;

    let manifest: Manifest = serde_json::from_slice(&get(&http, "index.json").await?)
        .map_err(|e| format!("The playlist index isn't valid: {e}"))?;
    let index = dir.join("index.json");
    let previous: HashMap<String, String> = std::fs::read(&index)
        .ok()
        .and_then(|b| serde_json::from_slice::<Manifest>(&b).ok())
        .map(|m| m.playlists.into_iter().map(|p| (p.file, p.sha256)).collect())
        .unwrap_or_default();

    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let mut downloaded = 0;
    for entry in &manifest.playlists {
        // A plain file name: never a path out of the folder.
        if entry.file.contains('/') || entry.file.starts_with('.') {
            continue;
        }
        let current = dir.join(&entry.file).exists() && previous.get(&entry.file) == Some(&entry.sha256);
        if !current {
            let body = get(&http, &entry.file).await?;
            std::fs::write(dir.join(&entry.file), body).map_err(|e| e.to_string())?;
            downloaded += 1;
        }
    }
    let json = serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?;
    std::fs::write(&index, json).map_err(|e| e.to_string())?;
    Ok(downloaded)
}

async fn get(http: &reqwest::Client, file: &str) -> Result<Vec<u8>, String> {
    let url = format!("{BASE_URL}/{}", file.replace(' ', "%20"));
    let response = http
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Couldn't reach GitHub: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("{file}: {}", response.status()));
    }
    Ok(response.bytes().await.map_err(|e| e.to_string())?.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("resonance-curated-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_bundled_set_seeds_an_empty_cache_only() {
        let bundled = folder("bundled");
        std::fs::write(bundled.join("index.json"), r#"{"version":1,"playlists":[]}"#).unwrap();
        std::fs::write(bundled.join("A.m3u"), "MUSICIANS/a.sid\n").unwrap();
        std::fs::write(bundled.join("notes.txt"), "not a playlist").unwrap();
        let cache = folder("cache").join("published_playlists");

        assert!(seed(&bundled, &cache).unwrap());
        assert!(cache.join("index.json").exists());
        assert!(cache.join("A.m3u").exists());
        assert!(!cache.join("notes.txt").exists());

        // A synced set is newer than the bundle: left alone.
        std::fs::write(cache.join("A.m3u"), "MUSICIANS/b.sid\n").unwrap();
        assert!(!seed(&bundled, &cache).unwrap());
        assert_eq!(std::fs::read_to_string(cache.join("A.m3u")).unwrap(), "MUSICIANS/b.sid\n");
    }

    #[test]
    fn no_bundled_index_seeds_nothing() {
        let bundled = folder("empty");
        let cache = folder("cache2").join("published_playlists");
        assert!(!seed(&bundled, &cache).unwrap());
        assert!(!cache.exists());
    }
}
