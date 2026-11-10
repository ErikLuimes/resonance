#!/bin/bash
# Check a published release from the outside, the way a tester's Mac and
# the website see it: the GitHub release, its download, the update feed and
# the site's Download button. Run it after publishing; it changes nothing.
#
#   apple/scripts/release-check.sh             the project's current version
#   apple/scripts/release-check.sh <version>   another one: 0.1.0-alpha.8
#
# Each line is ok, warn, FAIL or skip, with what was found and, on a
# failure, what to do about it. It exits 1 if anything failed. Warnings
# don't break downloads or updates. A check is skipped when it needs
# something this Mac doesn't have: the .dmg from build/release, or the tag.
#
# The site deploys a little after a push (usually under a minute, sometimes
# several), so a feed that's behind right after publishing may only need a
# moment: the failure says so.
#
# RESONANCE_REPO=<owner/name> and RESONANCE_SITE=<url> check another
# repository or site. It reads GitHub without signing in, which allows 60
# requests an hour; a run takes two.
set -euo pipefail

APPLE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APPLE/.." && pwd)"
cd "$APPLE"

case "${1:-}" in
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "usage: apple/scripts/release-check.sh [<version>]" >&2; exit 2 ;;
esac

SETTINGS="$(xcodebuild -project Resonance.xcodeproj -scheme Resonance \
    -configuration Release -showBuildSettings 2>/dev/null)"
setting() { echo "$SETTINGS" | awk -v k="$1" '$1 == k { print $3; exit }'; }
STAGE="$(setting RELEASE_STAGE)"
PROJECT_VERSION="$(setting MARKETING_VERSION)${STAGE:+-$STAGE}"
VERSION="${1:-$PROJECT_VERSION}"
# The build number is only known for the project's own version.
BUILD=""
[ "$VERSION" = "$PROJECT_VERSION" ] && BUILD="$(setting CURRENT_PROJECT_VERSION)"

COLOR=0
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && COLOR=1

exec python3 -I - "$VERSION" "$BUILD" "${RESONANCE_REPO:-ErikLuimes/resonance}" \
    "$(setting SPARKLE_FEED_URL)" "${RESONANCE_SITE:-https://useresonance.app/}" \
    "$ROOT" "$COLOR" <<'EOF'
import hashlib, json, os, re, subprocess, sys

version, build, repo, feed_url, site, root, color = sys.argv[1:]
color = color == "1"
stage = version.partition("-")[2]            # "alpha.9", or "" for a final release
channel = stage.split(".")[0]                # "alpha", "beta" or ""
tag = "v" + version
name = "Resonance-%s.dmg" % version
dmg_url = "https://github.com/%s/releases/download/%s/%s" % (repo, tag, name)
appcast = "apple/site/appcast.xml"
local_dmg = os.path.join(root, "apple/build/release", name)

counts = {"ok": 0, "warn": 0, "FAIL": 0, "skip": 0}
COLORS = {"ok": "32", "warn": "33", "FAIL": "31", "skip": "2"}

def line(kind, text, fix=None):
    counts[kind] += 1
    label = "%-4s" % kind
    if color:
        label = "\033[%sm%s\033[0m" % (COLORS[kind], label)
    print("  %s  %s" % (label, text))
    if fix:
        for part in fix.split("\n"):
            print("        " + part)

def ok(text): line("ok", text)
def warn(text, fix=None): line("warn", text, fix)
def fail(text, fix=None): line("FAIL", text, fix)
def skip(text): line("skip", text)

def section(title):
    print("\n" + (("\033[1m%s\033[0m" % title) if color else title))

def run(*command):
    done = subprocess.run(command, capture_output=True, text=True, cwd=root)
    return done.returncode, done.stdout, done.stderr

def fetch(url, *options):
    """The body and the HTTP status of the last hop, or (None, why)."""
    code, out, err = run("curl", "-sSL", "-m", "30", "-w", "\n%{http_code}", *options, url)
    if code != 0:
        return None, err.strip().replace("curl: ", "") or "curl failed"
    body, _, status = out.rpartition("\n")
    return body, status

def megabytes(size):
    return "%.1f MB" % (size / 1e6)

print("Release check: Resonance %s%s" % (version, " (build %s)" % build if build else ""))

# ---------------------------------------------------------------- GitHub
section("GitHub release")
release, asset = None, None
body, status = fetch("https://api.github.com/repos/%s/releases?per_page=30" % repo,
                     "-H", "Accept: application/vnd.github+json")
releases = None
if body is None:
    fail("couldn't reach GitHub: %s" % status)
elif status != "200":
    hint = "60 requests an hour without signing in: try again later." if status in ("403", "429") else None
    fail("GitHub answered HTTP %s for the list of releases" % status, hint)
else:
    releases = json.loads(body)
    release = next((r for r in releases if r.get("tag_name") == tag), None)

