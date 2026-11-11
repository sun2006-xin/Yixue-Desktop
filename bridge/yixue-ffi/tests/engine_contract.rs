use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use serde_json::{Value, json};
use yixue_core::{
    CancellationToken, CoreError, FakeProvider, Language, LanguagePair, ProviderCapabilities,
    ProviderKind, TranslationProvider, TranslationRequest, TranslationResult,
};
use yixue_ffi::{BRIDGE_SCHEMA_VERSION, BridgeEngine};

fn command(engine: &BridgeEngine, value: &Value) -> Value {
    serde_json::from_str(&engine.process_json(&value.to_string()))
        .expect("engine response should be JSON")
}

struct BlockingProvider {
    capabilities: ProviderCapabilities,
    entered: Arc<AtomicBool>,
}

impl TranslationProvider for BlockingProvider {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }

    fn translate(
        &self,
        _request: &TranslationRequest,
        cancellation: &CancellationToken,
    ) -> Result<TranslationResult, CoreError> {
        self.entered.store(true, Ordering::Release);
        loop {
            cancellation.check()?;
            thread::sleep(Duration::from_millis(5));
        }
    }
}

#[test]
fn engine_rejects_translation_before_a_provider_is_configured() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "translate",
            "payload": {
                "id": "request-1",
                "source_language": "english",
                "target_language": "chinese",
                "text": "hello"
            }
        }),
    );

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "provider_unavailable");
}

#[test]
fn engine_rejects_configuring_an_unverified_local_translation_model() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "configure_local_translation",
            "payload": {
                "model_path": "Z:/missing-yixue-model-package",
                "worker_path": "Z:/missing-yixue-worker.exe"
            }
        }),
    );

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "model_package_invalid");
}

#[test]
fn engine_translates_with_the_configured_provider() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let capabilities = ProviderCapabilities::new(
        "local.test",
        "Local test provider",
        ProviderKind::LocalModel,
        true,
        vec![LanguagePair::new(Language::English, Language::Chinese)],
    )
    .expect("capabilities should be valid");
    engine
        .set_translation_provider(Arc::new(FakeProvider::from_pairs(
            capabilities,
            [("hello", "你好")],
        )))
        .expect("provider should be configured");

    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "translate",
            "payload": {
                "id": "request-1",
                "source_language": "english",
                "target_language": "chinese",
                "text": "hello"
            }
        }),
    );

    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["translation"]["text"], "你好");
    assert_eq!(response["data"]["translation"]["provider_id"], "local.test");
}

#[test]
fn engine_cancels_an_active_translation_by_request_id() {
    let engine = Arc::new(BridgeEngine::open_in_memory().expect("engine should open"));
    let entered = Arc::new(AtomicBool::new(false));
    let capabilities = ProviderCapabilities::new(
        "local.blocking",
        "Blocking provider",
        ProviderKind::LocalModel,
        true,
        vec![LanguagePair::new(Language::English, Language::Chinese)],
    )
    .expect("capabilities should be valid");
    engine
        .set_translation_provider(Arc::new(BlockingProvider {
            capabilities,
            entered: entered.clone(),
        }))
        .expect("provider should be configured");

    let translating_engine = engine.clone();
    let translation = thread::spawn(move || {
        command(
            &translating_engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "translate",
                "payload": {
                    "id": "request-to-cancel",
                    "source_language": "english",
                    "target_language": "chinese",
                    "text": "hello"
                }
            }),
        )
    });

    for _ in 0..100 {
        if entered.load(Ordering::Acquire) {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
    assert!(entered.load(Ordering::Acquire));

    let cancellation = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "cancel_translation",
            "payload": {"id": "request-to-cancel"}
        }),
    );
    assert_eq!(cancellation["ok"], true);
    assert_eq!(cancellation["data"]["cancelled"], true);

    let response = translation.join().expect("translation thread should stop");
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "cancelled");
}

