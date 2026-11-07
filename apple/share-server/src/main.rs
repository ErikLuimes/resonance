//! Resonance's share server. A shared link is `<BASE_URL>/t/<code>?s=2&v=85`,
//! the code being the tune's 12-character share code (`tune::short_code`;
//! a whole MD5 works too):
//! the page carries Open Graph tags so chat apps show a preview card, and
//! hands the tune to the app through `resonance://`. The association file
//! lets macOS open those links in the app directly.
//!
//! Environment:
//!   INDEX         the tune index (default /data/index.json), built with
//!                 `cargo run -p phosphor-apple --example share_index`
//!   BASE_URL      this server's public address, e.g. https://share.example
//!   DOWNLOAD_URL  Download Resonance (default: the website)
//!   PORT          default 8080
//!   CARD_DIR      where rendered cards are kept (default /data/cards); one
//!                 folder per card version and HVSC release, so a new index
//!                 or look renders them again. Old folders can be deleted.
//!   FONT_DIR      extra fonts for the cards (the system's are loaded too)
//!   APPLE_APP_ID  the app its links open, <team id>.<bundle identifier>

mod card;
mod page;
mod tune;

use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::get;
use axum::Router;
use serde::Deserialize;

use tune::Index;

struct App {
    index: Index,
    base: String,
    download: String,
    /// Rendered cards, `<md5>-<subtune>.jpg`; None when it can't be made.
    card_dir: Option<PathBuf>,
    generic_card: Vec<u8>,
    apple_app_id: String,
}

#[derive(Deserialize)]
struct LinkQuery {
    s: Option<u16>,
    v: Option<u32>,
}

#[tokio::main]
async fn main() {
    let env = |key: &str, default: &str| std::env::var(key).unwrap_or_else(|_| default.to_string());
    let index_path = env("INDEX", "/data/index.json");
    let index = Index::load(std::path::Path::new(&index_path)).unwrap_or_else(|e| {
        eprintln!("Can't read the tune index: {e}");
        std::process::exit(1);
    });
    let port = env("PORT", "8080");
    let app = Arc::new(App {
        base: env("BASE_URL", &format!("http://localhost:{port}")).trim_end_matches('/').to_string(),
        download: env("DOWNLOAD_URL", "https://erikluimes.github.io/resonance/"),
        card_dir: card_dir(&env("CARD_DIR", "/data/cards"), index.hvsc),
        generic_card: card::jpeg(&card::svg(None, None)).expect("the generic card renders"),
        apple_app_id: env("APPLE_APP_ID", "R4D8QN85WK.app.useresonance.resonance"),
        index,
    });
    eprintln!(
        "HVSC {} index: {} tunes; links at {}/t/<code>",
        app.index.hvsc.map_or("?".into(), |v| v.to_string()),
        app.index.tunes.len(),
        app.base
    );
    let routes = router(app);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.expect("bind");
    axum::serve(listener, routes)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .expect("serve");
}

fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/t/{md5}", get(tune_page))
        .route("/card/{file}", get(tune_card))
        .route("/card.jpg", get(generic_card))
        .route("/healthz", get(|| async { "ok" }))
        // Answered here, not redirected: Apple's fetch doesn't follow redirects.
        .route("/.well-known/apple-app-site-association", get(app_site_association))
        // The domain's other addresses lead to the website: its root, and
        // anything else typed or linked there. Temporary, so a site of its
        // own can take the root later.
        .fallback(|State(app): State<Arc<App>>| async move { Redirect::temporary(&app.download) })
        .with_state(app)
}

