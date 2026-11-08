//! `resonance mcp`: Resonance as a Model Context Protocol server, so an assistant
//! like Claude can search, play and make playlists. JSON-RPC, one object per line
//! on stdin and stdout; stdout is only ever the protocol.
//!
//! Nothing here deletes anything: an assistant can add to your playlists and take
//! tunes out, but deleting a playlist stays yours to do.

use crate::client::Client;
use serde_json::{json, Value};
use std::io::{BufRead, Write};

/// Offered when a client asks for a version this doesn't know.
const PROTOCOL_VERSION: &str = "2025-06-18";
const KNOWN_VERSIONS: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

const INSTRUCTIONS: &str = "Resonance is a Commodore 64 SID music player for the Mac, with the High Voltage \
SID Collection (about 60,000 tunes). Its fingerprints know how tunes sound. Use `describe` for a mood or style \
in words, `sounds_like` for tunes like one you have, and `search` for a title or composer. Tunes are identified \
by their file paths, as the other tools return them.";

/// Where tool calls go: the app, or a stand-in in tests.
pub trait Backend {
    fn call(&mut self, cmd: &str, args: Value) -> Result<Value, String>;
}

/// Connects when first needed and once more if the app restarted.
#[derive(Default)]
pub struct AppBackend {
    client: Option<Client>,
}

impl Backend for AppBackend {
    fn call(&mut self, cmd: &str, args: Value) -> Result<Value, String> {
        if self.client.is_none() {
            self.client = Some(Client::connect()?);
        }
        let client = self.client.as_mut().expect("just connected");
        match client.call(cmd, args.clone()) {
            Err(error) if error.starts_with("Lost touch") => {
                let mut fresh = Client::connect()?;
                let answer = fresh.call(cmd, args);
                self.client = Some(fresh);
                answer
            }
            answer => answer,
        }
    }
}

struct Tool {
    name: &'static str,
    description: &'static str,
    read_only: bool,
    /// The input's properties, and which are required.
    properties: fn() -> Value,
    required: &'static [&'static str],
    /// The app's command.
    cmd: &'static str,
    /// From the tool's arguments to the command's.
    args: fn(&Value) -> Value,
}

fn none() -> Value {
    json!({})
}

fn same(args: &Value) -> Value {
    args.clone()
}

fn no_args(_: &Value) -> Value {
    json!({})
}

const PATH: &str = "A tune's file path, as other tools return it";