#[test]
fn engine_saves_and_lists_non_secret_provider_metadata() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let save_response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_provider_profile",
            "payload": {
                "id": "remote.openai-compatible",
                "display_name": "OpenAI compatible",
                "kind": "remote_api",
                "enabled": true,
                "model_id": "translation-model",
                "endpoint": "https://api.example.com/v1",
                "model_path": null,
                "secret_ref": "yixue.provider.remote.openai-compatible.api-key",
                "assigned_roles": ["translation", "understanding"]
            }
        }),
    );
    assert_eq!(save_response["ok"], true);

    let list_response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_provider_profiles"
        }),
    );
    assert_eq!(list_response["ok"], true);
    assert_eq!(
        list_response["data"]["profiles"][0]["id"],
        "remote.openai-compatible"
    );
    assert_eq!(
        list_response["data"]["profiles"][0]["secret_ref"],
        "yixue.provider.remote.openai-compatible.api-key"
    );
    assert_eq!(
        list_response["data"]["profiles"][0]["assigned_roles"],
        json!(["translation", "understanding"])
    );
    assert!(list_response.to_string().find("key-value").is_none());
}

#[test]
fn engine_rejects_secret_values_inside_profile_metadata() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_provider_profile",
            "payload": {
                "id": "remote.invalid",
                "display_name": "Invalid",
                "kind": "remote_api",
                "enabled": true,
                "model_id": "translation-model",
                "endpoint": "https://api.example.com/v1",
                "model_path": null,
                "secret_ref": "yixue.provider.remote.invalid.api-key",
                "api_key": "must-not-cross-this-boundary"
            }
        }),
    );

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_payload");
}

#[test]
fn engine_rejects_enabling_an_unverified_local_model() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_provider_profile",
            "payload": {
                "id": "local.unverified",
                               "display_name": "Unverified local model",
                "kind": "local_model",
                "enabled": true,
                "model_id": "unverified-model",
                "endpoint": null,
                "model_path": "Z:/missing-yixue-model-package",
                "secret_ref": null
            }
        }),
    );

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "model_package_invalid");

    let profiles = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_provider_profiles"
        }),
    );
    assert_eq!(
        profiles["data"]["profiles"].as_array().map(Vec::len),
        Some(0)
    );
}

#[test]
fn engine_records_activity_and_returns_a_home_snapshot() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let record_response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_activity",
            "payload": {
                "id": "reading-1",
                "kind": "reading",
                "title": "Human-AI Collaboration.pdf",
                "detail": "阅读器 · 第 12 页",
                "duration_seconds": 1200,
                "item_count": 8,
                "occurred_at": "2026-09-09T09:00:00+08:00"
            }
        }),
    );
    assert_eq!(record_response["ok"], true);

    let snapshot_response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "home_snapshot",
            "payload": {
                "local_date": "2026-09-09",
                "recent_limit": 5
            }
        }),
    );

    assert_eq!(snapshot_response["ok"], true);
    assert_eq!(
        snapshot_response["data"]["snapshot"]["learning_minutes"],
        20
    );
    assert_eq!(snapshot_response["data"]["snapshot"]["reading_pages"], 8);
    assert_eq!(
        snapshot_response["data"]["snapshot"]["recent"][0]["id"],
        "reading-1"
    );
}

#[test]
fn engine_returns_versioned_workbench_metrics_and_date_scoped_recent_activity() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    for (id, kind, duration_seconds, item_count, occurred_at) in [
        (
            "translation-1",
            "translation",
            12,
            4,
            "2026-09-15T09:00:00+08:00",
        ),
        ("focus-1", "focus", 1500, 1, "2026-09-15T10:00:00+08:00"),
        ("other-day", "speaking", 900, 1, "2026-09-14T10:00:00+08:00"),
    ] {
        let response = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "record_activity",
                "payload": {
                    "id": id,
                    "kind": kind,
                    "title": id,
                    "detail": null,
                    "source_id": if kind == "reading" { Some("article-1") } else { None::<&str> },
                    "duration_seconds": duration_seconds,
                    "item_count": item_count,
                    "occurred_at": occurred_at
                }
            }),
        );
        assert_eq!(response["ok"], true);
    }

    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "home_workbench_snapshot",
            "payload": {"local_date": "2026-09-15", "recent_limit": 10}
        }),
    );

    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["snapshot"]["local_date"], "2026-09-15");
    assert_eq!(
        response["data"]["snapshot"]["summary"]["translation_count"]["value"],
        1
    );
    assert_eq!(
        response["data"]["snapshot"]["summary"]["focus_seconds"]["value"],
        1500
    );
    assert_eq!(
        response["data"]["snapshot"]["summary"]["reading_articles"]["available"],
        true
    );
    assert_eq!(
        response["data"]["snapshot"]["summary"]["reading_articles"]["value"],
        0
    );
    assert_eq!(
        response["data"]["snapshot"]["recent"]
            .as_array()
            .map(Vec::len),
        Some(2)
    );
    assert_eq!(response["data"]["snapshot"]["recent"][0]["id"], "focus-1");
    assert_eq!(
        response["data"]["snapshot"]["details"][0]["source_id"],
        serde_json::Value::Null
    );
}

