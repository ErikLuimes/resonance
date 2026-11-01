#!/usr/bin/env python3
"""Writes apple/site/js/hvsc-tunes.js: the website demo's tunes, with what
Resonance's inspector shows for each — header fields, Songlengths, STIL's
notes on the tune and on its composer.

    python3 apple/scripts/site-demo-tunes.py [HVSC folder]

The HVSC folder defaults to Phosphor's (~/Library/Application
Support/phosphor/HVSC); STIL and Songlengths come from its DOCUMENTS
folder. The page plays a stand-in for each tune, so no SID data is copied.
"""

import hashlib
import json
import re
import struct
import sys
import unicodedata
from pathlib import Path

# The playlist's tunes first, in its order, then more for Surprise Me.
PLAYLIST = [
    "H/Hubbard_Rob/Commando",
    "H/Hubbard_Rob/Monty_on_the_Run",
    "H/Hubbard_Rob/Sanxion",
    "G/Galway_Martin/Parallax",
    "H/Hubbard_Rob/International_Karate",
    "H/Huelsbeck_Chris/Shades",
    "H/Hubbard_Rob/Spellbound",
    "T/Tel_Jeroen/Cybernoid_II",
    "G/Gray_Matt/Last_Ninja_2",
    "T/Tel_Jeroen/Supremacy",
]
MORE = [
    "H/Hubbard_Rob/Delta",
    "H/Hubbard_Rob/Lightforce",
    "H/Hubbard_Rob/Thing_on_a_Spring",
    "H/Hubbard_Rob/Warhawk",
    "H/Hubbard_Rob/Zoids",
    "H/Hubbard_Rob/Crazy_Comets",
    "H/Hubbard_Rob/Master_of_Magic",
    "H/Hubbard_Rob/One_Man_and_his_Droid",
    "G/Galway_Martin/Wizball",
    "G/Galway_Martin/Times_of_Lore",
    "G/Galway_Martin/Rambo_First_Blood_Part_II",
    "G/Galway_Martin/Comic_Bakery",
    "G/Galway_Martin/Arkanoid",
    "G/Galway_Martin/Green_Beret",
    "H/Huelsbeck_Chris/Great_Giana_Sisters",
    "H/Huelsbeck_Chris/R-Type",
    "H/Huelsbeck_Chris/Katakis",
    "T/Tel_Jeroen/Myth",
    "G/Gray_Matt/Driller",
    "G/Gray_Matt/Tusker",
    "D/Daglish_Ben/Last_Ninja",
    "D/Daglish_Ben/Deflektor",
    "D/Daglish_Ben/Gauntlet",
    "F/Follin_Tim/Agent_X_II_The_Mad_Profs_Back",
    "F/Follin_Tim/Bionic_Commando",
    "F/Follin_Tim/Ghouls_n_Ghosts",
    "G/Gray_Fred/Mutants",
    "D/Dunn_Jonathan/Platoon",
    "D/Dunn_Jonathan/RoboCop",
    "O/Ouwehand_Reyn/Last_Ninja_3",
]

OUT = Path(__file__).resolve().parents[1] / "site" / "js" / "hvsc-tunes.js"


# --- SID header -------------------------------------------------------------

def header(data):
    magic = data[0:4].decode("ascii")
    version, = struct.unpack(">H", data[4:6])
    songs, start = struct.unpack(">HH", data[14:18])
    text = lambda a: data[a:a + 32].split(b"\0")[0].decode("latin-1").strip()
    flags = struct.unpack(">H", data[0x76:0x78])[0] if version >= 2 else 0
    chips = 1
    if version >= 3 and data[0x7A]:
        chips += 1
    if version >= 4 and data[0x7B]:
        chips += 1
    return {
        "title": text(0x16),
        "author": text(0x36),
        "released": text(0x56),
        "songs": songs,
        "start": start,
        "format": magic,
        # 1 6581, 2 8580, 3 either, 0 unknown, as the app's inspector reads it.
        "sid": (flags >> 4) & 3,
        "pal": (flags >> 2) & 3 != 2,
        "chips": chips,
    }