fn tools() -> Vec<Tool> {
    vec![
        Tool {
            name: "now_playing",
            description: "What's playing: the tune, composer, position and whether it's paused.",
            read_only: true,
            properties: none,
            required: &[],
            cmd: "status",
            args: no_args,
        },
        Tool {
            name: "search",
            description: "Search the collection by tune title or composer. Doesn't play anything.",
            read_only: true,
            properties: || {
                json!({
                    "query": { "type": "string", "description": "Title or composer words, like \"hubbard commando\"" },
                    "limit": { "type": "integer", "description": "At most this many tunes (default 20)" },
                })
            },
            required: &["query"],
            cmd: "search",
            args: |a| json!({ "text": a["query"], "limit": a.get("limit").cloned().unwrap_or(json!(20)) }),
        },
        Tool {
            name: "sounds_like",
            description: "The tunes that sound most like one, by fingerprint, with how alike each is (score 0-1). \
                          Uses the tune playing unless given a path.",
            read_only: false,
            properties: || {
                json!({
                    "path": { "type": "string", "description": PATH },
                    "limit": { "type": "integer", "description": "At most this many tunes (default 10)" },
                    "play": { "type": "boolean", "description": "Also play them, most alike first (default false)" },
                })
            },
            required: &[],
            cmd: "like",
            args: |a| {
                let mut args = json!({
                    "limit": a.get("limit").cloned().unwrap_or(json!(10)),
                    "play": a.get("play").cloned().unwrap_or(json!(false)),
                });
                if let Some(path) = a.get("path") {
                    args["path"] = path.clone();
                }
                args
            },
        },
        Tool {
            name: "describe",
            description: "Make a Smart Playlist from a sentence and play it. Understands composers, years, lengths and \
                          sounds, such as \"fast arpeggios from 1987\" or \"an hour of Rob Hubbard without digi samples\".",
            read_only: false,
            properties: || {
                json!({
                    "text": { "type": "string", "description": "What to hear, in words" },
                    "play": { "type": "boolean", "description": "Play the result (default true)" },
                })
            },
            required: &["text"],
            cmd: "describe",
            args: same,
        },
        Tool {
            name: "recently_played",
            description: "What the user has been listening to, most recent first, with when each tune last played \
                          (playedAt, seconds since 1970). Use it to learn their taste, or what they've been neglecting.",
            read_only: true,
            properties: || json!({ "limit": { "type": "integer", "description": "At most this many tunes (default 50)" } }),
            required: &[],
            cmd: "recent",
            args: |a| json!({ "limit": a.get("limit").cloned().unwrap_or(json!(50)) }),
        },
        Tool {
            name: "sound_of_tune",
            description: "How a tune sounds, from its fingerprint: a sentence and its traits. Uses the tune playing \
                          unless given a path.",
            read_only: true,
            properties: || json!({ "path": { "type": "string", "description": PATH } }),
            required: &[],
            cmd: "sound",
            args: same,
        },
        Tool {
            name: "sound_drift",
            description: "Start an endless radio from the tune playing, or from a path: each tune sounds like the one \
                          before, so it slowly wanders across the collection.",
            read_only: false,
            properties: || json!({ "path": { "type": "string", "description": PATH } }),
            required: &[],
            cmd: "drift",
            args: same,
        },
        Tool {
            name: "play_tunes",
            description: "Play these tunes in this order, from the first or from `start`.",
            read_only: false,
            properties: || {
                json!({
                    "paths": { "type": "array", "items": { "type": "string" }, "description": "Tunes' file paths" },
                    "start": { "type": "string", "description": "Which of them to start with" },
                })
            },
            required: &["paths"],
            cmd: "play",
            args: same,
        },
        Tool {
            name: "surprise_me",
            description: "Play random tunes from all of the collection until something else plays.",
            read_only: false,
            properties: none,
            required: &[],
            cmd: "surprise",
            args: no_args,
        },
        Tool {
            name: "pause",
            description: "Pause.",
            read_only: false,
            properties: none,
            required: &[],
            cmd: "pause",
            args: no_args,
        },
        Tool {
            name: "resume",
            description: "Carry on playing.",
            read_only: false,
            properties: none,
            required: &[],
            cmd: "play",
            args: no_args,
        },
        Tool {
            name: "next_track",
            description: "Skip to the next tune.",
            read_only: false,
            properties: none,
            required: &[],
            cmd: "next",
            args: no_args,
        },
        Tool {
            name: "previous_track",
            description: "Go back to the previous tune.",
            read_only: false,
            properties: none,
            required: &[],
            cmd: "prev",
            args: no_args,
        },
        Tool {
            name: "favorite_this_tune",
            description: "Add the tune playing to Favorites.",
            read_only: false,
            properties: none,
            required: &[],
            cmd: "fav",
            args: no_args,
        },
        Tool {
            name: "list_playlists",
            description: "Favorites and the user's playlists, with how many tunes each holds.",
            read_only: true,
            properties: none,
            required: &[],
            cmd: "playlist.list",
            args: no_args,
        },
        Tool {
            name: "show_playlist",
            description: "The tunes in Favorites or one of the user's playlists.",
            read_only: true,
            properties: || json!({ "name": { "type": "string" } }),
            required: &["name"],
            cmd: "playlist.show",
            args: same,
        },
        Tool {
            name: "hvsc_collection",
            description: "The HVSC collection on this Mac: its release, what the last update added, and HVSC's own curated playlists (like \"HVSC Favorite Top 100\"), with how many tunes each holds.",
            read_only: true,
            properties: none,
            required: &[],
            cmd: "hvsc.info",
            args: no_args,
        },
        Tool {
            name: "show_hvsc_playlist",
            description: "The tunes in one of HVSC's curated playlists, by its name as hvsc_collection lists it.",
            read_only: true,
            properties: || json!({ "name": { "type": "string", "description": "Like \"HVSC Favorite Top 100\"" } }),
            required: &["name"],
            cmd: "hvsc.playlist",
            args: same,
        },
        Tool {
            name: "play_hvsc_playlist",
            description: "Play one of HVSC's curated playlists, by its name as hvsc_collection lists it.",
            read_only: false,
            properties: || json!({ "name": { "type": "string" } }),
            required: &["name"],
            cmd: "hvsc.playlist.play",
            args: same,
        },
        Tool {
            name: "play_playlist",
            description: "Play Favorites or one of the user's playlists.",
            read_only: false,
            properties: || json!({ "name": { "type": "string" } }),
            required: &["name"],
            cmd: "playlist.play",
            args: same,
        },
        Tool {
            name: "create_playlist",
            description: "Make a new playlist, optionally with tunes in it.",
            read_only: false,
            properties: || {
                json!({
                    "name": { "type": "string" },
                    "paths": { "type": "array", "items": { "type": "string" } },
                })
            },
            required: &["name"],
            cmd: "playlist.new",
            args: same,
        },
        Tool {
            name: "add_to_playlist",
            description: "Add tunes to Favorites or one of the user's playlists.",
            read_only: false,
            properties: || {
                json!({
                    "name": { "type": "string" },
                    "paths": { "type": "array", "items": { "type": "string" } },
                })
            },
            required: &["name", "paths"],
            cmd: "playlist.add",
            args: same,
        },
        Tool {
            name: "remove_from_playlist",
            description: "Take tunes out of Favorites or one of the user's playlists. The tunes themselves stay.",
            read_only: false,
            properties: || {
                json!({
                    "name": { "type": "string" },
                    "paths": { "type": "array", "items": { "type": "string" } },
                })
            },
            required: &["name", "paths"],
            cmd: "playlist.rm",
            args: same,
        },
    ]
}