#[test]
fn engine_persists_and_lists_reader_sources() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_content_source",
            "payload": {
                "id": "reader-1", "kind": "article", "title": "Reader article",
                "local_path": "D:/article.txt", "content_text": "First\n\nSecond",
                "reading_position": 1,
                "translated_paragraphs_json": "{\"paragraph-1\":\"第二段\"}",
                "created_at": "2026-09-12T12:00:00Z"
            }
        }),
    );
    assert_eq!(saved["ok"], true);
    let listed = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_content_sources",
            "payload": {"limit": 10}
        }),
    );
    assert_eq!(listed["ok"], true);
    assert_eq!(listed["data"]["sources"][0]["title"], "Reader article");
    assert_eq!(listed["data"]["sources"][0]["reading_position"], 1);
}

#[test]
fn engine_manages_reader_favorites_and_recoverable_trash() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let source = json!({
        "id": "reader-library-state", "kind": "article", "title": "Library state",
        "local_path": "D:/article.md", "content_text": "Keep this source",
        "reading_position": 0, "translated_paragraphs_json": "{}",
        "created_at": "2026-09-20T10:00:00Z"
    });
    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_content_source",
            "payload": source
        }),
    );
    assert_eq!(saved["ok"], true);

    let favorite = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "set_content_source_favorite",
            "payload": {"source_id": "reader-library-state", "favorite": true}
        }),
    );
    assert_eq!(favorite["ok"], true);

    let trashed = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "trash_content_source",
            "payload": {"source_id": "reader-library-state"}
        }),
    );
    assert_eq!(trashed["ok"], true);

    let listed = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_content_sources",
            "payload": {"limit": 10}
        }),
    );
    assert_eq!(listed["data"]["sources"][0]["is_favorite"], true);
    assert!(listed["data"]["sources"][0]["deleted_at"].is_string());
    assert_eq!(listed["data"]["sources"][0]["local_path"], "D:/article.md");

    let restored = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "restore_content_source",
            "payload": {"source_id": "reader-library-state"}
        }),
    );
    assert_eq!(restored["ok"], true);

    let deleted = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "delete_content_source",
            "payload": {"source_id": "reader-library-state"}
        }),
    );
    assert_eq!(deleted["ok"], true);
}

#[test]
fn engine_appends_lists_and_restores_reader_source_versions() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let source = json!({
        "id": "reader-versioned", "kind": "article", "title": "Versioned article",
        "local_path": "D:/article.md", "content_text": "First source",
        "reading_position": 0,
        "translated_paragraphs_json": "{\"version\":\"one\"}",
        "created_at": "2026-09-19T10:00:00Z"
    });
    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_content_source",
            "payload": source
        }),
    );
    assert_eq!(saved["ok"], true);

    let first = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_content_source_version",
            "payload": {
                "id": "reader-versioned", "kind": "article", "title": "Versioned article",
                "local_path": "D:/article.md", "content_text": "First source",
                "reading_position": 0,
                "translated_paragraphs_json": "{\"version\":\"one\"}",
                "created_at": "2026-09-19T10:00:00Z"
            }
        }),
    );
    assert_eq!(first["ok"], true);
    assert_eq!(first["data"]["version"]["version"], 1);

    let second = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_content_source_version",
            "payload": {
                "id": "reader-versioned", "kind": "article", "title": "Versioned article",
                "local_path": "D:/article.md", "content_text": "Second source",
                "reading_position": 1,
                "translated_paragraphs_json": "{\"version\":\"two\"}",
                "created_at": "2026-09-19T10:05:00Z"
            }
        }),
    );
    assert_eq!(second["ok"], true);
    assert_eq!(second["data"]["version"]["version"], 2);

    let listed = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_content_source_versions",
            "payload": {"source_id": "reader-versioned", "limit": 10}
        }),
    );
    assert_eq!(listed["ok"], true);
    assert_eq!(listed["data"]["versions"].as_array().map(Vec::len), Some(2));
    assert_eq!(listed["data"]["versions"][0]["version"], 2);

    let restored = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "restore_content_source_version",
            "payload": {
                "source_id": "reader-versioned",
                "version_id": first["data"]["version"]["id"]
            }
        }),
    );
    assert_eq!(restored["ok"], true);
    assert_eq!(restored["data"]["source"]["content_text"], "First source");
    assert_eq!(restored["data"]["source"]["reading_position"], 0);
}