if releases is not None and release is None:
    fail("no release tagged %s on %s" % (tag, repo),
         "Draft it at https://github.com/%s/releases/new?tag=%s\n"
         "A draft doesn't show here: publish it." % (repo, tag))
elif release:
    if release.get("draft"):
        fail("%s is still a draft" % tag, "Publish it: nobody can download a draft.")
    else:
        ok("%s is published" % tag)
    if bool(release.get("prerelease")) == bool(stage):
        ok("marked as a pre-release" if stage else "marked as a full release")
    elif stage:
        fail("not marked as a pre-release", "Tick \"Set as a pre-release\" on the release: %s is not final." % stage)
    else:
        fail("marked as a pre-release", "Untick \"Set as a pre-release\": this is a final release.")
    title = "Resonance " + version
    if release.get("name") == title:
        ok("titled \"%s\"" % title)
    else:
        warn("titled \"%s\"" % release.get("name"), "The others are \"%s\". Cosmetic: edit the title on GitHub." % title)
    asset = next((a for a in release.get("assets", []) if a.get("name") == name), None)
    if asset:
        ok("has %s (%s)" % (name, megabytes(asset["size"])))
    else:
        others = ", ".join(a["name"] for a in release.get("assets", [])) or "no files"
        fail("%s isn't attached (it has: %s)" % (name, others),
             "Attach apple/build/release/%s without renaming it:\nthe feed links to that exact name." % name)

    # The tag marks the source of the release: the commit with this version.
    code, out, _ = run("git", "show", "%s^{commit}:apple/Resonance.xcodeproj/project.pbxproj" % tag)
    if code != 0:
        skip("the tag isn't in this checkout (git fetch --tags), so its commit wasn't checked")
    else:
        stages = set(re.findall(r"RELEASE_STAGE = \"?([^\";]*)\"?;", out))
        if stages == {stage}:
            _, commit, _ = run("git", "rev-parse", "--short", "%s^{commit}" % tag)
            ok("the tag is on %s, which builds %s" % (commit.strip(), version))
        else:
            fail("the tag is on a commit that builds stage \"%s\"" % ", ".join(sorted(stages)),
                 "It should be on the commit with the version change to %s." % version)

# ---------------------------------------------------------------- Download
section("Download")
size = None
_, status = fetch(dmg_url, "-I")
if _ is None:
    fail("couldn't reach the download: %s" % status)
elif status != "200":
    fail("the download link answers HTTP %s" % status, dmg_url)
else:
    length = re.findall(r"(?im)^content-length:\s*(\d+)", _)
    size = int(length[-1]) if length else None
    ok("the link downloads (%s)" % (megabytes(size) if size else "size not given"))

if not os.path.isfile(local_dmg):
    skip("no apple/build/release/%s here, so the published file wasn't compared with the build" % name)
