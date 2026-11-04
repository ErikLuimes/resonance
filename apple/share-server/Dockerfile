# Resonance's share server. Build from apple/ (the card embeds the site's
# app icon):
#
#   docker build -f share-server/Dockerfile -t resonance-share .
#   docker run -p 8080:8080 -v /srv/resonance-share:/data \
#     -e BASE_URL=https://share.example resonance-share
#
# /data/index.json is the tune index; see README.md.
FROM rust:1-bookworm AS build
WORKDIR /src
COPY site/assets/icon-256.png site/assets/icon-256.png
COPY share-server share-server
RUN cd share-server && cargo build --release --locked

FROM debian:bookworm-slim
# Inter for the cards' text.
RUN apt-get update \
    && apt-get install -y --no-install-recommends fonts-inter ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/share-server/target/release/resonance-share-server /usr/local/bin/
ENV INDEX=/data/index.json PORT=8080
EXPOSE 8080
USER nobody
CMD ["resonance-share-server"]