#[test]
fn engine_records_a_completed_translation_without_accepting_secrets() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_completed_translation",
            "payload": {
                "id": "translation-1",
                "source_language": "english",
                "target_language": "chinese",
                "source_text": "Technology changes life.",
                "translated_text": "技术改变生活。",
                "provider_id": "remote.example",
                "created_at": "2026-09-09T12:00:00+08:00"
            }
        }),
    );
    assert_eq!(response["ok"], true);

    let snapshot = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "home_snapshot",
            "payload": {"local_date": "2026-09-09", "recent_limit": 5}
        }),
    );
    assert_eq!(
        snapshot["data"]["snapshot"]["recent"][0]["kind"],
        "translation"
    );

    let history = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {"limit": 10}
        }),
    );
    assert_eq!(history["ok"], true);
    assert_eq!(history["data"]["translations"][0]["id"], "translation-1");
    assert_eq!(
        history["data"]["translations"][0]["translated_text"],
        "技术改变生活。"
    );
}

#[test]
fn screenshot_summary_command_persists_only_for_the_exact_screenshot_source() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let recorded = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_completed_translation",
            "payload": {
                "id": "summary-history",
                "origin": "screenshot_translation",
                "source_language": "english",
                "target_language": "chinese",
                "source_text": "Exact OCR source",
                "translated_text": "原译文",
                "provider_id": "local.test",
                "created_at": "2026-10-09T12:00:00+08:00"
            }
        }),
    );
    assert_eq!(recorded["ok"], true);

    let mismatched = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_screenshot_translation_summary",
            "payload": {
                "id": "summary-history",
                "source_text": " Exact OCR source ",
                "summary_text": "摘要"
            }
        }),
    );
    assert_eq!(mismatched["ok"], false);
    assert_eq!(mismatched["error"]["code"], "invalid_input");

    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_screenshot_translation_summary",
            "payload": {
                "id": "summary-history",
                "source_text": "Exact OCR source",
                "summary_text": "学习摘要"
            }
        }),
    );
    assert_eq!(saved["ok"], true);

    let listed = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {"limit": 10, "origin": "screenshot_translation"}
        }),
    );
    assert_eq!(
        listed["data"]["translations"][0]["summary_text"],
        "学习摘要"
    );

    let corrected = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_completed_translation",
            "payload": {
                "id": "summary-history",
                "origin": "screenshot_translation",
                "source_language": "english",
                "target_language": "chinese",
                "source_text": "Corrected OCR source",
                "translated_text": "修正译文",
                "provider_id": "local.test",
                "created_at": "2026-10-09T12:05:00+08:00"
            }
        }),
    );
    assert_eq!(corrected["ok"], true);
    let after_correction = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {"limit": 10, "origin": "screenshot_translation"}
        }),
    );
    assert!(
        after_correction["data"]["translations"][0]
            .get("summary_text")
            .is_none()
    );
}