/// Tells macOS that Resonance opens this server's tune links, and only those.
async fn app_site_association(State(app): State<Arc<App>>) -> Response {
    let body = serde_json::json!({
        "applinks": {
            "details": [{
                "appIDs": [app.apple_app_id],
                "components": [{ "/": "/t/*", "comment": "Shared tunes" }],
            }],
        },
    });
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

async fn tune_page(State(app): State<Arc<App>>, Path(raw): Path<String>, Query(q): Query<LinkQuery>) -> Response {
    let Some(key) = tune::Key::parse(&raw) else { return StatusCode::NOT_FOUND.into_response() };
    let site = page::Site { base: &app.base, download: &app.download };
    match app.index.find(&key) {
        Some((md5, tune)) => {
            let code = tune::short_code(md5).unwrap_or_else(|| md5.to_string());
            let link = page::Link { key: md5, code: &code, subtune: tune.subtune(q.s), start: tune.start_song, hvsc: q.v };
            cached(Html(page::tune_page(&site, &link, tune)).into_response())
        }
        None => {
            let code = match &key {
                tune::Key::Md5(md5) => tune::short_code(md5).unwrap_or_else(|| md5.clone()),
                tune::Key::Code(code) => code.clone(),
            };
            let link = page::Link { key: key.as_str(), code: &code, subtune: q.s.unwrap_or(0), start: 0, hvsc: q.v };
            let mut response = Html(page::unknown_page(&site, &link)).into_response();
            *response.status_mut() = StatusCode::NOT_FOUND;
            response
        }
    }
}

async fn tune_card(State(app): State<Arc<App>>, Path(file): Path<String>, Query(q): Query<LinkQuery>) -> Response {
    let Some(key) = file.strip_suffix(".jpg").and_then(tune::Key::parse) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some((md5, tune)) = app.index.find(&key) else { return jpeg(app.generic_card.clone()) };
    let subtune = tune.subtune(q.s);
    let cached_file = app.card_dir.as_ref().map(|dir| dir.join(format!("{md5}-{subtune}.jpg")));
    if let Some(bytes) = cached_file.as_ref().and_then(|f| std::fs::read(f).ok()) {
        return jpeg(bytes);
    }
    let svg = card::svg(Some((tune, subtune)), app.index.hvsc);
    match tokio::task::spawn_blocking(move || card::jpeg(&svg)).await {
        Ok(Ok(bytes)) => {
            if let Some(file) = cached_file {
                // Written aside and renamed, so a reader never sees half a card.
                let part = file.with_extension("part");
                if std::fs::write(&part, &bytes).is_ok() {
                    let _ = std::fs::rename(&part, &file);
                }
            }
            jpeg(bytes)
        }
        _ => jpeg(app.generic_card.clone()),
    }
}

async fn generic_card(State(app): State<Arc<App>>) -> Response {
    jpeg(app.generic_card.clone())
}

fn jpeg(bytes: Vec<u8>) -> Response {
    cached(([(header::CONTENT_TYPE, "image/jpeg")], bytes).into_response())
}

/// `<root>/v<card version>-hvsc<release>`, created; None (cards rendered
/// every time) when it can't be.
fn card_dir(root: &str, hvsc: Option<u32>) -> Option<PathBuf> {
    let dir = PathBuf::from(root).join(format!(
        "v{}-hvsc{}",
        card::VERSION,
        hvsc.map_or("unknown".into(), |v| v.to_string())
    ));
    match std::fs::create_dir_all(&dir) {
        Ok(()) => Some(dir),
        Err(e) => {
            eprintln!("Not keeping cards in {}: {e}", dir.display());
            None
        }
    }
}

/// A tune's page and card only change with the index: a day is fine.
fn cached(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "public, max-age=86400".parse().unwrap());
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    fn app() -> Router {
        router(Arc::new(App {
            index: Index::new(Some(85), Default::default()),
            base: "https://useresonance.app".into(),
            download: "https://erikluimes.github.io/resonance/".into(),
            card_dir: None,
            generic_card: vec![0xFF, 0xD8, 0xFF],
            apple_app_id: "TEAM.app.useresonance.resonance".into(),
        }))
    }

    async fn get(path: &str) -> Response {
        app().oneshot(Request::get(path).body(Body::empty()).unwrap()).await.unwrap()
    }

    #[tokio::test]
    async fn everything_but_links_and_cards_goes_to_the_website() {
        for path in ["/", "/download", "/appcast.xml", "/t/"] {
            let response = get(path).await;
            assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT, "{path}");
            assert_eq!(response.headers()[header::LOCATION], "https://erikluimes.github.io/resonance/");
        }
    }

    #[tokio::test]
    async fn the_association_file_names_the_app_and_only_tune_links() {
        let response = get("/.well-known/apple-app-site-association").await;
        assert_eq!(response.status(), StatusCode::OK, "Apple's fetch doesn't follow redirects");
        assert_eq!(response.headers()[header::CONTENT_TYPE], "application/json");
        let body = axum::body::to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let file: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let details = &file["applinks"]["details"][0];
        assert_eq!(details["appIDs"][0], "TEAM.app.useresonance.resonance");
        assert_eq!(details["components"].as_array().unwrap().len(), 1);
        assert_eq!(details["components"][0]["/"], "/t/*");
    }

    #[tokio::test]
    async fn links_and_cards_are_answered_here() {
        let unknown = get("/t/ffffffffffffffffffffffffffffffff").await;
        assert_eq!(unknown.status(), StatusCode::NOT_FOUND, "an unknown tune's page, not a redirect");
        assert_eq!(get("/t/bQGey6gxqfhT").await.status(), StatusCode::NOT_FOUND, "a code it doesn't know");
        assert_eq!(get("/t/nothex").await.status(), StatusCode::NOT_FOUND);
        assert_eq!(get("/card.jpg").await.status(), StatusCode::OK);
        assert_eq!(get("/healthz").await.status(), StatusCode::OK);
    }
}
