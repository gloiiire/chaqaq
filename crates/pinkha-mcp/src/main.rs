//! Pinkha MCP server.
//!
//! Speaks the Model Context Protocol over stdio so AI agents
//! (Claude Desktop, Cursor, Claude Code) can read and write a local
//! pinkha SQLite store. Reuses the `PinkhaApi` exposed for the iOS /
//! macOS apps — no logic duplication, the server is a thin JSON-RPC
//! adapter on top.
//!
//! Usage:
//!   pinkha-mcp /path/to/pinkha.db
//!
//! The DB path is mandatory — there is no implicit default because
//! the iOS sandbox path is unreachable from a macOS process anyway,
//! and the macOS sandbox path depends on the install method.

use std::io::{self, BufRead, Write};
use std::sync::Arc;

use pinkha::ffi::PinkhaApi;
use pinkha_mcp::{protocol, tools};
use serde_json::{Value, json};

fn main() -> anyhow::Result<()> {
    let db_path = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("usage: pinkha-mcp <path/to/pinkha.db>"))?;
    let api = Arc::new(
        PinkhaApi::new(db_path).map_err(|e| anyhow::anyhow!("failed to open pinkha book: {e}"))?,
    );

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();

    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let req: protocol::Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                // Malformed JSON — emit a parse error with id=null
                // (the request id is unrecoverable past a parse fail).
                write_message(
                    &mut out,
                    &protocol::Response::error(Value::Null, -32700, &format!("parse error: {e}")),
                )?;
                continue;
            }
        };

        let response = handle(&api, req);
        // Notifications carry no id and produce no response — we
        // never emit them anyway, but skip writing if `handle`
        // returns `None` so the protocol stays clean.
        if let Some(r) = response {
            write_message(&mut out, &r)?;
        }
    }
    Ok(())
}

fn write_message(out: &mut impl Write, msg: &protocol::Response) -> io::Result<()> {
    let s = serde_json::to_string(msg).expect("serializable");
    writeln!(out, "{s}")?;
    out.flush()
}

fn handle(api: &Arc<PinkhaApi>, req: protocol::Request) -> Option<protocol::Response> {
    // `initialize` and `tools/list` are protocol plumbing — every
    // MCP client calls them at startup. `tools/call` is the actual
    // dispatch into pinkha. Everything else gets `method not found`.
    let id = req.id.clone();
    match req.method.as_str() {
        "initialize" => Some(protocol::Response::result(
            id,
            json!({
                "protocolVersion": "2024-11-05",
                "serverInfo": {
                    "name": "pinkha-mcp",
                    "version": env!("CARGO_PKG_VERSION"),
                },
                "capabilities": { "tools": {} },
            }),
        )),
        "tools/list" => Some(protocol::Response::result(
            id,
            json!({ "tools": tools::registry() }),
        )),
        "tools/call" => {
            let params = req.params.unwrap_or(Value::Null);
            let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let arguments = params.get("arguments").cloned().unwrap_or(Value::Null);
            match tools::dispatch(api, name, arguments) {
                Ok(text) => Some(protocol::Response::result(
                    id,
                    json!({
                        "content": [{ "type": "text", "text": text }],
                    }),
                )),
                Err(e) => Some(protocol::Response::error(id, -32000, &e.to_string())),
            }
        }
        // Notifications (no id) are silently dropped — the spec
        // requires no response. Requests with an unknown method get
        // the standard JSON-RPC `method not found`.
        _ if id.is_null() => None,
        _ => Some(protocol::Response::error(
            id,
            -32601,
            &format!("method not found: {}", req.method),
        )),
    }
}
