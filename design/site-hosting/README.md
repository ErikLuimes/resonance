# The website on useresonance.app

Plan, written 2026-11-15. Nothing here is built yet.

**On hold (2026-11-15):** Erik first upgrades the server to the next Ubuntu
LTS, and the VPS service is changing too. The migration waits for that and
may take about two weeks. When it resumes, read the server's real Apache
files first (the sketch below predates the upgrade) and make this plan solid
before any step is taken.

The website moves from GitHub Pages to useresonance.app itself, served by the
Hetzner server that already runs the share server. Resonance Remote gets the
two pages the App Store needs: support and privacy.

Erik decided it's a clean cut. There are no users yet and the app is in alpha,
so the old address doesn't live on: no mirror on GitHub Pages and no
redirects from it. The one exception is the update feed, which moves with a
bridge release (below), so installed builds follow it to the new address.

## Why

- **The App Store needs two pages.** Every app needs a Support URL, which
  Apple says must lead to real contact details. Every app also needs a
  Privacy Policy URL. Both go into App Store Connect and should stay the same
  for years. `useresonance.app/remote/support/` and
  `useresonance.app/remote/privacy/` belong to the domain, not to a GitHub
  username and repository name.
- **GitHub Pages' terms.** GitHub says Pages isn't to be used "as a free
  web-hosting service to run your online business", or for a site mainly
  meant for selling things or for paid online services. A page for an app
  the App Store sells is common there, but on our own server the question
  doesn't come up.
- **One address.** Today useresonance.app sends visitors to
  `erikluimes.github.io/resonance/`, so the address bar changes.
- **Match days.** The domain sits behind Cloudflare's proxy, which Spanish
  ISPs block during LaLiga matches. Serving everything from our own server
  lets the record go DNS-only, and the share links keep working on match
  days too.

## How it's served now (checked 2026-11-15)

- `useresonance.app`: Cloudflare, proxied, to the Hetzner server. Apache
  there (TLS from certbot) proxies everything to the share-server container
  on `127.0.0.1:8787`. The container answers `/t/`, `/card/`, `/card.jpg`,
  `/.well-known/apple-app-site-association`, `/healthz` and `/remote`, and
  sends anything else to the GitHub Pages site with a 307.
- The website: GitHub Pages, published from `apple/site` by
  `.github/workflows/resonance-site.yml` on each push to main.
- The update feed: `SPARKLE_FEED_URL` in the project is
  `https://erikluimes.github.io/resonance/appcast.xml`, so it's built into
  every shipped app.
- The stats tool (private, `resonance-stats`) reads the `/t/` lines from
  Apache's `other_vhosts_access.log` through its own SSH account. Its
  pattern starts with `useresonance.app:<port>`.
- I couldn't read the server's Apache files from here (my SSH key isn't
  accepted), so the Apache setup below is a sketch to fit to the real files.

## How it will be served

Apache on the Hetzner server, for `useresonance.app`:

- **Files:** `apple/site` from a checkout of the public repository, at
  `/srv/resonance-site/repo/apple/site`.
- **Passed to the container, as now:** `/t/`, `/card/`, `/card.jpg`,
  `/.well-known/apple-app-site-association`, `/healthz`.
- **Everything else:** the files. A path that doesn't exist gets the site's
  own 404 page.
- `remote.useresonance.app` redirects to `https://useresonance.app/remote/`.
  Now that the page has its permanent home, this can be a 301.

### Getting the site onto the server: the server pulls

A systemd timer runs every five minutes and brings the checkout up to date
with `main`. The checkout is sparse (only `apple/site`) and blobless, so it
stays small.

Why pull rather than push from a GitHub Action: no key to the server lives
in GitHub, and nothing in GitHub can write to the server. The cost is a delay
of up to five minutes after a push, which matters only for the appcast, and
`publish.sh` already pushes the appcast last.

### Apache, a sketch

Fit this into the existing site file for useresonance.app; certbot's
`SSLCertificate…` lines stay as they are. Keep the default log
(`other_vhosts_access.log`) and don't add a `CustomLog`, so the stats feed
keeps finding its lines.

