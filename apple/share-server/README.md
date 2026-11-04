# Resonance share server

Answers Resonance's shared tune links, `<BASE_URL>/t/<code>?s=2&v=85`, the
code being the tune's 12-character share code (the first 72 bits of its MD5
in base64url; `tune::short_code`). A whole MD5 works too; `s` is left out
for the start song:

- `GET /t/<code>` — a page with Open Graph and Twitter tags (title
  "Commando — Rob Hubbard", the preview card as `og:image`), the tune's
  fingerprint sphere turning (a canvas script with the app's maths; the
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

The app's Release builds share `https://useresonance.app` links (the
`SHARE_BASE_URL` build setting), so that's the `BASE_URL`. A website at
the same domain later can share it: route `/t/` and `/card/` to this
server and the rest to the site.

Locally, without Docker:

```bash
INDEX=index.json cargo run --release --manifest-path apple/share-server/Cargo.toml
```

`cargo test` checks the index format, the page's tags and the card.