#[test]
fn screenshot_history_versions_keep_capture_ids_and_report_safe_image_deletion() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    for (id, created_at) in [
        ("capture-version-1", "2026-10-08T12:00:00+08:00"),
        ("capture-version-2", "2026-10-08T12:05:00+08:00"),
    ] {
        let saved = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "record_completed_translation",
                "payload": {
                    "id": id,
                    "origin": "screenshot_translation",
                    "screenshot_capture_id": "capture-stable",
                    "source_language": "english",
                    "target_language": "chinese",
                    "source_text": format!("source {id}"),
                    "translated_text": format!("translation {id}"),
                    "provider_id": "local.test",
                    "created_at": created_at
                }
            }),
        );
        assert_eq!(saved["ok"], true);
    }

    let history = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {"limit": 10, "origin": "screenshot_translation"}
        }),
    );
    assert_eq!(history["data"]["translations"].as_array().unwrap().len(), 2);
    assert!(
        history["data"]["translations"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["screenshot_capture_id"] == "capture-stable")
    );

    let partial_delete = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "screenshot_capture_image_deletion_candidates",
            "payload": {"ids": ["capture-version-1"]}
        }),
    );
    assert_eq!(partial_delete["ok"], true);
    assert_eq!(partial_delete["data"]["captureIds"], json!([]));

    let whole_group = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "screenshot_capture_image_deletion_candidates",
            "payload": {"ids": ["capture-version-1", "capture-version-2"]}
        }),
    );
    assert_eq!(whole_group["data"]["captureIds"], json!(["capture-stable"]));

    let deleted = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "delete_translation_history",
            "payload": {"ids": ["capture-version-1"]}
        }),
    );
    assert_eq!(deleted["ok"], true);
    let last_version = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "screenshot_capture_image_deletion_candidates",
            "payload": {"ids": ["capture-version-2"]}
        }),
    );
    assert_eq!(
        last_version["data"]["captureIds"],
        json!(["capture-stable"])
    );
}

#[test]
fn screenshot_capture_reference_command_reports_only_live_screenshot_ids() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    for (id, origin, capture_id, created_at) in [
        (
            "screenshot-version-1",
            "screenshot_translation",
            Some("capture-shared"),
            "2026-10-08T12:00:00+08:00",
        ),
        (
            "screenshot-version-2",
            "screenshot_translation",
            Some("capture-shared"),
            "2026-10-08T12:05:00+08:00",
        ),
        (
            "legacy-capture",
            "screenshot_translation",
            None,
            "2026-10-08T12:10:00+08:00",
        ),
        (
            "quick-only-capture",
            "quick_translation",
            None,
            "2026-10-08T12:15:00+08:00",
        ),
    ] {
        let mut payload = json!({
            "id": id,
            "origin": origin,
            "source_language": "english",
            "target_language": "chinese",
            "source_text": format!("source {id}"),
            "translated_text": format!("translation {id}"),
            "provider_id": "local.test",
            "created_at": created_at
        });
        if let Some(capture_id) = capture_id {
            payload["screenshot_capture_id"] = json!(capture_id);
        }
        let saved = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "record_completed_translation",
                "payload": payload
            }),
        );
        assert_eq!(saved["ok"], true);
    }

    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "screenshot_capture_image_references",
            "payload": {
                "ids": [
                    "missing-capture",
                    "legacy-capture",
                    "capture-shared",
                    "capture-shared",
                    "quick-only-capture"
                ]
            }
        }),
    );
    assert_eq!(response["ok"], true);
    assert_eq!(
        response["data"]["captureIds"],
        json!(["capture-shared", "legacy-capture"])
    );

    let injection_like_id = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "screenshot_capture_image_references",
            "payload": {"ids": ["missing' OR 1=1 --"]}
        }),
    );
    assert_eq!(injection_like_id["ok"], true);
    assert_eq!(injection_like_id["data"]["captureIds"], json!([]));
}

#[test]
fn screenshot_capture_reference_command_enforces_payload_and_input_limits() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let too_many_ids = (0..501)
        .map(|index| format!("capture-{index}"))
        .collect::<Vec<_>>();

    for capture_ids in [vec![String::new()], vec!["x".repeat(301)], too_many_ids] {
        let response = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "screenshot_capture_image_references",
                "payload": {"ids": capture_ids}
            }),
        );
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "invalid_input");
    }

    let invalid_payload = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "screenshot_capture_image_references",
            "payload": {"capture_ids": ["capture-id"]}
        }),
    );
    assert_eq!(invalid_payload["ok"], false);
    assert_eq!(invalid_payload["error"]["code"], "invalid_payload");
}