else:
    digest = (asset or {}).get("digest") or ""
    sha = hashlib.sha256()
    with open(local_dmg, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            sha.update(block)
    mine = sha.hexdigest()
    if not asset:
        skip("nothing published to compare the build with")
    elif not digest.startswith("sha256:"):
        if asset["size"] == os.path.getsize(local_dmg):
            warn("GitHub gives no checksum for the file; its size matches the build")
        else:
            fail("the published file is %d bytes, the build %d" % (asset["size"], os.path.getsize(local_dmg)),
                 "Upload apple/build/release/%s again." % name)
    elif digest[7:] == mine:
        ok("the published file is the build in build/release (SHA-256 %s…)" % mine[:12])
    else:
        fail("the published file isn't the build in build/release",
             "published %s…\nbuilt     %s…\n"
             "The feed's signature is for the built file: upload that one, or updates fail to verify."
             % (digest[7:19], mine[:12]))
    code, _, err = run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", local_dmg)
    stapled, _, _ = run("xcrun", "stapler", "validate", "-q", local_dmg)
    if code == 0 and stapled == 0:
        ok("the build is notarized and stapled")
    elif code == 0:
        warn("the build is notarized but not stapled", "It opens online; offline, Gatekeeper can't check it.")
    else:
        fail("Gatekeeper rejects the build: %s" % (err.strip().split(": ", 1)[-1] or "no reason given"),
             "An unsigned build needs Open Anyway in System Settings.")

# ---------------------------------------------------------------- Feed
section("Update feed")

def entries(feed):
    found = []
    for item in re.findall(r"<item>.*?</item>", feed, flags=re.S):
        def first(pattern):
            match = re.search(pattern, item, flags=re.S)
            return match.group(1) if match else None
        found.append({
            "title": first(r"<title>(.*?)</title>"),
            "build": int(first(r"<sparkle:version>(\d+)</sparkle:version>") or 0),
            "channel": first(r"<sparkle:channel>(.*?)</sparkle:channel>") or "",
            "url": first(r"<enclosure[^>]*\burl=\"([^\"]*)\""),
            "length": first(r"<enclosure[^>]*\blength=\"(\d+)\""),
            "notes": bool((first(r"<description[^>]*>(.*?)</description>") or "").strip()),
        })
    return found

if not feed_url:
    fail("the project has no SPARKLE_FEED_URL for Release")
else:
    live, status = fetch(feed_url)
    if live is None or status != "200":
        fail("couldn't read %s (%s)" % (feed_url, status if live is None else "HTTP " + status))
    else:
        code, committed, _ = run("git", "show", "HEAD:" + appcast)
        _, changed, _ = run("git", "status", "--porcelain", "--", appcast)
        _, ahead, _ = run("git", "rev-list", "--count", "origin/main..HEAD", "--", appcast)
        newest = max(entries(live), key=lambda e: e["build"], default=None)
        if newest and newest["title"] == version:
            ok("the live feed's newest entry is %s (build %d)" % (version, newest["build"]))
        else:
            if changed.strip():
                why = "%s has changes that aren't committed: commit and push it." % appcast
            elif ahead.strip() not in ("", "0"):
                why = "The commit with the feed isn't pushed (compared with origin/main as last fetched)."
            elif "<title>%s</title>" % version in committed:
                why = ("The feed is pushed, so the site hasn't deployed it yet. Give it a few minutes, or look at\n"
                       "https://github.com/%s/actions/workflows/resonance-site.yml" % repo)
            else:
                why = "%s has no entry for %s: release.sh adds it." % (appcast, version)
            fail("the live feed's newest entry is %s: installed copies aren't offered %s"
                 % (newest["title"] if newest else "missing", version), why)
            newest = None
        if code == 0 and live.strip() == committed.strip():
            ok("the live feed is the committed %s" % appcast)
        elif newest:
            warn("the live feed differs from the committed %s" % appcast,
                 "A later change to the feed may be waiting for the site to deploy.")
        if newest:
            if build and str(newest["build"]) != build:
                fail("the entry is build %d, the project is build %s" % (newest["build"], build))
            if newest["channel"] == channel:
                ok("on the %s channel" % channel if channel else "on the Stable channel (no channel tag)")
            else:
                fail("on the \"%s\" channel, not \"%s\"" % (newest["channel"] or "stable", channel or "stable"),
                     "People on the %s channel won't be offered it." % (channel or "Stable"))
            if newest["url"] == dmg_url:
                ok("it links to the release's %s" % name)
            else:
                fail("it links to %s" % newest["url"], "The release's file is at\n" + dmg_url)
            published = asset["size"] if asset else size
            if published is None:
                skip("the download's size is unknown, so the entry's length wasn't checked")
            elif newest["length"] == str(published):
                ok("its length matches the download (%s bytes)" % newest["length"])
            else:
                fail("its length is %s bytes, the download %d" % (newest["length"], published),
                     "The feed was made for another file than the one published: updates will fail.")
            if newest["notes"]:
                ok("it carries the release notes for the update dialog")
            else:
                warn("it has no release notes", "apple/release-notes/%s.md wasn't there when release.sh ran." % version)

# ---------------------------------------------------------------- Website
section("Website")
page, status = fetch(site)
if page is None or status != "200":
    fail("couldn't load %s (%s)" % (site, status if page is None else "HTTP " + status))
else:
    ok("%s loads" % site)

# What js/main.js does for the Download button: the newest published release
# with a build of the app, not the "fingerprints" one.
def app_asset(r):
    assets = [a for a in r.get("assets", []) if not a["name"].lower().startswith("fingerprints")]
    for ending in (".dmg", ".zip", ".pkg"):
        for a in assets:
            if a["name"].lower().endswith(ending):
                return a
    return None

if releases is None:
    skip("without GitHub's list of releases, the Download button wasn't checked")
else:
    offered = next((r for r in releases if not r.get("draft") and r.get("tag_name") != "fingerprints" and app_asset(r)), None)
    if offered and offered.get("tag_name") == tag and app_asset(offered)["name"] == name:
        ok("the Download button offers %s" % name)
    elif offered:
        fail("the Download button offers %s from %s" % (app_asset(offered)["name"], offered.get("tag_name")),
             "It takes the newest published release with a .dmg: %s isn't that yet." % tag)
    else:
        fail("the Download button has nothing to offer: no published release has a .dmg")

# ---------------------------------------------------------------- Result
print()
summary = "%d passed" % counts["ok"]
if counts["warn"]:
    summary += ", %d warning%s" % (counts["warn"], "" if counts["warn"] == 1 else "s")
if counts["skip"]:
    summary += ", %d skipped" % counts["skip"]
if counts["FAIL"]:
    print("%s is NOT fully released: %d failed, %s." % (version, counts["FAIL"], summary))
    sys.exit(1)
print("%s is released: %s." % (version, summary))
print("Not checked here: that the previous release installs it with Check for Updates….")
EOF
