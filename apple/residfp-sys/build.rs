//! Compiles the vendored libsidplayfp (player, sidtune, C64, residfp
//! builder) and libresidfp into one static library with the C shim.
//!
//! `sidplayfp-sys`, which the fingerprint scan uses, compiles its own copy of
//! libsidplayfp (3.0.0). Two archives defining the same C++ symbols would
//! make the final link pick object files from either at random, so every
//! class and namespace that libsidplayfp declares at global scope is renamed
//! here with `-D` (the `libsidplayfp` namespace becomes `rsfp_libsidplayfp`,
//! `SidTune` becomes `RsfpSidTune`, and so on). The sources are untouched;
//! `cargo test -p residfp-sys` checks that no symbol escaped the renaming.

use std::env;
use std::path::PathBuf;

/// (upstream name, name in this crate). Only what isn't inside a namespace
/// that is itself renamed, plus the two namespaces.
const RENAMES: &[(&str, &str)] = &[
    ("libsidplayfp", "rsfp_libsidplayfp"),
    ("reSIDfp", "rsfp_reSIDfp"),
    ("sidplayfp", "rsfp_sidplayfp"),
    ("SidTune", "RsfpSidTune"),
    ("SidTuneInfo", "RsfpSidTuneInfo"),
    ("SidConfig", "RsfpSidConfig"),
    ("SidInfo", "RsfpSidInfo"),
    ("SidInfoImpl", "RsfpSidInfoImpl"),
    ("sidbuilder", "rsfp_sidbuilder"),
    ("ReSIDfpBuilder", "RsfpReSIDfpBuilder"),
    ("reloc65", "rsfp_reloc65"),
    ("residfp_version_string", "rsfp_residfp_version_string"),
    // Header-only MD5, also compiled into sidplayfp-sys.
    ("hashlib", "rsfp_hashlib"),
    // A global array in SidTune.cpp.
    ("defaultFileNameExt", "rsfp_defaultFileNameExt"),
    // SIDLite's chip, also compiled into sidlite-sys.
    ("SIDLite", "rsfp_SIDLite"),
];