```apache
<VirtualHost *:443>
    ServerName useresonance.app
    DocumentRoot /srv/resonance-site/repo/apple/site

    <Directory /srv/resonance-site/repo/apple/site>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>
    ErrorDocument 404 /404.html

    # The share server, as before.
    ProxyPreserveHost On
    ProxyPass        /t/   http://127.0.0.1:8787/t/
    ProxyPassReverse /t/   http://127.0.0.1:8787/t/
    ProxyPass        /card/    http://127.0.0.1:8787/card/
    ProxyPass        /card.jpg http://127.0.0.1:8787/card.jpg
    ProxyPass        /.well-known/apple-app-site-association http://127.0.0.1:8787/.well-known/apple-app-site-association
    ProxyPass        /healthz  http://127.0.0.1:8787/healthz

    # Pages and the feed are always checked; everything else carries ?v= or
    # changes rarely.
    <FilesMatch "\.(html|xml)$">
        Header set Cache-Control "no-cache"
    </FilesMatch>
    <FilesMatch "\.(css|js|jpg|png|webp|mp4|svg)$">
        Header set Cache-Control "public, max-age=86400"
    </FilesMatch>
    AddOutputFilterByType DEFLATE text/html text/css text/javascript application/javascript application/xml image/svg+xml
</VirtualHost>
```

Modules: `proxy`, `proxy_http`, `headers`, `deflate` (the first two are
already on).

## Changes in the repository (Claude can do these)

1. **The address.** Replace `https://erikluimes.github.io/resonance/` with
   `https://useresonance.app/` in:
   - the site's `og:url`, `og:image` and `canonical` tags: `index.html`,
     `remote/index.html`, the twelve `v/*/index.html`
   - `design/site-sharing/make-cards.py` (`BASE`)
   - the Help window's website link (`HelpView.swift`)
   - `.github/README.md`
   - the share server's `DOWNLOAD_URL` default and its tests
2. **The update feed.** Set `SPARKLE_FEED_URL` to
   `https://useresonance.app/appcast.xml` and update `UpdaterTests.swift`.
   The next release becomes the bridge (see "Moving the update feed").
3. **A 404 page:** `apple/site/404.html`, in the site's look.
4. **Retire GitHub Pages,** but only after the bridge release: delete
   `.github/workflows/resonance-site.yml`, and Erik turns Pages off in the
   repository's settings. Until then the workflow keeps publishing
   `apple/site`, the appcast included, so the old address still answers.
5. **The share server:** drop the `/remote` route and its test, since Apache
   serves that folder now. Its fallback redirect stays for anything the proxy
   still sends it.