# --- Songlengths ------------------------------------------------------------

def songlengths(path):
    lengths = {}
    current = None
    for line in path.read_text(encoding="latin-1").splitlines():
        if line.startswith("; /"):
            current = line[2:].strip()
        elif "=" in line and current:
            md5, times = line.split("=", 1)
            lengths[current] = (md5.strip(), [seconds(t) for t in times.split()])
            current = None
    return lengths


def seconds(time):
    time = re.sub(r"\(.*\)", "", time)
    minutes, secs = time.split(":")
    return round(int(minutes) * 60 + float(secs))


# --- STIL, parsed like upstream's src/stil.rs --------------------------------

FIELDS = ("NAME", "AUTHOR", "TITLE", "ARTIST", "COMMENT")


def stil_entries(path):
    entries = {}
    entry = block = field = None

    def flush_block():
        nonlocal block
        if block and any(block.get(f) for f in FIELDS):
            entry["blocks"].append(block)
        block = None

    for line in path.read_text(encoding="latin-1").splitlines():
        if line.startswith("#"):
            field = None
            continue
        if line.startswith("/") and line.strip():
            if entry:
                flush_block()
            entry = {"comment": None, "blocks": []}
            entries[line.strip().lower()] = entry
            block = field = None
            continue
        if entry is None:
            continue
        trimmed = line.strip()
        if trimmed.startswith("(#") and trimmed.endswith(")"):
            flush_block()
            block = {"subtune": int(trimmed[2:-1])}
            field = None
            continue
        match = re.match(r"(NAME|AUTHOR|TITLE|ARTIST|COMMENT):(.*)", trimmed)
        if match:
            field, value = match.group(1), match.group(2).strip()
            if field == "COMMENT" and block is None:
                target, key = entry, "comment"
            else:
                block = block or {"subtune": 0}
                target, key = block, field
            target[key] = value if target.get(key) is None else target[key] + "\n" + value
            continue
        if trimmed and field:
            target = entry if field == "COMMENT" and block is None else block
            key = "comment" if target is entry else field
            if target is not None and target.get(key) is not None:
                target[key] += "\n" + trimmed
            continue
        if not trimmed:
            field = None
    if entry:
        flush_block()
    return entries


# Undo STIL's hard wrapping, like the app (apple/core/src/databases.rs).
STIL_TEXT_WIDTH = 71


def reflow(text):
    if text is None:
        return None
    out, last = "", None
    for line in (l.rstrip() for l in text.splitlines()):
        if last is None:
            out = line
        elif is_wrap(last, line):
            out += " " + line.lstrip()
        else:
            out += "\n" + line
        last = line
    return out if out.strip() else None


def is_wrap(prev, nxt):
    words = nxt.split()
    if not words:
        return False
    if len(prev) + 1 + len(words[0]) > STIL_TEXT_WIDTH:
        return True
    ends_sentence = prev.endswith((".", "!", "?", ":", '"', "'", ")", "]"))
    return not ends_sentence and (len(prev) >= 40 or nxt.startswith("/"))


def stil_notes(entry):
    if not entry:
        return None
    blocks = []
    for b in entry["blocks"]:
        block = {"subtune": b["subtune"]}
        for field in FIELDS:
            value = reflow(b.get(field))
            if value:
                block[field.lower()] = value
        if len(block) > 1:
            blocks.append(block)
    comment = reflow(entry["comment"])
    if not comment and not blocks:
        return None
    notes = {"blocks": blocks}
    if comment:
        notes = {"comment": comment, **notes}
    return notes


# --- The composer card, named like LibraryStore.composer(of:) -----------------

def words(name):
    folded = unicodedata.normalize("NFD", name.lower())
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    return frozenset(w for w in re.split(r"[^\w]|_", folded) if w)


def credit(author):
    handles, base, handle, depth = [], "", "", 0
    for c in author:
        if c == "(":
            depth += 1
        elif c == ")" and depth > 0:
            depth -= 1
            if depth == 0:
                handles.append(handle)
                handle = ""
        elif depth > 0:
            handle += c
        else:
            base += c
    return base, handles