#[test]
fn engine_filters_translation_history_by_origin_query_and_page() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    for (id, origin, source_text, translated_text, created_at) in [
        (
            "quick-newest",
            "quick_translation",
            "Needle from quick translation",
            "快速翻译结果",
            "2026-10-07T12:03:00+08:00",
        ),
        (
            "screenshot-newer",
            "screenshot_translation",
            "Needle from screenshot",
            "截屏词条 A",
            "2026-10-07T12:02:00+08:00",
        ),
        (
            "screenshot-older",
            "screenshot_translation",
            "Different source",
            "截屏词条 Needle B",
            "2026-10-07T12:01:00+08:00",
        ),
    ] {
        let recorded = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "record_completed_translation",
                "payload": {
                    "id": id,
                    "origin": origin,
                    "source_language": "english",
                    "target_language": "chinese",
                    "source_text": source_text,
                    "translated_text": translated_text,
                    "provider_id": "local.test",
                    "created_at": created_at
                }
            }),
        );
        assert_eq!(recorded["ok"], true);
    }

    let second_filtered_page = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {
                "limit": 1,
                "offset": 1,
                "origin": "screenshot_translation",
                "query": "Needle"
            }
        }),
    );
    assert_eq!(second_filtered_page["ok"], true);
    assert_eq!(
        second_filtered_page["data"]["translations"][0]["id"],
        "screenshot-older"
    );

    let invalid_origin = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {"limit": 10, "origin": "unknown"}
        }),
    );
    assert_eq!(invalid_origin["ok"], false);
    assert_eq!(invalid_origin["error"]["code"], "invalid_payload");
}

#[test]
fn engine_validates_screenshot_history_by_id_origin_and_exact_source_text() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    for (id, origin) in [
        ("screenshot-match", "screenshot_translation"),
        ("quick-same-source", "quick_translation"),
    ] {
        let saved = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "record_completed_translation",
                "payload": {
                    "id": id,
                    "origin": origin,
                    "source_language": "english",
                    "target_language": "chinese",
                    "source_text": "Exact captured source",
                    "translated_text": "译文",
                    "provider_id": "local.test",
                    "created_at": "2026-10-07T12:00:00+08:00"
                }
            }),
        );
        assert_eq!(saved["ok"], true);
    }

    for (id, source_text, expected_match) in [
        ("screenshot-match", "Exact captured source", true),
        ("screenshot-match", "Exact captured", false),
        ("quick-same-source", "Exact captured source", false),
        ("missing-id", "Exact captured source", false),
    ] {
        let response = command(
            &engine,
            &json!({
                "schema_version": BRIDGE_SCHEMA_VERSION,
                "command": "validate_screenshot_translation_history",
                "payload": {"id": id, "source_text": source_text}
            }),
        );
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["matches"], expected_match);
    }

    let invalid_payload = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "validate_screenshot_translation_history",
            "payload": {"id": "screenshot-match"}
        }),
    );
    assert_eq!(invalid_payload["ok"], false);
    assert_eq!(invalid_payload["error"]["code"], "invalid_payload");

    let invalid_input = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "validate_screenshot_translation_history",
            "payload": {"id": " ", "source_text": "Exact captured source"}
        }),
    );
    assert_eq!(invalid_input["ok"], false);
    assert_eq!(invalid_input["error"]["code"], "invalid_input");
}