const SIDPLAYFP_VERSION: (u32, u32, u32) = (3, 1, 2);
const RESIDFP_VERSION: (u32, u32, u32) = (1, 2, 3);

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let fp = manifest.join("csrc/libsidplayfp");
    let re = manifest.join("csrc/libresidfp");

    // ── Generated headers (what configure would write) ──
    let (maj, min, lev) = SIDPLAYFP_VERSION;
    std::fs::write(
        out.join("config.h"),
        format!(
            "#ifndef CONFIG_H\n#define CONFIG_H\n\
             #define VERSION \"{maj}.{min}.{lev}\"\n\
             #define PACKAGE \"libsidplayfp\"\n\
             #define PACKAGE_NAME \"libsidplayfp\"\n\
             #define PACKAGE_VERSION \"{maj}.{min}.{lev}\"\n\
             #define PACKAGE_URL \"https://github.com/libsidplayfp/libsidplayfp\"\n\
             #define HAVE_CXX11 1\n#define HAVE_CXX14 1\n#define HAVE_CXX17 1\n\
             #define HAVE_RESIDFP 1\n\
             #define HAVE_STRCASECMP 1\n#define HAVE_STRNCASECMP 1\n\
             #define HAVE_BUILTIN_EXPECT 1\n\
             #endif\n"
        ),
    )
    .expect("write config.h");
    std::fs::create_dir_all(out.join("sidplayfp")).unwrap();
    std::fs::write(
        out.join("sidplayfp/sidversion.h"),
        format!(
            "#ifndef LIBSIDPLAYFP_VERSION_H\n#define LIBSIDPLAYFP_VERSION_H\n\
             #define LIBSIDPLAYFP_VERSION_MAJ {maj}\n\
             #define LIBSIDPLAYFP_VERSION_MIN {min}\n\
             #define LIBSIDPLAYFP_VERSION_LEV {lev}\n#endif\n"
        ),
    )
    .expect("write sidversion.h");
    let (rmaj, rmin, rlev) = RESIDFP_VERSION;
    std::fs::create_dir_all(out.join("residfp")).unwrap();
    std::fs::write(
        out.join("residfp/sidversion.h"),
        format!(
            "#ifndef LIBRESIDFP_VERSION_H\n#define LIBRESIDFP_VERSION_H\n\
             #define LIBRESIDFP_VERSION_MAJ {rmaj}\n\
             #define LIBRESIDFP_VERSION_MIN {rmin}\n\
             #define LIBRESIDFP_VERSION_LEV {rlev}\n#endif\n"
        ),
    )
    .expect("write residfp/sidversion.h");
    let siddefs = std::fs::read_to_string(re.join("siddefs-fp.h.in")).expect("siddefs-fp.h.in");
    std::fs::write(
        out.join("siddefs-fp.h"),
        siddefs
            .replace("@RESIDFP_BRANCH_HINTS@", "1")
            .replace("@HAVE_BUILTIN_EXPECT@", "1")
            .replace("@PACKAGE_VERSION@", &format!("{rmaj}.{rmin}.{rlev}"))
            .replace("@RESIDFP_INLINING@", "1")
            .replace("@RESIDFP_INLINE@", "inline"),
    )
    .expect("write siddefs-fp.h");
    let sl_defs = std::fs::read_to_string(fp.join("builders/sidlite-builder/sidlite/sl_defs.h.in"))
        .expect("sl_defs.h.in");
    std::fs::write(
        out.join("sl_defs.h"),
        sl_defs.replace("@HAVE_BUILTIN_EXPECT@", "1"),
    )
    .expect("write sl_defs.h");

    let configure = |build: &mut cc::Build| {
        build
            .cpp(true)
            .std("c++17")
            // The emulation runs in the audio callback: full optimization
            // in every profile (a workspace member would get -O1 in dev).
            .opt_level(3)
            .warnings(false)
            .define("HAVE_CONFIG_H", None)
            .define("NDEBUG", None)
            .include(&out)
            .include(&fp)
            .include(&re)
            .include(fp.join("builders/sidlite-builder"))
            .include(&manifest);
        for (from, to) in RENAMES {
            build.define(from, Some(*to));
        }
    };

    // ── libresidfp ──
    let mut residfp = cc::Build::new();
    configure(&mut residfp);
    // Upstream's configure adds these for the emulation core.
    residfp
        .flag("-ffast-math")
        .flag("-fno-unsafe-math-optimizations");
    for f in [
        "Dac.cpp",
        "EnvelopeGenerator.cpp",
        "ExternalFilter.cpp",
        "Filter.cpp",
        "Filter6581.cpp",
        "Filter8580.cpp",
        "FilterModelConfig.cpp",
        "FilterModelConfig6581.cpp",
        "FilterModelConfig8580.cpp",
        "Integrator6581.cpp",
        "Integrator8580.cpp",
        "OpAmp.cpp",
        "SID.cpp",
        "Spline.cpp",
        "State.cpp",
        "WaveformCalculator.cpp",
        "WaveformGenerator.cpp",
        "resample/SincResampler.cpp",
        "version.cc",
        "residfp/residfp.cpp",
    ] {
        residfp.file(re.join(f));
    }
    residfp.compile("rsfp_residfp");

    // ── libsidplayfp + shim ──
    let mut player = cc::Build::new();
    configure(&mut player);
    for f in [
        "EventScheduler.cpp",
        "player.cpp",
        "psiddrv.cpp",
        "reloc65.cpp",
        "sidemu.cpp",
        "simpleMixer.cpp",
        "sidplayfp/SidConfig.cpp",
        "sidplayfp/SidInfo.cpp",
        "sidplayfp/SidTune.cpp",
        "sidplayfp/SidTuneInfo.cpp",
        "sidplayfp/sidbuilder.cpp",
        "sidplayfp/sidplayfp.cpp",
        "sidtune/MUS.cpp",
        "sidtune/PSID.cpp",
        "sidtune/SidTuneBase.cpp",
        "sidtune/SidTuneTools.cpp",
        "sidtune/p00.cpp",
        "sidtune/prg.cpp",
        "c64/c64.cpp",
        "c64/mmu.cpp",
        "c64/CPU/mos6510.cpp",
        "c64/CPU/mos6510debug.cpp",
        "c64/CIA/SerialPort.cpp",
        "c64/CIA/interrupt.cpp",
        "c64/CIA/mos652x.cpp",
        "c64/CIA/timer.cpp",
        "c64/CIA/tod.cpp",
        "c64/VIC_II/mos656x.cpp",
        "builders/residfp-builder/residfp-builder.cpp",
        "builders/residfp-builder/residfp-emu.cpp",
        // SIDLite's chip only; the shim has its own emu and builder.
        "builders/sidlite-builder/sidlite/ADSR.cpp",
        "builders/sidlite-builder/sidlite/Filter.cpp",
        "builders/sidlite-builder/sidlite/SID.cpp",
        "builders/sidlite-builder/sidlite/WavGen.cpp",
    ] {
        player.file(fp.join(f));
    }
    player.file(manifest.join("shim.cpp"));
    player.compile("rsfp_player");

    println!("cargo:rerun-if-changed=shim.cpp");
    println!("cargo:rerun-if-changed=shim.h");
    println!("cargo:rerun-if-changed=csrc");
    #[cfg(target_os = "macos")]
    println!("cargo:rustc-link-lib=c++");
    #[cfg(target_os = "linux")]
    println!("cargo:rustc-link-lib=stdc++");
}
