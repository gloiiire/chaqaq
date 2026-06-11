//! Round-trip tests for the JSON-RPC envelope types. The wire format
//! is small but the dispatcher relies on it being stable — the
//! `id` field in particular is echoed verbatim back to the caller
//! and the `error` / `result` exclusivity is enforced via
//! `skip_serializing_if`.

use pinkha_mcp::protocol::{Request, Response, RpcError};
use serde_json::{Value, json};

#[test]
fn request_decodes_with_string_id_and_params() {
    let raw = r#"{"jsonrpc":"2.0","id":"abc","method":"tools/list","params":{"x":1}}"#;
    let r: Request = serde_json::from_str(raw).expect("must decode");
    assert_eq!(r.id, Value::String("abc".to_string()));
    assert_eq!(r.method, "tools/list");
    assert_eq!(r.params, Some(json!({ "x": 1 })));
}

#[test]
fn request_decodes_with_numeric_id_and_missing_params() {
    let raw = r#"{"jsonrpc":"2.0","id":42,"method":"ping"}"#;
    let r: Request = serde_json::from_str(raw).expect("must decode");
    assert_eq!(r.id, json!(42));
    assert_eq!(r.method, "ping");
    assert_eq!(r.params, None);
}

#[test]
fn request_decodes_notification_with_null_id() {
    // Notifications use a null id (or omit it altogether). Both
    // serde forms must decode without complaining.
    let raw = r#"{"jsonrpc":"2.0","method":"notify"}"#;
    let r: Request = serde_json::from_str(raw).expect("must decode missing id");
    assert_eq!(r.id, Value::Null);
}

#[test]
fn response_result_encodes_without_error_field() {
    let resp = Response::result(json!("xyz"), json!({ "data": 1 }));
    let s = serde_json::to_string(&resp).unwrap();
    let parsed: Value = serde_json::from_str(&s).unwrap();
    assert_eq!(parsed.get("jsonrpc").and_then(Value::as_str), Some("2.0"));
    assert_eq!(parsed.get("id").and_then(Value::as_str), Some("xyz"));
    assert!(parsed.get("result").is_some());
    assert!(
        parsed.get("error").is_none(),
        "error field must be elided on a success envelope : {parsed}"
    );
}

#[test]
fn response_error_encodes_without_result_field() {
    let resp = Response::error(json!(7), -32601, "Method not found");
    let s = serde_json::to_string(&resp).unwrap();
    let parsed: Value = serde_json::from_str(&s).unwrap();
    assert!(
        parsed.get("result").is_none(),
        "result field must be elided on an error envelope : {parsed}"
    );
    let err = parsed.get("error").expect("error field present");
    assert_eq!(err.get("code").and_then(Value::as_i64), Some(-32601));
    assert_eq!(
        err.get("message").and_then(Value::as_str),
        Some("Method not found")
    );
}

#[test]
fn rpc_error_serializes_code_and_message() {
    // Direct serialization (without the Response wrapper) — the
    // dispatcher uses RpcError standalone in a couple of places.
    let e = RpcError {
        code: -32700,
        message: "Parse error".to_string(),
    };
    let s = serde_json::to_string(&e).unwrap();
    let parsed: Value = serde_json::from_str(&s).unwrap();
    assert_eq!(parsed.get("code").and_then(Value::as_i64), Some(-32700));
    assert_eq!(
        parsed.get("message").and_then(Value::as_str),
        Some("Parse error")
    );
}
