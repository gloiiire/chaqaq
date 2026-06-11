//! Library surface of the pinkha MCP server.
//!
//! The crate ships a binary (`pinkha-mcp` — the stdio JSON-RPC loop)
//! but the JSON-RPC envelope types and the tool dispatcher are also
//! exposed as a library so integration tests can exercise them
//! without spawning a child process. Embedders (e.g. an in-process
//! MCP harness inside the Mac app) can also reuse the dispatcher
//! directly.

pub mod protocol;
pub mod tools;
