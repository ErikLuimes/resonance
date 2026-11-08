# Resonance share server

Answers Resonance's shared tune links, `<BASE_URL>/t/<code>?s=2&v=85`, the
code being the tune's 12-character share code (the first 72 bits of its MD5
in base64url; `tune::short_code`). A whole MD5 works too; `s` is left out
for the start song:

- `GET /t/<code>` — a page with Open Graph and Twitter tags (title
  "Commando — Rob Hubbard", the preview card as `og:image`), the tune's
  fingerprint sphere turning (a canvas script with the app's math; the
  card instead when the index has no fingerprint), an
  **Open in Resonance** button (`resonance://tune/<md5>?s=&v=&p=&t=&a=`)
  and **Download Resonance**. Unknown MD5s get a 404 page with the generic
  card that still offers Open in Resonance (the receiver's collection may
  be newer than the index).
- `GET /card/<code>.jpg?s=2` — the preview card for a subtune, an
  800×420 JPEG (about 25 KB)
  (title, composer, facts, strongest traits, the fingerprint barcode),
  rendered with resvg the first time it's asked for and kept on disk in
  `CARD_DIR`.
- `GET /card.jpg` — Resonance's own card.
- `GET /.well-known/apple-app-site-association` — tells macOS the app opens
  `/t/*` links directly. Apple's servers fetch it, and don't follow redirects,
  so a proxy or firewall mustn't redirect or challenge them there. A new
  version can take a day to reach Macs, through Apple's cache.
- `GET /healthz`. Everything else (`/`, `/download`, …) redirects to the website (`DOWNLOAD_URL`), so the domain leads there.

Everything it shows comes from the tune index; it fetches nothing.

## The index

Build it on a Mac with the collection and the app's fingerprints (copy the
store first: opening it may convert it):

```bash
cp ~/Library/Application\ Support/Resonance/fingerprints.sqlite /tmp/fp.sqlite
```

```bash
cd apple && cargo run -p phosphor-apple --release --example share_index -- ~/Library/Application\ Support/Resonance/HVSC /tmp/fp.sqlite > index.json
```

Rebuild and upload it after each HVSC release, then restart the
container. The published fingerprint set (`fingerprints-x1.zip` on the
`fingerprints` release, unzipped) works as the store too.

## Run it

Build the image with `apple/` as the context (the card uses the website's app icon), from the repository root:

```bash
docker build -f apple/share-server/Dockerfile -t resonance-share apple
```

```bash
docker run -d --name resonance-share --restart unless-stopped -p 127.0.0.1:8080:8080 -v /srv/resonance-share:/data -e BASE_URL=https://useresonance.app resonance-share
```

with `index.json` in `/srv/resonance-share`, behind your reverse proxy
(TLS). The container runs as `nobody`, which must be able to write
`cards/` there (`sudo chown -R 65534 /srv/resonance-share`); if it can't,
cards are rendered on every request instead. Settings, as environment variables:

| Variable | Default | |
| --- | --- | --- |
| `BASE_URL` | `http://localhost:<PORT>` | public address, used in the page's links and tags |
| `INDEX` | `/data/index.json` | the tune index |
| `DOWNLOAD_URL` | the website | Download Resonance |
| `PORT` | `8080` | |
| `CARD_DIR` | `/data/cards` | rendered cards, in a folder per card version and HVSC release (`v1-hvsc85`); delete old folders after a new index or look |
| `FONT_DIR` | | extra fonts for the cards (the image has Inter) |
| `APPLE_APP_ID` | `R4D8QN85WK.app.useresonance.resonance` | the app its links open: team ID, then bundle identifier |

The app's Release builds share `https://useresonance.app` links (the
`SHARE_BASE_URL` build setting), so that's the `BASE_URL`. A website at
the same domain later can share it: route `/t/` and `/card/` to this
server and the rest to the site.

## Updating a server without a checkout

useresonance.app's server has no copy of this repository. Its image is built
from a bundle made on a Mac and unpacked in `/srv/resonance-share`: `build/`
holds the server's code and the app icon, and `data/` holds `index.json` and
the rendered cards. The container listens on `127.0.0.1:8787`, which Apache
proxies to with TLS from certbot. Docker needs `sudo` there.

On the Mac, from `apple/`, make the bundle (code only, so the server's
`index.json` and cards stay):

```bash
B=$(mktemp -d) && mkdir -p $B/build/site/assets && rsync -a --exclude target share-server $B/build/ && cp site/assets/icon-256.png $B/build/site/assets/ && tar -czf ~/Desktop/resonance-share-update.tgz -C $B build
```

Still on the Mac, copy it over and log in (`you@yourserver` is your own
login):

```bash
scp ~/Desktop/resonance-share-update.tgz you@yourserver:/tmp/
```

```bash
ssh you@yourserver
```

On the server, put the new code in place:

```bash
sudo rm -rf /srv/resonance-share/build && sudo tar -xzf /tmp/resonance-share-update.tgz -C /srv/resonance-share
```

Build the image (a few minutes):

```bash
sudo docker build -f /srv/resonance-share/build/share-server/Dockerfile -t resonance-share /srv/resonance-share/build
```

Swap the running container for one from the new image:

```bash
sudo docker rm -f resonance-share && sudo docker run -d --name resonance-share --restart unless-stopped -p 127.0.0.1:8787:8080 -v /srv/resonance-share/data:/data -e BASE_URL=https://useresonance.app resonance-share
```

Check that it answers. This prints the association file's JSON, with
`R4D8QN85WK.app.useresonance.resonance` in it:

```bash
curl -s http://127.0.0.1:8787/.well-known/apple-app-site-association
```

A new `index.json`, after an HVSC release, goes to `/srv/resonance-share/data/`
instead; then `sudo docker restart resonance-share`, and delete the old card
folders in `data/cards/`.

From anywhere, the public file and Apple's copy of it, which Apple refreshes
every few hours, should both return it with a 200:

```bash
curl -i https://useresonance.app/.well-known/apple-app-site-association
```

```bash
curl -i https://app-site-association.cdn-apple.com/a/v1/useresonance.app
```

## Locally

Without Docker:

```bash
INDEX=index.json cargo run --release --manifest-path apple/share-server/Cargo.toml
```

`cargo test` checks the index format, the page's tags and the card.
