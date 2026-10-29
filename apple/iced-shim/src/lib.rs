//! `src/hvsc_sync.rs` imports `iced::futures::StreamExt`. Iced re-exports
//! `futures`, so pointing that path at `futures-util` is behaviour-identical
//! and keeps the real GUI toolkit out of the macOS engine build.
pub use futures_util as futures;
