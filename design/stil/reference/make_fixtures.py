#!/usr/bin/env python3
"""
Cut fixture entries out of a full STIL.txt and write golden outputs.

    python3 make_fixtures.py /path/to/STIL.txt ../fixtures     # (re)generate
    python3 make_fixtures.py --check ../fixtures                # verify reference still matches

Each fixture is:
    <name>.stil.txt        the raw entry text, exactly as in STIL.txt (plus the
                           musician's folder entry when initials come from it)
    <name>.expected.json   build_entry() output for the fixture's main entry
manifest.json lists the fixtures, their main entry and what they exercise.
"""
import json
import os
import sys

from stil_reference import parse, read_stil, build_entry, initials_index, initials_for

FIXTURES = [
    ("freaky_dna_reflow", "/DEMOS/0-9/128_Byte_Blues_BASIC.sid", [],
     "Hard-wrapped essay: unwrap into 3 paragraphs; whole comment is one quote; byline from (Freaky DNA); PAL/NTSC and 6581/8580 as tech runs; 'etc..' fix"),
    ("commando_medley", "/MUSICIANS/H/Hubbard_Rob/Commando.sid", ["/MUSICIANS/H/Hubbard_Rob/"],
     "File-level quote signed (RH) resolved via folder entry to Rob Hubbard (composer); subtune 1 medley with point and range timestamps; subtune 3 <?> unknown title"),
    ("seven_years_remix", "/DEMOS/0-9/7_Years.sid", [],
     "Cover (TITLE + ARTIST) and a cross-reference link run 'Remix of /MUSICIANS/...sid'"),
    ("three_oversample_link", "/DEMOS/0-9/3_Oversample.sid", [],
     "Inline link mid-sentence; text before/after the link stays plain"),
    ("miles_memoriam", "/DEMOS/0-9/53_Miles_West_of_Venus.sid", [],
     "memoriam flag"),
    ("lion_heart_other_voice", "/MUSICIANS/H/Hubbard_Rob/Lion_Heart.sid", ["/MUSICIANS/H/Hubbard_Rob/"],
     "Quote by someone who is not the folder's musician: role stays null (never 'not the composer'); spaced hyphen becomes em dash"),
    ("master_of_magic_cover_quote", "/MUSICIANS/H/Hubbard_Rob/Master_of_Magic.sid", ["/MUSICIANS/H/Hubbard_Rob/"],
     "Subtune with cover [from Audion] by Synergy plus a composer quote in the same subtune"),
    ("phobos_initials_mixed", "/MUSICIANS/P/Phobos/Batman.sid", ["/MUSICIANS/P/Phobos/"],
     "Note block + quote block in one comment; (KM) resolved via folder declaration; link with ', Tune #2' subtune"),
    ("scotland_mixed", "/MUSICIANS/C/Clarke_Peter/Scotland_the_Brave.sid", ["/MUSICIANS/C/Clarke_Peter/"],
     "Note paragraph followed by a composer quote; '...' becomes ellipsis"),
    ("numbered_list", "/MUSICIANS/D/Deetsay/Great_Hirmu_Sisters.sid", [],
     "Numbered list '1) 2) 3)' gets one paragraph per item"),
    ("interview_qa", "/MUSICIANS/T/Tel_Jeroen/Bad_Blood.sid", [],
     "Q: becomes a question block; the unquoted 'JT: ...' answer runs to the comment's end as a quote signed JT (Jeroen Tel, composer)"),
    ("interview_quoted_answer", "/MUSICIANS/D/Daglish_Ben/Last_Ninja.sid", ["/MUSICIANS/D/Daglish_Ben/"],
     "Quote, then Q: question and a quoted 'A: \"...\" (BD)' answer resolved to Ben Daglish; the note after it stays a note"),
    ("lead_in_quote", "/MUSICIANS/K/Kriwanek_Mario/U-96.sid", [],
     "Song 1: 'Same as /…/Remoteness.sid \"…\" (Geir Tjelta)': no sentence break before the quote, yet it splits into a note and someone else's quote"),
    ("lead_in_long_quote", "/MUSICIANS/N/NecroPolo/Snowpiercer.sid", ["/MUSICIANS/N/NecroPolo/"],
     "'X-SID \"…' opens a quote after a tracker name and closes, signed (NP), paragraphs later; the tracker becomes the quote's label, not a note"),
    ("emphasis", "/MUSICIANS/C/CreaMD/Black_Sistah.sid", [],
     "*word* becomes an em run"),
    ("url", "/GAMES/A-F/Catalypse.sid", [],
     "URL run"),
    ("hex_address", "/GAMES/A-F/Alf_the_First_Adventure.sid", [],
     "$hex address as tech run"),
    ("names_field", "/DEMOS/A-F/Battle_Hymn_of_the_Republic_v1_BASIC.sid", [],
     "NAME / AUTHOR fields"),
]


def raw_block(text_lines, path):
    """Return the raw lines of one entry (path line up to the blank line before the next entry)."""
    start = text_lines.index(path)
    out = [text_lines[start]]
    for line in text_lines[start + 1:]:
        if line.startswith("/") or line.startswith("#"):
            break
        out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return out


def generate(stil_path, out_dir):
    text = read_stil(stil_path)
    lines = text.split("\n")
    os.makedirs(out_dir, exist_ok=True)
    manifest = []
    for name, entry, folders, what in FIXTURES:
        block = []
        for f in folders:
            block += raw_block(lines, f) + [""]
        block += raw_block(lines, entry)
        raw_text = "\n".join(block) + "\n"
        with open(os.path.join(out_dir, f"{name}.stil.txt"), "w", encoding="utf-8") as fh:
            fh.write(raw_text)
        manifest.append({"name": name, "entry": entry, "exercises": what})
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
    write_expected(out_dir)


def expected_for(out_dir, item):
    raw_text = open(os.path.join(out_dir, f"{item['name']}.stil.txt"), encoding="utf-8").read()
    entries = parse(raw_text)
    idx = initials_index(entries)
    return build_entry(entries[item["entry"]], initials=initials_for(item["entry"], idx))


def write_expected(out_dir):
    manifest = json.load(open(os.path.join(out_dir, "manifest.json"), encoding="utf-8"))
    for item in manifest:
        with open(os.path.join(out_dir, f"{item['name']}.expected.json"), "w", encoding="utf-8") as fh:
            json.dump(expected_for(out_dir, item), fh, indent=2, ensure_ascii=False)
            fh.write("\n")


def check(out_dir):
    manifest = json.load(open(os.path.join(out_dir, "manifest.json"), encoding="utf-8"))
    bad = 0
    for item in manifest:
        want = json.load(open(os.path.join(out_dir, f"{item['name']}.expected.json"), encoding="utf-8"))
        got = expected_for(out_dir, item)
        ok = want == got
        bad += not ok
        print(("PASS " if ok else "FAIL ") + item["name"])
    return bad


if __name__ == "__main__":
    if sys.argv[1] == "--check":
        sys.exit(1 if check(sys.argv[2]) else 0)
    generate(sys.argv[1], sys.argv[2])