def people(base):
    parts = re.split(r"[&,/]", base.replace(" and ", "&"))
    return [p.strip() for p in parts if p.strip()]


def names(author):
    base, handles = credit(author)
    seen, out = set(), []
    for name in [base] + people(base) + handles:
        name = name.strip()
        key = words(name)
        if key and key not in seen:
            seen.add(key)
            out.append(name)
    return out


def subtitle(name, author):
    key = words(name)
    base, handles = credit(author)
    folks = people(base)
    if any(words(h) == key for h in handles):
        return folks[0] if len(folks) == 1 else None
    index = next((i for i, p in enumerate(folks) if words(p) == key), None)
    if index is None:
        return None
    if len(folks) > 1:
        others = folks[:index] + folks[index + 1:]
        return "with " + (others[0] if len(others) == 1 else ", ".join(others[:-1]) + " and " + others[-1])
    return handles[0] if len(handles) == 1 else None


def spoken_name(folder):
    # derive_display_name in upstream's hvsc_browser.rs, then spokenName.
    parts = folder.split("_")
    if len(parts) == 2 and parts[1][:1].isupper():
        return f"{parts[1]} {parts[0]}"
    return folder.replace("_", " ")


def composer(folder, author):
    key = words(folder)
    name = next((n for n in names(author) if words(n) == key), None)
    if name:
        return name, subtitle(name, author)
    return spoken_name(folder), None


# --- Output -------------------------------------------------------------------

def main():
    hvsc = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Library/Application Support/phosphor/HVSC"
    stil = stil_entries(hvsc / "DOCUMENTS/STIL.txt")
    lengths = songlengths(hvsc / "DOCUMENTS/Songlengths.md5")

    tunes, composers = [], {}
    for rel in PLAYLIST + MORE:
        path = f"/MUSICIANS/{rel}.sid"
        file = hvsc / path.lstrip("/")
        if not file.exists():
            print(f"skipped {path}: not in HVSC", file=sys.stderr)
            continue
        data = file.read_bytes()
        tune = header(data)
        md5, secs = lengths.get(path, (None, []))
        if md5 and md5 != hashlib.md5(data).hexdigest():
            print(f"warning: {path} doesn't match its Songlengths MD5", file=sys.stderr)
        folder = path.rsplit("/", 1)[0] + "/"
        name, sub = composer(folder.split("/")[3], tune["author"])
        note = reflow((stil.get(folder.lower()) or {}).get("comment"))
        if note:
            composers[folder] = note
        notes = stil_notes(stil.get(path.lower()))
        tunes.append({
            "path": path,
            **tune,
            "lengths": secs,
            "composer": name,
            **({"composerSub": sub} if sub else {}),
            **({"stil": notes} if notes else {}),
        })
    js = (
        "// Generated by apple/scripts/site-demo-tunes.py from HVSC: each demo\n"
        "// tune's header fields, Songlengths, and STIL's notes on the tune and on\n"
        "// its composer's folder. The page plays a stand-in for each.\n\n"
        f"export const PLAYLIST_SIZE = {sum(1 for t in tunes if t['path'][11:-4] in PLAYLIST)};\n\n"
        f"export const TUNES = {json.dumps(tunes, ensure_ascii=False, indent=1)};\n\n"
        f"export const COMPOSER_NOTES = {json.dumps(composers, ensure_ascii=False, indent=1)};\n"
    )
    OUT.write_text(js, encoding="utf-8")
    for t in tunes:
        print(f"{t['title'][:28]:28} {t['composer'][:20]:20} songs={t['songs']:<3} "
              f"{t['format']} sid={t['sid']} pal={t['pal']} chips={t['chips']} "
              f"stil={'yes' if 'stil' in t else '-'}", file=sys.stderr)
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB, {len(tunes)} tunes)", file=sys.stderr)


if __name__ == "__main__":
    main()
