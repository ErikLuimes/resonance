#!/usr/bin/env python3
"""Reads real fingerprints from the running Resonance, for the terminal page's live terminal.

Asks the app, over its control socket, for the Favorites playlist, how each tune sounds,
and the tunes that sound like each. Writes the file named, or data.js beside this one,
which is the mockup's. No paths go in it.

    python3 design/site-cli/make-data.py apple/site/js/terminal-data.js
"""
import json, os, socket, sys

GROUP = os.path.expanduser("~/Library/Group Containers/R4D8QN85WK.resonance/control.sock")
OWN = os.path.expanduser("~/Library/Containers/app.useresonance.resonance/Data/control.sock")
PLAYLIST, ROWS, PANEL, COLS = "Favorites", 18, 4, 34

sock = socket.socket(socket.AF_UNIX)
sock.connect(GROUP if os.path.exists(GROUP) else OWN)
lines, count = sock.makefile("r"), 0

def call(cmd, missing=None, **args):
    """Ask the app. `missing` is the answer for a tune it has no fingerprint of."""
    global count
    count += 1
    sock.sendall((json.dumps({"id": count, "cmd": cmd, "args": args}) + "\n").encode())
    answer = json.loads(lines.readline())
    if not answer.get("ok"):
        if missing is not None:
            return missing
        raise SystemExit(f"{cmd}: {answer.get('error')}")
    return answer["result"]

ids, tunes = {}, []

def tune(row):
    """The tune's number in the file, adding it the first time it's seen."""
    path = row["path"]
    if path not in ids:
        ids[path] = len(tunes)
        tunes.append({"t": row["title"], "a": row["author"], "r": row["released"], "s": row.get("secs") or 0, "_path": path})
    return ids[path]

def squeeze(voice):
    """A voice's loudness across the tune, in COLS steps of 0 to 8."""
    if not voice:
        return ""
    out = []
    for i in range(COLS):
        part = voice[i * len(voice) // COLS:max((i + 1) * len(voice) // COLS, i * len(voice) // COLS + 1)]
        out.append(str(min(8, round(max(part) / 255 * 8))))
    return "".join(out)

def detail(index):
    entry = tunes[index]
    if "f" in entry and "d" in entry:
        return
    path = entry["_path"]
    prints = call("prints", missing=[], paths=[path], detail=True)
    if prints:
        p = prints[0]
        entry["f"] = [round(v, 2) for v in p["traits"]]
        if p.get("mix"):
            m = p["mix"]
            entry["m"] = [round(m[k] * 100) for k in ("pulse", "noise", "triangle", "saw")]
        if p.get("activity"):
            entry["v"] = [squeeze(v) for v in p["activity"]]
    sound = call("sound", missing={}, path=path)
    entry["d"] = sound.get("summary", "") if isinstance(sound, dict) else ""

def traits(indexes):
    need = [i for i in indexes if "f" not in tunes[i]]
    for start in range(0, len(need), 200):
        for p in call("prints", paths=[tunes[i]["_path"] for i in need[start:start + 200]]):
            tunes[ids[p["path"]]]["f"] = [round(v, 2) for v in p["traits"]]

def alike(index, limit):
    rows = call("like", missing=[], path=tunes[index]["_path"], limit=limit)
    return [[tune(r), round((r.get("score") or 0) * 100)] for r in rows]

favorites = [tune(r) for r in call("playlist.show", name=PLAYLIST) if "/HVSC" in r["path"] or "/HCSV" in r["path"]]
lists = {}
for f in favorites:
    lists[f] = alike(f, ROWS)
shown = list(dict.fromkeys(favorites + [i for f in favorites for i, _ in lists[f]]))
for n, i in enumerate(shown):
    detail(i)
    if i not in lists:
        lists[i] = alike(i, PANEL)
    print(f"\r{n + 1}/{len(shown)}", end="", file=sys.stderr)
traits(range(len(tunes)))
for entry in tunes:
    del entry["_path"]

data = {"playlist": PLAYLIST, "favorites": favorites, "tunes": tunes, "like": lists}
with open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "data.js"), "w") as out:
    out.write("// Made by make-data.py from the running app. Don't edit.\nwindow.TERMINAL_DATA = ")
    json.dump(data, out, ensure_ascii=False, separators=(",", ":"))
    out.write(";\n")
print(f"\n{len(tunes)} tunes, {len(lists)} lists", file=sys.stderr)