#[test]
fn engine_deletes_selected_translation_history_and_related_records() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let translation_id = "translation-to-delete";
    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_completed_translation",
            "payload": {
                "id": translation_id,
                "source_language": "english",
                "target_language": "chinese",
                "source_text": "A sentence to remove.",
                "translated_text": "要删除的句子。",
                "provider_id": "local.test",
                "created_at": "2026-09-16T12:00:00+08:00"
            }
        }),
    );
    assert_eq!(saved["ok"], true);

    let annotation = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_translation_annotation",
            "payload": {
                "translation_id": translation_id,
                "note": "删除测试批注",
                "favorite": true,
                "added_to_learning": true,
                "updated_at": "2026-09-16T12:01:00+08:00"
            }
        }),
    );
    assert_eq!(annotation["ok"], true);

    let deleted = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "delete_translation_history",
            "payload": {"ids": [translation_id]}
        }),
    );
    assert_eq!(deleted["ok"], true);
    assert_eq!(deleted["data"]["deleted"], 1);

    let history = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_history",
            "payload": {"limit": 10}
        }),
    );
    assert_eq!(history["ok"], true);
    assert_eq!(history["data"]["translations"].as_array().unwrap().len(), 0);

    let annotations = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_annotations",
            "payload": {"limit": 10}
        }),
    );
    assert_eq!(annotations["ok"], true);
    assert_eq!(
        annotations["data"]["annotations"].as_array().unwrap().len(),
        0
    );

    let snapshot = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "home_snapshot",
            "payload": {"local_date": "2026-09-16", "recent_limit": 10}
        }),
    );
    assert_eq!(snapshot["ok"], true);
    assert_eq!(
        snapshot["data"]["snapshot"]["recent"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}

#[test]
fn engine_persists_translation_annotations_separately_from_history() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let translation = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "record_completed_translation",
            "payload": {
                "id": "translation-with-annotation",
                "source_language": "english",
                "target_language": "chinese",
                "source_text": "A useful sentence.",
                "translated_text": "一句有用的句子。",
                "provider_id": "local.test",
                "created_at": "2026-09-13T12:00:00+08:00"
            }
        }),
    );
    assert_eq!(translation["ok"], true);

    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_translation_annotation",
            "payload": {
                "translation_id": "translation-with-annotation",
                "note": "用于工作场景复习",
                "favorite": true,
                "added_to_learning": true,
                "updated_at": "2026-09-13T12:01:00+08:00"
            }
        }),
    );
    assert_eq!(saved["ok"], true);

    let listed = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_translation_annotations",
            "payload": {"limit": 10}
        }),
    );
    assert_eq!(listed["ok"], true);
    assert_eq!(
        listed["data"]["annotations"][0]["translation_id"],
        "translation-with-annotation"
    );
    assert_eq!(listed["data"]["annotations"][0]["favorite"], true);
    assert_eq!(listed["data"]["annotations"][0]["added_to_learning"], true);
}

#[test]
fn engine_persists_word_annotations_for_dictionary_learning() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let saved = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_word_annotation",
            "payload": {
                "word": "Apple",
                "note": "记录自己的工作例句",
                "added_to_learning": true,
                "updated_at": "2026-09-13T12:02:00+08:00"
            }
        }),
    );
    assert_eq!(saved["ok"], true);
    assert_eq!(saved["data"]["annotation"]["word"], "apple");

    let loaded = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "get_word_annotation",
            "payload": {"word": "APPLE"}
        }),
    );
    assert_eq!(loaded["ok"], true);
    assert_eq!(loaded["data"]["annotation"]["note"], "记录自己的工作例句");
    assert_eq!(loaded["data"]["annotation"]["added_to_learning"], true);
}

#[test]
fn engine_lists_favorite_word_details_with_paging() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let dictionary = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "save_dictionary_entry",
            "payload": {
                "id": "seed.consistency",
                "word": "consistency",
                "ipa": "/kənˈsɪstənsi/",
                "part_of_speech": "n. 名词",
                "meanings": ["一致性；连贯性"],
                "example": "Consistency is the key to success.",
                "example_translation": "一致性是成功的关键。",
                "source": "yixue-basic"
            }
        }),
    );
    assert_eq!(dictionary["ok"], true);

    let favorite = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "set_favorite_word",
            "payload": {"word": "consistency", "favorite": true}
        }),
    );
    assert_eq!(favorite["ok"], true);

    let page = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "list_favorite_word_page",
            "payload": {"query": "cons", "limit": 10, "offset": 0}
        }),
    );
    assert_eq!(page["ok"], true);
    assert_eq!(page["data"]["has_more"], false);
    assert_eq!(page["data"]["records"][0]["word"], "consistency");
    assert_eq!(page["data"]["records"][0]["language_pair"], "en-zh");
    assert_eq!(
        page["data"]["records"][0]["dictionary_entries"][0]["example"],
        "Consistency is the key to success."
    );
}

#[test]
fn engine_reports_local_storage_usage_by_category() {
    let engine = BridgeEngine::open_in_memory().expect("engine should open");
    let response = command(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "storage_usage",
            "payload": {}
        }),
    );

    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["records"].as_array().unwrap().len(), 7);
    assert_eq!(
        response["data"]["records"][0]["category"],
        "translation_history"
    );
}