fn tool_list() -> Value {
    let list: Vec<Value> = tools()
        .iter()
        .map(|tool| {
            json!({
                "name": tool.name,
                "description": tool.description,
                "inputSchema": {
                    "type": "object",
                    "properties": (tool.properties)(),
                    "required": tool.required,
                },
                "annotations": { "readOnlyHint": tool.read_only, "destructiveHint": false },
            })
        })
        .collect();
    json!({ "tools": list })
}

fn call_tool(params: &Value, backend: &mut dyn Backend) -> Result<Value, (i64, String)> {
    let name = params["name"].as_str().unwrap_or_default();
    let tools = tools();
    let tool = tools.iter().find(|t| t.name == name).ok_or((-32602, format!("Unknown tool: {name}")))?;
    let empty = json!({});
    let arguments = params.get("arguments").filter(|a| a.is_object()).unwrap_or(&empty);
    let missing = tool.required.iter().find(|r| arguments.get(**r).is_none_or(Value::is_null));
    // A tool's own failure is for the assistant to read and act on, not a
    // protocol error.
    let outcome = match missing {
        Some(field) => Err(format!("{name} needs {field}.")),
        None => backend.call(tool.cmd, (tool.args)(arguments)),
    };
    Ok(match outcome {
        Ok(result) => json!({ "content": [{ "type": "text", "text": result.to_string() }], "isError": false }),
        Err(message) => json!({ "content": [{ "type": "text", "text": message }], "isError": true }),
    })
}