6. **The Remote's pages,** each a mockup first:
   - `apple/site/remote/support/`: a contact email, common questions (needs
     a Mac with Resonance; same network; pairing; Listen; what to do when
     the Mac isn't found), and pairing help.
   - `apple/site/remote/privacy/`: see below.
   - Link both from the Remote page's footer, and from the app's Connection
     sheet, where the `useresonance.app` button already is.
7. **Docs:** `apple/share-server/README.md` (routing now happens in
   Apache), `design/site-remote/README.md` (the subdomain now points at the
   domain), and a line in `CLAUDE.md`'s design docs.

### What the privacy page says (facts to confirm)

- Resonance Remote collects no data. No account, analytics, ads or tracking,
  and no server of ours in between. App Store label: Data Not Collected.
- It talks only to the Mac it's paired with, directly over the local
  network, encrypted (TLS with a pre-shared key; the audio for Listen is
  sealed with ChaCha20-Poly1305).
- Pairing keys stay in the Keychain on the device and the Mac. With "Connect
  devices on your Apple Account" on, the Mac's key syncs through iCloud
  Keychain, end to end encrypted by Apple.
- The camera is used only to scan the pairing code; nothing is stored.
- The Mac app sends nothing about you either. Update checks don't include
  system profiling (`SUEnableSystemProfiling` is off).
- Shared links: opening one asks our server for that tune's page. The server
  keeps a standard access log; Erik's stats read only the `/t/` lines, with
  each visitor address replaced by a keyed hash.
- The website counts visits with GoatCounter, without cookies.
- New since going DNS-only: the access log now holds visitors' real
  addresses instead of Cloudflare's. Say how long the logs are kept
  (logrotate's default on Ubuntu is 14 days).

## Moving the update feed: a bridge release

Sparkle reads the feed's address from the app's own Info.plist (`SUFeedURL`,
filled from `SPARKLE_FEED_URL`), and nothing in `Updater.swift` overrides it.
So an installed app follows whatever address the build it updated to carries:

1. The server serves the site, `appcast.xml` included, at
   `https://useresonance.app/`. GitHub Pages still publishes the same
   `apple/site` on each push, so both addresses serve the same file from
   the same commit.
2. The next release (say alpha.9) is built with the new `SPARKLE_FEED_URL`.
   `publish.sh` adds its entry to `apple/site/appcast.xml` and pushes as
   usual, and that one file reaches both places.
3. Installed builds still ask GitHub Pages, find alpha.9 there, and install
   it. Alpha.9 and everything after asks `useresonance.app`.
4. Once your own Macs (and any testers) run alpha.9 or later, delete the
   Pages workflow and turn Pages off. A build older than alpha.9 that never
   updated stops finding updates then; reinstalling fixes it.

Things to keep while both addresses serve the feed:

- The bridge entry must be on a channel the installed builds follow. Alpha
  builds follow alpha, so an alpha release reaches them all.
- Sparkle checks the EdDSA signature, not where the feed lives, so nothing
  about signing changes.
- The appcast reaches the server up to five minutes after the push (the
  timer). The old address is GitHub's usual minute or two.

## Erik's steps, in order

1. **The checkout and timer on the server.** Claude writes the exact
   commands and the systemd units into this file before you start.
2. **Apache:** add the files and the proxy lines above to the
   useresonance.app site, then `sudo apache2ctl configtest` and
   `sudo systemctl reload apache2`. Test before touching DNS, from the Mac:
   `curl -sI --resolve useresonance.app:443:<server IP> https://useresonance.app/`
   should answer 200 from Apache. `/t/<code>` should still give the tune
   page, and the association file should still give a 200.
3. **Cloudflare:** set the `useresonance.app` record to DNS only (gray
   cloud). Add `remote` as DNS only too. Then
   `sudo certbot --apache -d remote.useresonance.app --redirect`, and the
   redirect vhost from `design/site-remote/README.md`, pointing at
   `https://useresonance.app/remote/`.
4. **Certificate renewal:** once the record is DNS only, certbot's HTTP
   check reaches the server directly. Run `sudo certbot renew --dry-run`
   once to confirm.
5. **Apple's link file:** check that
   `https://app-site-association.cdn-apple.com/a/v1/useresonance.app` still
   returns it; Apple refreshes every few hours.
6. **Push** the repository changes. GitHub Pages keeps publishing for now.
7. **The share server:** redeploy with the new `DOWNLOAD_URL` default, or
   set `-e DOWNLOAD_URL=https://useresonance.app/` in the `docker run` line.
8. **The bridge release:** publish the next release as usual. Check that
   both `https://erikluimes.github.io/resonance/appcast.xml` and
   `https://useresonance.app/appcast.xml` list it, and that your Mac updates
   to it.
9. **Retire Pages:** once your Macs run the bridge release, Claude deletes
   the workflow, you push, and you turn Pages off in the repository's
   settings.
10. **Stats:** `ssh resonance-stats log | head -2` should still print `/t/`
    lines.

Undo: set the Cloudflare record back to proxied, and put the old Apache site
file back. Keep a copy of it before step 2.

## Not decided

- The support contact: which email address goes on the page (not a personal
  one, unless you want that). Whether to show a postal address: Apple asks
  for one where local law requires it, and an EU trader's address shows on
  the App Store anyway.
- Whether the Remote is free or paid. It doesn't change this plan, but the
  support page's questions differ.
- `www.useresonance.app`: it has no record today. Add one that redirects to
  the domain, or leave it out.
