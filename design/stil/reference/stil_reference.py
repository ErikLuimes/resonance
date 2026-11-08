#!/usr/bin/env python3
"""
Reference implementation of the STIL pipeline for Resonance.

    parse  ->  reflow  ->  enrich  ->  render-ready JSON

This is the executable spec. The Swift code in Resonance should produce the
same output for the fixtures in ../fixtures/ (see SPEC.md for the rules in
prose). Run it on a whole STIL.txt to get corpus stats:

    python3 stil_reference.py STIL.txt --stats
    python3 stil_reference.py STIL.txt --entry /MUSICIANS/H/Hubbard_Rob/Commando.sid

Only the standard library is used.
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field, asdict
from typing import Optional

# ---------------------------------------------------------------------------
# 1. Parsing
# ---------------------------------------------------------------------------

FIELD_KEYS = ("NAME", "AUTHOR", "TITLE", "ARTIST", "COMMENT", "BUG")
FIELD_RE = re.compile(r"^ {0,4}(NAME|AUTHOR|TITLE|ARTIST|COMMENT|BUG): ?(.*)$")
SUBTUNE_RE = re.compile(r"^\(#(\d+)\)\s*$")
INDENT = 9  # "COMMENT: " and continuation lines both start text at column 9


@dataclass
class RawField:
    key: str
    lines: list[str]  # text only, key/indent stripped, trailing spaces removed


@dataclass
class RawSection:
    subtune: Optional[int]  # None = applies to the whole file
    fields: list[RawField] = field(default_factory=list)


@dataclass
class RawEntry:
    path: str
    sections: list[RawSection] = field(default_factory=list)


def read_stil(path: str) -> str:
    """STIL.txt from HVSC is ISO-8859-1 with CRLF line endings.
    Decode as UTF-8 first (some redistributed copies are UTF-8), then fall back
    to Latin-1, which never fails."""
    data = open(path, "rb").read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    return text.replace("\r\n", "\n").replace("\r", "\n")


def parse(text: str) -> dict[str, RawEntry]:
    entries: dict[str, RawEntry] = {}
    cur: Optional[RawEntry] = None
    sec: Optional[RawSection] = None
    fld: Optional[RawField] = None

    for line in text.split("\n"):
        line = line.rstrip()
        if not line:
            fld = None
            continue
        if line.startswith("#"):          # file header and "### /DEMOS/ ###" dividers
            cur = sec = fld = None
            continue
        if line.startswith("/"):          # new entry: the tune's HVSC path
            cur = RawEntry(path=line.strip())
            entries[cur.path] = cur
            sec = RawSection(subtune=None)
            cur.sections.append(sec)
            fld = None
            continue
        if cur is None:
            continue
        m = SUBTUNE_RE.match(line)
        if m:
            sec = RawSection(subtune=int(m.group(1)))
            cur.sections.append(sec)
            fld = None
            continue
        m = FIELD_RE.match(line)
        if m:
            fld = RawField(key=m.group(1), lines=[m.group(2)])
            sec.fields.append(fld)
            continue
        if fld is not None and line.startswith(" " * INDENT):
            fld.lines.append(line[INDENT:])
            continue
        # Anything else is malformed; keep it rather than lose text.
        if fld is not None:
            fld.lines.append(line.strip())

    # Drop the empty file-level section when an entry starts straight with (#1)
    for e in entries.values():
        e.sections = [s for s in e.sections if s.fields or s.subtune is not None]
    return entries


# ---------------------------------------------------------------------------
# 2. Reflow (unwrap hard-wrapped lines into paragraphs)
# ---------------------------------------------------------------------------

WRAP_WIDTH = 79   # STIL is hand-wrapped to 79-80 columns
SLACK = 3         # tolerate sloppy hand-wrapping
SENTENCE_END = tuple('.!?")')   # not ':' - "I learned one thing:" usually continues
NUMBERED_RE = re.compile(r"^\(?\d{1,2}[.)]\s")       # "1) ", "2. ", "(3) "  - not "1990. "
BULLET_RE = re.compile(r"^[-*\u2022]\s")
SPEAKER_RE = re.compile(r"^[A-Z]{1,3}:\s")           # interview lines: "Q: ", "A: ", "MG: "


def _first_word(s: str) -> str:
    return s.split(" ", 1)[0]


def reflow(lines: list[str]) -> list[str]:
    """Join hard-wrapped lines; return paragraphs (each one string)."""
    lines = [l.strip() for l in lines]
    paras: list[str] = []
    cur = ""
    for i, line in enumerate(lines):
        if not line:
            if cur:
                paras.append(cur)
                cur = ""
            continue
        if not cur:
            cur = line
        elif cur.endswith("-") and not cur.endswith(" -") and line[:1].islower():
            cur += line                    # word hyphenated across the break
        else:
            cur += " " + line

        if i + 1 >= len(lines) or not lines[i + 1]:
            continue
        nxt = lines[i + 1]
        ends_sentence = line.endswith(SENTENCE_END)
        would_have_fit = INDENT + len(line) + 1 + len(_first_word(nxt)) <= WRAP_WIDTH - SLACK
        structural = (
            NUMBERED_RE.match(nxt) is not None
            or SPEAKER_RE.match(nxt) is not None
            or (BULLET_RE.match(nxt) is not None and ends_sentence)
        )
        if (would_have_fit and ends_sentence) or structural:
            paras.append(cur)
            cur = ""
    if cur:
        paras.append(cur)
    return paras


# ---------------------------------------------------------------------------
# 3. Enrichment
# ---------------------------------------------------------------------------

# 3a. Titles: "BGM1 [from the arcade game Commando] (1:16-1:32)"
TITLE_RE = re.compile(
    r"^(?P<title>.*?)"
    r"(?:\s*\[(?P<src>[Ff]rom [^\]]*(?:\[[^\]]*\][^\]]*)*)\])?"
    r"(?:\s*\((?P<t1>\d{1,2}:\d\d)(?:-(?P<t2>\d{1,2}:\d\d))?\))?$"
)


def _secs(ts: Optional[str]) -> Optional[int]:
    if not ts:
        return None
    m, s = ts.split(":")
    return int(m) * 60 + int(s)


def parse_title(raw: str) -> dict:
    m = TITLE_RE.match(raw.strip())
    title = m.group("title").strip() if m else raw.strip()
    src = m.group("src") if m else None
    return {
        "title": None if title in ("<?>", "") else title,   # "<?>" = unknown title
        "unknown": title == "<?>",
        "source": src[5:].strip() if src else None,           # "the arcade game Commando"
        "at": _secs(m.group("t1")) if m else None,            # seconds into the subtune
        "until": _secs(m.group("t2")) if m else None,
    }


# 3b. Composer names from the HVSC path
def composer_from_path(path: str) -> Optional[dict]:
    """/MUSICIANS/H/Hubbard_Rob/Commando.sid -> {'name': 'Rob Hubbard', 'initials': 'RH'}.
    Folder names are Last_First (last name may contain spaces: Del_Duca_Ivan)."""
    parts = path.split("/")
    if len(parts) < 5 or parts[1] != "MUSICIANS":
        return None
    folder = parts[-2]          # deepest folder: /MUSICIANS/B/Blues_Muz/Nordboe_Kjell/x.sid
    bits = folder.split("_")
    if len(bits) < 2:
        return {"name": folder, "initials": folder[:1].upper(), "aliases": [folder]}
    first, last = bits[-1], " ".join(bits[:-1])
    name = f"{first} {last}"
    initials = (first[:1] + "".join(w[:1] for w in last.split())).upper()
    short = (first[:1] + last[:1]).upper()
    return {"name": name, "initials": initials, "aliases": sorted({initials, short, name, last, first})}


# 3b'. Folder entries ("/MUSICIANS/P/Paco/") often declare which initials sign
# that musician's comments: "Paco's (Ádám Papp) own comments are denoted (AP)."
INITIALS_DECL_RE = re.compile(
    r"(?:(?P<who>[A-Z][\w .'\-\u00c0-\u024f]{0,40}?)(?:'s)?(?:\s*\([^)]*\))?\s+(?:own\s+)?comments?"
    r"|comments?\s+(?:by|from)\s+(?P<who2>[^.()]{1,40}?))"
    r"\s+(?:are\s+|is\s+)?(?:denoted|indicated|marked|signed)(?:\s+(?:by|with|as))?\s*\((?P<ini>[^)]{1,8})\)"
)


def initials_index(entries: dict[str, "RawEntry"]) -> dict[str, dict[str, str]]:
    """folder path -> {initials: display name}. Applies to every tune below it."""
    index: dict[str, dict[str, str]] = {}
    for path, raw in entries.items():
        if not path.endswith("/"):
            continue
        fallback = composer_from_path(path + "x.sid")
        for sec in raw.sections:
            for f in sec.fields:
                if f.key != "COMMENT":
                    continue
                text = " ".join(l.strip() for l in f.lines)
                for m in INITIALS_DECL_RE.finditer(text):
                    who = (m.group("who") or m.group("who2") or "").strip()
                    who = who.split(". ")[-1].strip().rstrip("'’")   # "...House. Brennan", "Simmonds'"
                    if not who or who.split()[0] in ("All", "The", "His", "Her", "Their", "Own"):
                        who = fallback["name"] if fallback else who
                    elif fallback and " " not in who and who in fallback["name"].split():
                        who = fallback["name"]                              # "Glenn" -> "Glenn Gallefoss"
                    index.setdefault(path, {})[m.group("ini").strip()] = who
    return index


def initials_for(path: str, index: dict[str, dict[str, str]]) -> dict[str, str]:
    out: dict[str, str] = {}
    for folder in sorted(index, key=len):          # outer folders first, inner override
        if path.startswith(folder):
            out.update(index[folder])
    return out


# 3c. Quote + attribution:  "....." (Freaky DNA)


def resolve_byline(by: Optional[str], composer: Optional[dict], sid_author: Optional[str],
                   initials: Optional[dict[str, str]] = None) -> dict:
    """Decide whether the person quoted is the tune's composer.
    `sid_author` is the PSID header author field, e.g. 'Jeroen Tel (WMC)'; the app
    has it, the reference tool usually does not."""
    if not by:
        return {"by": None, "role": None}
    declared = (initials or {}).get(by)
    if declared:
        is_composer = bool(composer) and declared.lower() in {a.lower() for a in composer["aliases"]}
        return {"by": declared, "role": "composer" if is_composer else None}
    candidates: set[str] = set()
    if composer:
        candidates |= {a.lower() for a in composer["aliases"]}
    if sid_author:
        a = sid_author.strip()
        candidates.add(a.lower())
        h = re.search(r"\(([^)]+)\)", a)
        if h:
            candidates.add(h.group(1).lower())                     # handle in parens
        plain = re.sub(r"\s*\([^)]*\)", "", a).strip()
        candidates.add(plain.lower())
        words = [w for w in re.split(r"[\s&,]+", plain) if w]
        candidates.add("".join(w[0] for w in words).lower())      # initials
    if by.lower() in candidates:
        return {"by": composer["name"] if composer and by.isupper() and len(by) <= 4 else by,
                "role": "composer"}
    # No match does NOT mean "someone else": STIL often signs with the initials
    # of a musician's real name while the folder uses their handle
    # (/MUSICIANS/P/Phobos/... signed "(KM)"). Never claim "not the composer".
    return {"by": by, "role": None}


# 3d. Inline tokens inside comment text
LINK_RE = re.compile(r"/(?:MUSICIANS|DEMOS|GAMES)/\S+?\.sid")
URL_RE = re.compile(r"\b(?:https?://|www\.)[^\s\"')\]]+[^\s\"')\].,;:!?]")
EMPH_RE = re.compile(r"(?<![\w*])\*(?=\S)([^*\n]{1,40}?)(?<=\S)\*(?![\w*])")
TECH_RE = re.compile(r"\$[0-9A-Fa-f]{2,4}\b|\b(?:6581|8580)(?:/(?:6581|8580))?\b|\b(?:PAL|NTSC)(?:/(?:PAL|NTSC))?\b")
SUBTUNE_REF_RE = re.compile(r"^,?\s*\(?(?:sub)?(?:tune|song)\s*#?(\d+)\)?", re.I)

TOKEN_RE = re.compile("|".join(f"(?P<{n}>{r.pattern})" for n, r in
                               (("link", LINK_RE), ("url", URL_RE), ("em", EMPH_RE), ("tech", TECH_RE))))


def smart_typography(s: str) -> str:
    """Typographic clean-up for plain prose. Never applied to paths/URLs."""
    s = s.replace("etc..", "etc.")
    s = re.sub(r"\.\.\.+", "\u2026", s)
    s = re.sub(r"\s+--\s+|\s+-\s+", " \u2014 ", s)       # spaced dash -> em dash
    s = s.replace("--", "\u2014")
    s = re.sub(r"(\w)'(\w)", "\\1\u2019\\2", s)          # it's
    s = re.sub(r"(\s|^|[(\[])'", "\\1\u2018", s)        # opening single
    s = s.replace("'", "\u2019")                         # remaining: closing / possessive
    s = re.sub(r'(\s|^|[(\[\u2014])"', "\\1\u201c", s)  # opening double
    s = s.replace('"', "\u201d")
    return s


MASK = "\ue000"


def to_runs(text: str) -> list[dict]:
    """Split a paragraph into styled runs:
       {"t": text}                     plain
       {"t": text, "link": path}       cross-reference to another tune (+ "subtune")
       {"t": text, "url": href}
       {"t": text, "em": true}
       {"t": text, "tech": true}       chip models, PAL/NTSC, $hex addresses
    """
    # Typography must see the whole paragraph (a closing quote right after a
    # link is still a closing quote), but must never touch paths or URLs.
    # So: mask tokens with a placeholder letter, typeset, then split.
    tokens: list[dict] = []
    masked = []
    pos = 0
    for m in TOKEN_RE.finditer(text):
        masked.append(text[pos:m.start()])
        kind, tok = m.lastgroup, m.group(0)
        if kind == "link":
            run = {"t": tok, "link": tok}
            tail = SUBTUNE_REF_RE.match(text[m.end():])
            if tail:
                run["subtune"] = int(tail.group(1))
        elif kind == "url":
            run = {"t": tok, "url": tok if tok.startswith("http") else "https://" + tok}
        elif kind == "em":
            run = {"t": smart_typography(tok[1:-1]), "em": True}
        else:
            run = {"t": tok, "tech": True}
        tokens.append(run)
        masked.append(MASK)          # private-use char, contains no quotes or spaces
        pos = m.end()
    masked.append(text[pos:])
    typeset = smart_typography("".join(masked))

    runs: list[dict] = []
    for i, chunk in enumerate(typeset.split(MASK)):
        if chunk:
            runs.append({"t": chunk})
        if i < len(tokens):
            runs.append(tokens[i])
    return runs


MEMORIAM_RE = re.compile(r"\bpassed away\b|\bR\.I\.P\b", re.I)
SENTENCE_RE = re.compile(r"^(.+?[.!?\u2026])(?:\s|$)")


def first_sentence(s: str, max_len: int = 140) -> str:
    m = SENTENCE_RE.match(s)
    out = m.group(1) if m else s
    if len(out) > max_len:
        out = out[: max_len - 1].rsplit(" ", 1)[0] + "\u2026"
    return out


# A quote block ends with  "  or  " (Attribution)  or  " (Comment by Someone)
QUOTE_END_RE = re.compile(r'"\s*(?:\((?:[Cc]omments? by |[Qq]uote by )?(?P<by>[^()]{1,40})\))?\s*$')
ATTR_ONLY_RE = re.compile(r'^\((?:[Cc]omments? by |[Qq]uote by )?(?P<by>[^()]{1,40})\)\s*$')
# A quote that starts mid-paragraph: 'Demo version of X. "This is a track I wrote..." (AB)'
INLINE_QUOTE_START_RE = re.compile(r'(?:^|(?<=[.!?:]\s)|(?<=\s))"')


def _split_inline_quote(p: str) -> Optional[tuple[str, str]]:
    """If paragraph p ends in a quote with attribution that starts mid-paragraph,
    return (note_part, quote_part). Picks the earliest opening quote after a
    sentence boundary whose remainder has balanced quotes."""
    end = QUOTE_END_RE.search(p)
    if not end or not end.group("by"):
        return None
    for m in INLINE_QUOTE_START_RE.finditer(p):
        k = m.start() if p[m.start()] == '"' else m.start()
        if k == 0:
            return None
        head, tail = p[:k].rstrip(), p[k:]
        if not head.endswith((".", "!", "?", ":")):
            continue
        if tail[:end.start() - k + 1].count('"') % 2 == 0:
            return head, tail
    # No sentence boundary before the quote: a reference or a tool name in
    # front of it ("Same as /…/Remoteness.sid "Used in the game…" (Geir
    # Tjelta)", "SW1.8 "Title is…" (NP)"). Split there too when the byline
    # is a name or initials and the quote is a phrase, not a title.
    if not _is_byline(end.group("by")):
        return None
    for m in INLINE_QUOTE_START_RE.finditer(p):
        k = m.start()
        if k == 0:
            return None
        head, tail = p[:k].rstrip(), p[k:]
        body = tail[1:end.start() - k]
        # A phrase, or anything after a short label like "SW1.7".
        if tail[:end.start() - k + 1].count('"') % 2 == 0 and (len(body.split()) >= 4 or len(head.split()) <= 3):
            return head, tail
    return None


def _split_opening_quote(p: str, rest: list[str]) -> Optional[tuple[str, str]]:
    """A quote that opens after a short lead-in ("SW1.8 "This angry tune…",
    "Covers /…/Traz.sid "…") and closes, signed, in a later paragraph:
    (lead-in, quote start). The lead-in is a few words or ends in a tune
    path; the quote must close with a name or initials."""
    for m in INLINE_QUOTE_START_RE.finditer(p):
        k = m.start()
        if k == 0:
            return None
        head, tail = p[:k].rstrip(), p[k:]
        if len(head.split()) > 3 and not head.endswith(".sid"):
            return None
        count = tail.count('"')
        if count % 2 == 0:
            return None                               # closed here: not this case
        for q in rest:
            count += q.count('"')
            end = QUOTE_END_RE.search(q)
            if count % 2 == 0:
                if end and _is_byline(end.group("by")):
                    return head, tail
                return None
        return None
    return None


def _is_label(head: str) -> bool:
    """A lead-in that names the tool a tune was made with rather than saying
    something: a few words, no sentence end, no tune path ("SW1.8",
    "GMC1.6 + SW1.9-EMU", "SID Factory 2")."""
    return (0 < len(head.split()) <= 3 and "/" not in head
            and not head.endswith((".", "!", "?", ":", ",")))


# A byline that is a name or initials: every word capitalized (or a digit,
# or a name particle), so "(German children's song)" isn't one.
BYLINE_PARTICLES = {"van", "de", "der", "den", "von", "of", "the", "la", "le", "di", "da", "and", "&"}


def _is_byline(by: Optional[str]) -> bool:
    if not by:
        return False
    words = by.split()
    return all(w[0].isupper() or w[0].isdigit() or w.lower() in BYLINE_PARTICLES for w in words)


# "Q: Is this a cover?" / "A: ..." / "JT: ...": an interview line.
QA_RE = re.compile(r"^(?P<who>[A-Z]{1,3}): (?P<rest>.*)$", re.S)


def split_blocks(paras: list[str]) -> list[dict]:
    """Group paragraphs into note blocks, quote blocks and interview
    questions. A "Q: " paragraph is a question block; the "A: " or "XY: "
    paragraph after it is the answer, a quote: up to its closing quote when
    it opens with one, else up to the next question or the comment's end.
    Initials other than "A" sign an answer that has no (byline)."""
    work: list[str] = []
    labels: dict[int, str] = {}                       # work index of a quote → its tool label
    for n, p in enumerate(paras):                     # split "Note. "Quote" (X)" first
        # (not an interview line: its "A: " isn't a note)
        sp = None
        if not p.startswith('"') and not QA_RE.match(p):
            sp = _split_inline_quote(p) or _split_opening_quote(p, paras[n + 1:])
        if sp and _is_label(sp[0]):
            labels[len(work)] = sp[0]                 # "SW1.8 "…": the quote's label, not a note
            work.append(sp[1])
        else:
            work.extend(sp if sp else [p])

    def is_question(p: str) -> bool:
        m = QA_RE.match(p)
        return bool(m) and m.group("who") == "Q"

    blocks: list[dict] = []
    answer_by: Optional[str] = None                   # an answer's speaker, for its quote
    i = 0
    while i < len(work):
        p = work[i]
        qa = QA_RE.match(p)
        if qa and qa.group("who") == "Q":
            blocks.append({"kind": "question", "by": None, "paragraphs": [qa.group("rest").strip()]})
            i += 1
            continue
        if qa and blocks and blocks[-1]["kind"] == "question":
            who, rest = qa.group("who"), qa.group("rest").strip()
            speaker = None if who == "A" else who
            if rest.startswith('"'):
                work[i] = p = rest                    # handled as a quote below
                answer_by = speaker
            else:
                body, j = [rest], i + 1
                while j < len(work) and not is_question(work[j]):
                    body.append(work[j])
                    j += 1
                blocks.append({"kind": "quote", "by": speaker, "paragraphs": body})
                i = j
                continue
        if p.startswith('"'):
            # find the paragraph that closes this quote (balanced quote count)
            count, j, closed = 0, i, None
            while j < len(work):
                count += work[j].count('"')
                if count % 2 == 0 and QUOTE_END_RE.search(work[j]):
                    closed = j
                    break
                j += 1
            if closed is not None:
                body = work[i:closed + 1]
                m = QUOTE_END_RE.search(body[-1])
                by = m.group("by")
                body[-1] = body[-1][:m.start()]
                body[0] = body[0][1:]
                nxt = closed + 1
                if not by and nxt < len(work):
                    a = ATTR_ONLY_RE.match(work[nxt])
                    if a:
                        by, nxt = a.group("by"), nxt + 1
                by = by or answer_by
                answer_by = None
                block = {"kind": "quote", "by": by.strip() if by else None,
                         "paragraphs": [b.strip() for b in body if b.strip()]}
                if i in labels:
                    block["label"] = labels[i]
                blocks.append(block)
                i = nxt
                continue
        answer_by = None
        if blocks and blocks[-1]["kind"] == "note":
            blocks[-1]["paragraphs"].append(p)
        else:
            blocks.append({"kind": "note", "by": None, "paragraphs": [p]})
        i += 1
    return blocks


def enrich_comment(lines: list[str], composer: Optional[dict], sid_author: Optional[str],
                   initials: Optional[dict[str, str]] = None) -> dict:
    paras = reflow(lines)
    blocks = split_blocks(paras)
    out_blocks, links = [], set()
    for b in blocks:
        byline = resolve_byline(b["by"], composer, sid_author, initials)
        runs = [to_runs(p) for p in b["paragraphs"]]
        links |= {r["link"] for p in runs for r in p if "link" in r}
        out = {"kind": b["kind"], "by": byline["by"], "role": byline["role"], "paragraphs": runs}
        if "label" in b:
            out["label"] = b["label"]                 # only when there is one
        out_blocks.append(out)
    first = blocks[0]["paragraphs"][0] if blocks and blocks[0]["paragraphs"] else ""
    return {
        "blocks": out_blocks,
        "memoriam": bool(MEMORIAM_RE.search(" ".join(paras))),
        "teaser": smart_typography(first_sentence(first)) if first else "",
        "links": sorted(links),
    }


# ---------------------------------------------------------------------------
# 4. Assemble the render-ready model
# ---------------------------------------------------------------------------

def build_entry(raw: RawEntry, sid_author: Optional[str] = None,
                initials: Optional[dict[str, str]] = None) -> dict:
    """`initials` = initials_for(raw.path, initials_index(all_entries))."""
    composer = composer_from_path(raw.path)
    out_sections = []
    for sec in raw.sections:
        covers, comments, names, authors = [], [], [], []
        last_cover = None
        for f in sec.fields:
            one_line = " ".join(l.strip() for l in f.lines)
            if f.key == "TITLE":
                last_cover = parse_title(one_line)
                last_cover["artist"] = None
                covers.append(last_cover)
            elif f.key == "ARTIST":
                artist = None if one_line == "<?>" else one_line      # "<?>" = unknown artist
                if last_cover is not None and last_cover["artist"] is None:
                    last_cover["artist"] = artist
                else:  # ARTIST without TITLE
                    covers.append({"title": None, "unknown": False, "source": None, "at": None,
                                   "until": None, "artist": artist})
            elif f.key == "COMMENT":
                comments.append(enrich_comment(f.lines, composer, sid_author, initials))
            elif f.key == "NAME":
                names.append(one_line)
            elif f.key == "AUTHOR":
                authors.append(one_line)
        timeline = [c for c in covers if c["at"] is not None]
        out_sections.append({
            "subtune": sec.subtune,
            "names": names,
            "authors": authors,
            "covers": covers,
            "isMedley": len(timeline) >= 2,
            "comments": comments,
        })
    return {"path": raw.path, "composer": composer, "sections": out_sections}


def medley_segments(covers: list[dict], song_length: Optional[int]) -> list[dict]:
    """Timeline segments for a medley. A single timestamp '(0:53)' runs until the
    next timestamped entry starts (or the song ends)."""
    timed = sorted((c for c in covers if c["at"] is not None), key=lambda c: c["at"])
    segs = []
    for i, c in enumerate(timed):
        end = c["until"]
        if end is None:
            end = timed[i + 1]["at"] if i + 1 < len(timed) else song_length
        segs.append({"title": c["title"] or "Unknown", "artist": c["artist"],
                     "start": c["at"], "end": end})
    return segs


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def corpus_stats(entries: dict[str, RawEntry]) -> dict:
    c = Counter()
    idx = initials_index(entries)
    c["folder_entries"] = sum(1 for p in entries if p.endswith("/"))
    c["folders_declaring_initials"] = len(idx)
    for raw in entries.values():
        e = build_entry(raw, initials=initials_for(raw.path, idx))
        c["entries"] += 1
        c["entries_with_subtunes"] += any(s["subtune"] is not None for s in e["sections"])
        for s in e["sections"]:
            c["subtune_sections"] += s["subtune"] is not None
            c["covers"] += sum(1 for x in s["covers"] if x["title"] or x["unknown"])
            c["covers_with_source"] += sum(1 for x in s["covers"] if x["source"])
            c["unknown_titles"] += sum(1 for x in s["covers"] if x["unknown"])
            c["medley_sections"] += s["isMedley"]
            for cm in s["comments"]:
                c["comments"] += 1
                c["comments_mixed_note_and_quote"] += len({b["kind"] for b in cm["blocks"]}) > 1
                c["memoriam"] += cm["memoriam"]
                for b in cm["blocks"]:
                    c["blocks_" + b["kind"]] += 1
                    c["paragraphs"] += len(b["paragraphs"])
                    c["quotes_with_byline"] += b["kind"] == "quote" and b["by"] is not None
                    c["quotes_confirmed_composer"] += b["role"] == "composer"
                    runs = [r for p in b["paragraphs"] for r in p]
                    c["link_runs"] += sum(1 for r in runs if "link" in r)
                    c["link_runs_with_subtune"] += sum(1 for r in runs if "subtune" in r)
                    c["url_runs"] += sum(1 for r in runs if "url" in r)
                    c["em_runs"] += sum(1 for r in runs if r.get("em"))
                    c["tech_runs"] += sum(1 for r in runs if r.get("tech"))
    return dict(c)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1
    entries = parse(read_stil(argv[1]))
    if "--stats" in argv:
        print(json.dumps(corpus_stats(entries), indent=2))
    if "--entry" in argv:
        key = argv[argv.index("--entry") + 1]
        idx = initials_index(entries)
        print(json.dumps(build_entry(entries[key], initials=initials_for(key, idx)), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
