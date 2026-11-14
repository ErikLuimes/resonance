//! Gives `resonance-mcp` an Info.plist of its own: the App Sandbox needs one
//! to know a command line tool's bundle ID, and traps at launch without it.

fn main() {
    let plist = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("mcp-Info.plist");
    println!("cargo:rerun-if-changed={}", plist.display());
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg-bin=resonance-mcp=-Wl,-sectcreate,__TEXT,__info_plist,{}", plist.display());
    }
}
