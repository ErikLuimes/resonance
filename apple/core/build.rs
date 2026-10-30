//! Bakes upstream Phosphor's version (`[package] version` in the root
//! Cargo.toml) into the crate as `PHOSPHOR_VERSION`. `CARGO_PKG_VERSION` is
//! this crate's own version, which upstream merges don't touch.

use std::path::Path;

fn main() {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Cargo.toml");
    println!("cargo:rerun-if-changed={}", manifest.display());
    let text = std::fs::read_to_string(&manifest)
        .unwrap_or_else(|e| panic!("can't read {}: {e}", manifest.display()));
    let version = package_version(&text).expect("no [package] version in Phosphor's Cargo.toml");
    println!("cargo:rustc-env=PHOSPHOR_VERSION={version}");
}

/// The quoted value of `version = "…"` in the `[package]` table.
fn package_version(toml: &str) -> Option<&str> {
    let mut in_package = false;
    for line in toml.lines().map(str::trim) {
        if line.starts_with('[') {
            in_package = line == "[package]";
        } else if in_package {
            if let Some(value) = line
                .strip_prefix("version")
                .and_then(|r| r.trim_start().strip_prefix('='))
            {
                return value.trim().strip_prefix('"')?.split('"').next();
            }
        }
    }
    None
}
