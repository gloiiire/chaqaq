//! Minimal JSON-RPC 2.0 envelope types used by the MCP transport.
//! Hand-rolled rather than pulled from a crate because the surface
//! is tiny and the protocol is stable — keeps the dependency tree
//! lean and the type definitions readable.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct Request {
    // Read by serde from the incoming payload but unused after that —
    // the protocol version is implicit on every line. Keeping the
    // field exists is what swallows it (silenced via allow rather
    // than dropped, because a future strict mode might want to assert
    // `jsonrpc == "2.0"` here).
    #[serde(default)]
    #[allow(dead_code)]
    pub jsonrpc: String,
    /// `Value::Null` for notifications, an integer or string for
    /// regular requests. We keep it untyped so echoing it back is
    /// trivial regardless of the client's convention.
    #[serde(default)]
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub jsonrpc: &'static str,
    pub id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

impl Response {
    pub fn result(id: Value, value: Value) -> Self {
        Self { jsonrpc: "2.0", id, result: Some(value), error: None }
    }

    pub fn error(id: Value, code: i32, message: &str) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(RpcError { code, message: message.to_string() }),
        }
    }
}
