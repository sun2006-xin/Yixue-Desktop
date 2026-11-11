use std::{
    ffi::{CStr, CString},
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use yixue_ffi::{
    BRIDGE_SCHEMA_VERSION, yixue_bridge_schema_version, yixue_engine_free, yixue_engine_open,
    yixue_engine_process_json, yixue_process_json, yixue_string_free,
};

#[test]
fn c_abi_exposes_schema_version() {
    assert_eq!(yixue_bridge_schema_version(), BRIDGE_SCHEMA_VERSION);
}

#[test]
fn c_abi_returns_owned_utf8_json_and_releases_it() {
    let input = CString::new(
        json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "health"
        })
        .to_string(),
    )
    .expect("input should not contain null bytes");

    // SAFETY: `input` is a live, null-terminated C string for the duration of the call.
    let output = unsafe { yixue_process_json(input.as_ptr()) };
    assert!(!output.is_null());

    // SAFETY: the bridge returns a live, null-terminated string owned by Rust.
    let response_text = unsafe { CStr::from_ptr(output) }
        .to_str()
        .expect("output should be UTF-8");
    let response: Value = serde_json::from_str(response_text).expect("output should be JSON");
    assert_eq!(response["ok"], true);

    // SAFETY: `output` came from `yixue_process_json` and is released exactly once.
    unsafe { yixue_string_free(output) };
}

#[test]
fn null_input_is_reported_without_dereferencing() {
    // SAFETY: null is an explicitly supported sentinel input.
    let output = unsafe { yixue_process_json(std::ptr::null()) };
    assert!(!output.is_null());

    // SAFETY: the bridge returns a live, null-terminated string owned by Rust.
    let response_text = unsafe { CStr::from_ptr(output) }
        .to_str()
        .expect("output should be UTF-8");
    let response: Value = serde_json::from_str(response_text).expect("output should be JSON");
    assert_eq!(response["error"]["code"], "null_input");

    // SAFETY: `output` came from `yixue_process_json` and is released exactly once.
    unsafe { yixue_string_free(output) };
}

#[test]
fn c_abi_engine_owns_a_persistent_database_lifecycle() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock should be after epoch")
        .as_nanos();
    let database_path = std::env::temp_dir().join(format!(
        "yixue-ffi-engine-{}-{unique}.db",
        std::process::id()
    ));
    let database_path = CString::new(database_path.to_string_lossy().as_bytes())
        .expect("database path should not contain null bytes");

    // SAFETY: the database path is a live, null-terminated UTF-8 C string.
    let engine = unsafe { yixue_engine_open(database_path.as_ptr()) };
    assert!(!engine.is_null());

    let request = CString::new(
        json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_provider_profiles"
        })
        .to_string(),
    )
    .expect("request should not contain null bytes");
    // SAFETY: the engine and request were created by their documented constructors.
    let output = unsafe { yixue_engine_process_json(engine, request.as_ptr()) };
    assert!(!output.is_null());
    // SAFETY: output is a live C string returned by the bridge.
    let response: Value = serde_json::from_str(
        unsafe { CStr::from_ptr(output) }
            .to_str()
            .expect("response should be UTF-8"),
    )
    .expect("response should be JSON");
    assert_eq!(response["ok"], true);

    // SAFETY: both pointers came from the matching bridge constructors and are freed once.
    unsafe {
        yixue_string_free(output);
        yixue_engine_free(engine);
    }
    fs::remove_file(database_path.to_str().expect("path should be UTF-8"))
        .expect("temporary database should be removable");
}
