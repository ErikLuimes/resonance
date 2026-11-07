#!/bin/bash
# Write Resonance/Acknowledgements.txt: the licences of the code built into
# the app, which About Resonance shows.
#
#   apple/scripts/acknowledgements.sh
#
# Covers every Rust crate linked into the core or the command line tool, which
# ships inside the app (from Cargo's dependency tree; build tools and macros,
# which don't ship, are left out) and every
# Swift package the app resolves from the internet (Package.resolved; the
# local STILKit is ours), each with its licence files. Crates and packages
# that share a licence text share one copy. Run it after changing
# dependencies, and commit the result.
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APPLE/Resonance/Acknowledgements.txt"
RESOLVED="$APPLE/Resonance.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGES="$APPLE/build/SourcePackages"
cd "$APPLE"

# The Swift packages' sources, for their licence files.
xcodebuild -resolvePackageDependencies -quiet -project Resonance.xcodeproj -scheme Resonance \
    -clonedSourcePackagesDirPath "$PACKAGES"

SHIPPED="$(mktemp)"
METADATA="$(mktemp)"
trap 'rm -f "$SHIPPED" "$METADATA"' EXIT
# The crates in the app and its tool: normal dependencies, no proc-macros.
cargo tree -p phosphor-apple -p resonance-cli -e normal --target aarch64-apple-darwin --prefix none --format '{p}' \
    | grep -v '(proc-macro)' | sed 's/ (\*)//' | awk '{print $1, $2}' | sort -u > "$SHIPPED"
cargo metadata --format-version 1 --filter-platform aarch64-apple-darwin > "$METADATA"

python3 -I - "$SHIPPED" "$METADATA" "$OUT" "$RESOLVED" "$PACKAGES/checkouts" <<'EOF'
import json, os, re, sys

shipped_file, metadata_file, out, resolved_file, checkouts = sys.argv[1:]
shipped = {tuple(line.split()) for line in open(shipped_file) if line.strip()}
packages = json.load(open(metadata_file))["packages"]

OURS = {"phosphor-apple", "phosphor-iced-shim", "resonance-cli"}
LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice)", re.I)

groups = {}   # licence text, normalised -> (text, crates and packages)

def add(label, folder, fallback):
    texts = []
    for name in sorted(os.listdir(folder)):
        path = os.path.join(folder, name)
        if LICENCE_FILE.match(name) and os.path.isfile(path):
            texts.append(open(path, encoding="utf-8", errors="replace").read().strip())
    text = "\n\n".join(texts) or fallback
    # Texts that differ only in line wrapping are one text.
    key = " ".join(text.split())
    groups.setdefault(key, (text, []))[1].append(label)

for p in sorted(packages, key=lambda p: (p["name"].lower(), p["version"])):
    if (p["name"], "v" + p["version"]) not in shipped or p["name"] in OURS:
        continue
    folder = os.path.dirname(p["manifest_path"])
    fallback = "(No licence file in the crate; its licence: %s)" % (p.get("license") or "unknown")
    if p.get("license_file") and not any(LICENCE_FILE.match(n) for n in os.listdir(folder)):
        fallback = open(os.path.join(folder, p["license_file"]), encoding="utf-8", errors="replace").read().strip()
    add("%s %s (%s)" % (p["name"], p["version"], p.get("license") or "see below"), folder, fallback)

# Swift packages: each pin's checkout is named after its repository.
crate_count = sum(len(c) for _, c in groups.values())
pins = json.load(open(resolved_file))["pins"]
for pin in sorted(pins, key=lambda p: p["identity"]):
    name = pin["location"].rstrip("/").split("/")[-1].removesuffix(".git")
    folder = os.path.join(checkouts, name)
    if not os.path.isdir(folder):
        sys.exit("No checkout of the %s package at %s" % (name, folder))
    add("%s %s (Swift package)" % (name, pin["state"].get("version") or pin["state"]["revision"][:7]),
        folder, "(No licence file in the package)")

rule = "-" * 72
with open(out, "w") as f:
    f.write("""Resonance includes the following open-source software.

Resonance's own code is MIT-licensed, and so is Phosphor, whose engine it
runs. The SID emulators it includes (reSID through resid-rs, SIDLite and
libsidplayfp) are GPL-licensed, so Resonance as built and distributed is
covered by the GNU General Public License, version 3. Its source code is
at https://github.com/ErikLuimes/resonance.

Sounds Like uses embeddings made in advance with MERT-v1-95M by Yizhi Li et
al. (https://huggingface.co/m-a-p/MERT-v1-95M), downloaded separately under the
CC BY-NC 4.0 licence (https://creativecommons.org/licenses/by-nc/4.0/). They
were reduced in size. The MERT model itself isn't part of Resonance.

The skull in the command line tool's terminal app is drawn with signed distance
functions following the work of Inigo Quilez (https://iquilezles.org/articles/).

The credits are a tribute to the demoscene, in the style of Crystal Dream II by
Triton (1993). Nothing from the demo is in Resonance. We forgive the PC.
""")
    for text, crates in sorted(groups.values(), key=lambda g: g[1][0].lower()):
        f.write("\n%s\n\n%s\n\n%s\n" % (rule, "\n".join(crates), text))
print("%d crates, %d Swift packages, %d licence texts -> %s (%d KB)" % (
    crate_count, len(pins), len(groups), out, os.path.getsize(out) // 1024))
EOF
