use std::{
    collections::BTreeMap,
    fmt::Write as _,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use yixue_ffi::{BRIDGE_SCHEMA_VERSION, process_json};

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn create() -> Self {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be valid")
            .as_nanos();
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-ffi-model-packages")
            .join(format!("package-{suffix}"));
        fs::create_dir_all(&path).expect("test directory should be created");
        Self(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("test directory should be removed");
    }
}

fn write_valid_package(root: &Path) {
    let files = [
        ("config.json", b"{}".as_slice()),
        ("model.bin", b"model".as_slice()),
        ("source_vocabulary.json", b"[]".as_slice()),
        ("target_vocabulary.json", b"[]".as_slice()),
        ("source.spm", b"source tokenizer".as_slice()),
        ("target.spm", b"target tokenizer".as_slice()),
    ];
    let mut hashes = BTreeMap::new();
    for (name, content) in files {
        fs::write(root.join(name), content).expect("fixture file should be written");
        let mut hash = String::with_capacity(64);
        for byte in Sha256::digest(content) {
            write!(&mut hash, "{byte:02x}").expect("writing to a string should succeed");
        }
        hashes.insert(name, hash);
    }
    fs::write(
        root.join("yixue-model.json"),
        serde_json::to_vec_pretty(&json!({
            "schema_version": 1,
            "package_id": "yixue.opus-en-zh.int8",
            "display_name": "译学英中轻量模型",
            "engine": "ctranslate2",
            "source_language": "english",
            "target_language": "chinese",
            "base_model": "Helsinki-NLP/opus-mt-en-zh",
            "license": "Apache-2.0",
            "files": hashes,
        }))
        .expect("manifest should serialize"),
    )
    .expect("manifest should be written");
}

#[test]
fn health_command_reports_bridge_and_core_versions() {
    let response: Value = serde_json::from_str(&process_json(
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "health"
        })
        .to_string(),
    ))
    .expect("bridge response should be JSON");

    assert_eq!(response["ok"], true);
    assert_eq!(response["schema_version"], BRIDGE_SCHEMA_VERSION);
    assert_eq!(response["data"]["core_version"], env!("CARGO_PKG_VERSION"));
}

#[test]
fn malformed_json_returns_a_stable_error_envelope() {
    let response: Value =
        serde_json::from_str(&process_json("not-json")).expect("error response should be JSON");

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_json");
}

#[test]
fn incompatible_schema_is_rejected_explicitly() {
    let response: Value = serde_json::from_str(&process_json(
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION + 1,
            "command": "health"
        })
        .to_string(),
    ))
    .expect("bridge response should be JSON");

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "unsupported_schema");
}

#[test]
fn translation_request_validation_uses_core_rules() {
    let response: Value = serde_json::from_str(&process_json(
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "validate_translation_request",
            "payload": {
                "id": "request-1",
                "source_language": "english",
                "target_language": "chinese",
                "text": "   "
            }
        })
        .to_string(),
    ))
    .expect("bridge response should be JSON");

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_input");
}

#[test]
fn model_package_validation_returns_safe_metadata() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);

    let response: Value = serde_json::from_str(&process_json(
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "validate_model_package",
            "payload": {"model_path": directory.0}
        })
        .to_string(),
    ))
    .expect("bridge response should be JSON");

    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["package_id"], "yixue.opus-en-zh.int8");
    assert_eq!(response["data"]["source_language"], "english");
    assert_eq!(response["data"]["target_language"], "chinese");
    assert_eq!(response["data"]["license"], "Apache-2.0");
    assert_eq!(response["data"]["verified_file_count"], 6);
}

#[test]
fn history_origin_json_contract_preserves_screenshot_and_defaults_legacy_requests() {
    let engine = yixue_ffi::BridgeEngine::open_in_memory().unwrap();
    for (id, origin) in [
        ("legacy", None),
        ("screenshot", Some("screenshot_translation")),
    ] {
        let mut payload = json!({"id": id, "source_language": "english", "target_language": "chinese",
            "source_text": "Hello", "translated_text": "你好", "provider_id": "local.dictionary", "created_at": "2026-10-06T12:00:00Z"});
        if let Some(origin) = origin {
            payload["origin"] = json!(origin);
        }
        let response: Value = serde_json::from_str(
            &engine.process_json(
                &json!({"schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_completed_translation", "payload": payload})
                .to_string(),
            ),
        )
        .unwrap();
        assert_eq!(response["ok"], true);
        assert_eq!(
            response["data"]["translation"]["origin"],
            origin.unwrap_or("quick_translation")
        );
    }
    let response: Value = serde_json::from_str(
        &engine.process_json(
            &json!({"schema_version": BRIDGE_SCHEMA_VERSION,
        "command": "list_translation_history", "payload": {"limit": 10}})
            .to_string(),
        ),
    )
    .unwrap();
    assert_eq!(
        response["data"]["translations"][0]["origin"],
        "quick_translation"
    );
    assert_eq!(
        response["data"]["translations"][1]["origin"],
        "screenshot_translation"
    );
}
