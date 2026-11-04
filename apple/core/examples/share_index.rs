//! Build the share server's tune index (see `share-server/`): every tune
//! in an HVSC collection with its title, author, released, lengths and,
//! from a fingerprint store, its sound traits.
//!
//!     cargo run -p phosphor-apple --release --example share_index -- \
//!         <HVSC folder> [fingerprints.sqlite] > index.json
//!
//! Use the published fingerprint set (fingerprints-x1.zip on the
//! `fingerprints` release) or a copy of the app's own store: opening the
//! file may convert it, so don't point it at the one the app is using.

use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(root) = args.first() else {
        eprintln!("usage: share_index <HVSC folder> [fingerprints.sqlite] > index.json");
        std::process::exit(2);
    };
    match phosphor_apple::build_share_index(Path::new(root), args.get(1).map(Path::new)) {
        Ok(index) => {
            let with_traits = index.tunes.values().filter(|t| !t.f.is_empty()).count();
            eprintln!(
                "HVSC {}: {} tunes, {with_traits} with traits",
                index.hvsc.map_or("?".into(), |v| v.to_string()),
                index.tunes.len()
            );
            serde_json::to_writer(std::io::stdout().lock(), &index).unwrap();
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