/// The answer to one line; nothing for a notification.
pub fn handle(line: &str, backend: &mut dyn Backend) -> Option<Value> {
    let Ok(request) = serde_json::from_str::<Value>(line) else {
        return Some(json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": "Parse error" } }));
    };
    let id = request.get("id")?.clone();
    let params = request.get("params").cloned().unwrap_or(json!({}));
    let result = match request["method"].as_str().unwrap_or_default() {
        "initialize" => {
            let asked = params["protocolVersion"].as_str().unwrap_or_default();
            let version = if KNOWN_VERSIONS.contains(&asked) { asked } else { PROTOCOL_VERSION };
            Ok(json!({
                "protocolVersion": version,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "resonance", "title": "Resonance", "version": env!("CARGO_PKG_VERSION") },
                "instructions": INSTRUCTIONS,
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(tool_list()),
        "tools/call" => call_tool(&params, backend),
        method => Err((-32601, format!("Method not found: {method}"))),
    };
    Some(match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }),
    })
}

pub fn run() -> Result<(), String> {
    let mut backend = AppBackend::default();
    let stdout = std::io::stdout();
    for line in std::io::stdin().lock().lines() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(answer) = handle(&line, &mut backend) {
            let mut out = stdout.lock();
            writeln!(out, "{answer}").map_err(|e| e.to_string())?;
            out.flush().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        calls: Vec<(String, Value)>,
        fail: Option<String>,
    }

    impl Backend for Fake {
        fn call(&mut self, cmd: &str, args: Value) -> Result<Value, String> {
            self.calls.push((cmd.to_string(), args));
            match &self.fail {
                Some(message) => Err(message.clone()),
                None => Ok(json!({ "done": true })),
            }
        }
    }

    fn ask(method: &str, params: Value, backend: &mut Fake) -> Value {
        let line = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }).to_string();
        handle(&line, backend).unwrap()
    }

    #[test]
    fn initialize_keeps_a_version_it_knows() {
        let answer = ask("initialize", json!({ "protocolVersion": "2025-03-26" }), &mut Fake::default());
        assert_eq!(answer["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(answer["result"]["serverInfo"]["name"], "resonance");
        assert!(answer["result"]["capabilities"]["tools"].is_object());
    }

    #[test]
    fn initialize_offers_its_own_for_one_it_doesnt() {
        let answer = ask("initialize", json!({ "protocolVersion": "1999-01-01" }), &mut Fake::default());
        assert_eq!(answer["result"]["protocolVersion"], PROTOCOL_VERSION);
    }

    #[test]
    fn notifications_get_no_answer() {
        let line = json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }).to_string();
        assert!(handle(&line, &mut Fake::default()).is_none());
    }

    #[test]
    fn ping_is_answered() {
        assert_eq!(ask("ping", json!({}), &mut Fake::default())["result"], json!({}));
    }

    #[test]
    fn nonsense_is_a_parse_error() {
        assert_eq!(handle("not json", &mut Fake::default()).unwrap()["error"]["code"], -32700);
    }

    #[test]
    fn an_unknown_method_says_so() {
        assert_eq!(ask("dance", json!({}), &mut Fake::default())["error"]["code"], -32601);
    }

    #[test]
    fn every_tool_is_well_formed() {
        let list = ask("tools/list", json!({}), &mut Fake::default());
        let tools = list["result"]["tools"].as_array().unwrap();
        assert!(tools.len() >= 15);
        let mut names = std::collections::BTreeSet::new();
        for tool in tools {
            assert!(names.insert(tool["name"].as_str().unwrap().to_string()), "duplicate {}", tool["name"]);
            assert!(!tool["description"].as_str().unwrap().is_empty());
            assert_eq!(tool["inputSchema"]["type"], "object");
            for field in tool["inputSchema"]["required"].as_array().unwrap() {
                assert!(tool["inputSchema"]["properties"].get(field.as_str().unwrap()).is_some(), "{}", tool["name"]);
            }
        }
    }

    /// Deleting stays with the person.
    #[test]
    fn nothing_deletes_a_playlist() {
        assert!(tools().iter().all(|t| t.cmd != "playlist.delete" && !t.name.contains("delete")));
    }

    #[test]
    fn read_only_tools_only_read() {
        let reads = ["status", "search", "recent", "sound", "playlist.list", "playlist.show", "hvsc.info", "hvsc.playlist"];
        for tool in tools().iter().filter(|t| t.read_only) {
            assert!(reads.contains(&tool.cmd), "{} is marked read-only", tool.name);
        }
    }

    #[test]
    fn search_turns_query_into_text() {
        let mut fake = Fake::default();
        ask("tools/call", json!({ "name": "search", "arguments": { "query": "commando" } }), &mut fake);
        assert_eq!(fake.calls[0], ("search".to_string(), json!({ "text": "commando", "limit": 20 })));
    }

    #[test]
    fn recently_played_asks_for_fifty_unless_told() {
        let mut fake = Fake::default();
        ask("tools/call", json!({ "name": "recently_played" }), &mut fake);
        assert_eq!(fake.calls[0], ("recent".to_string(), json!({ "limit": 50 })));
        ask("tools/call", json!({ "name": "recently_played", "arguments": { "limit": 5 } }), &mut fake);
        assert_eq!(fake.calls[1].1, json!({ "limit": 5 }));
    }

    #[test]
    fn sounds_like_doesnt_play_unless_told() {
        let mut fake = Fake::default();
        ask("tools/call", json!({ "name": "sounds_like", "arguments": {} }), &mut fake);
        assert_eq!(fake.calls[0].1, json!({ "limit": 10, "play": false }));
    }

    #[test]
    fn a_result_comes_back_as_text() {
        let answer = ask("tools/call", json!({ "name": "pause" }), &mut Fake::default());
        assert_eq!(answer["result"]["isError"], false);
        assert_eq!(answer["result"]["content"][0]["type"], "text");
        assert_eq!(answer["result"]["content"][0]["text"], r#"{"done":true}"#);
    }

    #[test]
    fn a_tools_failure_is_for_the_assistant_to_read() {
        let mut fake = Fake { fail: Some("Nothing is playing.".into()), ..Fake::default() };
        let answer = ask("tools/call", json!({ "name": "favorite_this_tune" }), &mut fake);
        assert_eq!(answer["result"]["isError"], true);
        assert_eq!(answer["result"]["content"][0]["text"], "Nothing is playing.");
    }

    #[test]
    fn a_missing_argument_never_reaches_the_app() {
        let mut fake = Fake::default();
        let answer = ask("tools/call", json!({ "name": "search", "arguments": {} }), &mut fake);
        assert_eq!(answer["result"]["isError"], true);
        assert!(fake.calls.is_empty());
    }

    #[test]
    fn an_unknown_tool_is_a_protocol_error() {
        assert_eq!(ask("tools/call", json!({ "name": "dance" }), &mut Fake::default())["error"]["code"], -32602);
    }
}
