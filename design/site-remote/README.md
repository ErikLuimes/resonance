# The Resonance Remote page

A page for Resonance Remote, the iPhone and iPad app, at `useresonance.app/remote` and
`remote.useresonance.app`. Written 2026-11-15.

- [mockup.html](mockup.html): the page for review. Serve the repo root (launch config
  `site-mockups`, port 8644) and open `/design/site-remote/mockup.html`. It loads the real
  site's `styles.css` and media through `<base>`, so it looks like the live site.
- The real page is `apple/site/remote/index.html`, with its own styles in
  `apple/site/remote.css` and script in `apple/site/js/remote.js`. The Pages workflow
  publishes it with the rest of `apple/site`. Change the page there; the mockup stays as
  it was approved.

The page uses the Remote's own icon, `apple/site/assets/remote-icon-{256,512}.png`, exported
from its Icon Composer file in resonance-remote:

```bash
ictool ../resonance-remote/ios/ResonanceRemote/ResonanceRemote/AppIcon.icon --export-image --output-file apple/site/assets/remote-icon-512.png --platform iOS --rendition Default --width 512 --height 512 --scale 1
```

## How useresonance.app is served (checked 2026-11-15)

- **The website is GitHub Pages**, at `https://erikluimes.github.io/resonance/`, published
  from `apple/site` by `.github/workflows/resonance-site.yml`. It's plain static files, with no
  Jekyll. (`docs/` is Phosphor's old Jekyll site and isn't published.) The Pages site has no
  custom domain.
- **`useresonance.app` itself is the share server.** Cloudflare DNS, proxied (orange cloud),
  goes to the Hetzner server. There Apache, with a certbot certificate, proxies to the Docker
  container on `127.0.0.1:8787`. The container answers `/t/…`, `/card/…`,
  `/.well-known/apple-app-site-association` and `/healthz`. Everything else gets a 307 to
  `DOWNLOAD_URL`, which is the Pages site's home page (`apple/share-server/src/main.rs`,
  `router`).
- So today `https://useresonance.app/remote` lands on the home page, because the share server
  drops the path. `remote.useresonance.app` has no DNS record.

## The plan: redirects to the one real page

The page lives in one place, on GitHub Pages at `erikluimes.github.io/resonance/remote/`. Both
addresses redirect there.

**Why redirects and not the same content served twice.** GitHub Pages gives a repository one
custom domain, and it can't serve a subfolder as a subdomain. So serving the page itself at
`remote.useresonance.app` would mean keeping a second copy of the page on the Hetzner server,
which would drift from the site. Search engines would also see two copies. A redirect keeps
one page. It also matches how the domain's root already works.

**Why a gray-cloud record for the subdomain, straight to the Hetzner server.** Spanish ISPs
block Cloudflare's addresses during LaLiga matches. A DNS-only record skips Cloudflare. Apache
there redirects straight to GitHub Pages and never goes through the orange-clouded apex, so the
subdomain keeps working on match days. (`useresonance.app/remote` still goes dark then, like
the rest of the apex.) The record shows the server's address, but shmup.gg already points
straight at the same server, so nothing new is exposed.

**Temporary redirects (302/307), not permanent ones.** Browsers keep permanent redirects
forever. If the site later moves to `useresonance.app` itself, the subdomain has to be free to
point somewhere new. That's the same reason the share server's fallback is a 307.

### In the repo (built 2026-11-15)

1. The page: `apple/site/remote/index.html`, with `apple/site/remote.css` and
   `apple/site/js/remote.js`. The home page's footer links to it.
2. The share server: `/remote` and `/remote/` give a 307 to `<DOWNLOAD_URL>/remote/`,
   tested by `the_remote_goes_to_its_page_on_the_website`. Everything else still goes to
   the home page.

### Erik's steps

**1. Publish the page.** Push `main`. The "Resonance site" workflow deploys `apple/site`.
Then check that `https://erikluimes.github.io/resonance/remote/` loads.

**2. DNS, in Cloudflare (useresonance.app → DNS → Records → Add record):**

| Type | Name | Content | Proxy status | TTL |
| --- | --- | --- | --- | --- |
| A | `remote` | the Hetzner server's IPv4 (the one shmup.gg's A record has) | **DNS only** (gray cloud) | Auto |
| AAAA | `remote` | the server's IPv6, only if shmup.gg has an AAAA record | **DNS only** | Auto |

**3. Apache on the server (`ssh hetzner`).** Create
`/etc/apache2/sites-available/remote.useresonance.app.conf`:

```apache
<VirtualHost *:80>
    ServerName remote.useresonance.app
    Redirect temp / https://erikluimes.github.io/resonance/remote/
</VirtualHost>
```

Turn it on, check it and reload:

```bash
sudo a2ensite remote.useresonance.app && sudo apache2ctl configtest && sudo systemctl reload apache2
```

Then get the certificate. `.app` is on the HSTS preload list, so browsers only ever use
https, and the subdomain doesn't work at all until this step is done. Certbot copies the
redirect into the new `:443` site:

```bash
sudo certbot --apache -d remote.useresonance.app --redirect
```

**4. Deploy the share server** with the `/remote` route, using the steps in
`apple/share-server/README.md`, "Updating a server without a checkout".

**5. Check.** Both should answer with a redirect to
`https://erikluimes.github.io/resonance/remote/`:

```bash
curl -sI https://remote.useresonance.app/ | grep -iE '^(HTTP|location)'
```

```bash
curl -sI https://useresonance.app/remote | grep -iE '^(HTTP|location)'
```

Certbot's renewal timer already runs for the apex, and it renews this certificate too.

## Open

- The phone screens are recordings of the Remote in the iPhone 18 Pro Max simulator (iOS 27),
  paired with Resonance on the Mac, made 2026-11-15: `apple/site/media/remote-*.mp4` and
  their posters, converted with `apple/scripts/site-videos.sh` (`CROP=1320:2868:0:0
  WIDTH=640`). The raw takes are in `~/Documents/Resonance/site-recordings/remote/`. The
  picture comes from `xcrun simctl io <device> recordVideo`, and the sound from BlackHole 2ch
  through `sox`, recorded at the same time and joined with ffmpeg. The iPad is left out for
  now, because its layout needs more work.
- No App Store link until there is one. The page says "Coming soon to the App Store" without
  a link. When the app is live, that becomes the App Store badge, and the Remote's
  `useresonance.app` button can point at `/remote`.
- Later, a QR code could hold a `useresonance.app` link (PLAN.md in resonance-remote). That
  would need `/remote/*` or a new path in the association file, and it's separate from this
  page.
