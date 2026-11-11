use std::{
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

use rusqlite::Connection;
use yixue_core::{
    CoreError, ModelCatalogEntry, ModelCatalogEntryDraft, ProviderProfile, ProviderProfileDraft,
    ProviderProfileKind, Storage,
};

fn remote_profile(endpoint: &str) -> Result<ProviderProfile, CoreError> {
    ProviderProfile::new(ProviderProfileDraft {
        id: "remote.openai-compatible".to_owned(),
        display_name: "OpenAI compatible".to_owned(),
        kind: ProviderProfileKind::RemoteApi,
        enabled: true,
        model_id: "translation-model".to_owned(),
        endpoint: Some(endpoint.to_owned()),
        model_path: None,
        secret_ref: Some("yixue.provider.remote.openai-compatible.api-key".to_owned()),
        assigned_roles: vec!["translation".to_owned()],
    })
}

#[test]
fn remote_profile_rejects_insecure_or_credential_bearing_endpoints() {
    assert_eq!(
        remote_profile("http://api.example.com/v1"),
        Err(CoreError::InvalidInput("remote endpoint must use HTTPS"))
    );
    let credential_bearing_endpoint = format!(
        "{}user:{}@api.example.com/v1",
        "https://", "not-a-real-password"
    );
    assert_eq!(
        remote_profile(&credential_bearing_endpoint),
        Err(CoreError::InvalidInput(
            "remote endpoint must not contain credentials"
        ))
    );
}

#[test]
fn loopback_http_endpoint_is_allowed_for_local_model_servers() {
    let profile = remote_profile("http://127.0.0.1:11434/v1")
        .expect("loopback HTTP endpoint should be accepted");

    assert_eq!(profile.endpoint(), Some("http://127.0.0.1:11434/v1"));
}

#[test]
fn local_model_requires_a_model_path_and_cannot_reference_a_secret() {
    let missing_path = ProviderProfile::new(ProviderProfileDraft {
        id: "local.m2m100".to_owned(),
        display_name: "M2M100".to_owned(),
        kind: ProviderProfileKind::LocalModel,
        enabled: true,
        model_id: "facebook/m2m100_418M".to_owned(),
        endpoint: None,
        model_path: None,
        secret_ref: None,
        assigned_roles: vec![],
    });
    assert_eq!(
        missing_path,
        Err(CoreError::InvalidInput("local model path is required"))
    );

    let secret_bearing_local = ProviderProfile::new(ProviderProfileDraft {
        id: "local.m2m100".to_owned(),
        display_name: "M2M100".to_owned(),
        kind: ProviderProfileKind::LocalModel,
        enabled: true,
        model_id: "facebook/m2m100_418M".to_owned(),
        endpoint: None,
        model_path: Some("D:\\Models\\m2m100".to_owned()),
        secret_ref: Some("yixue.provider.local.m2m100.api-key".to_owned()),
        assigned_roles: vec![],
    });
    assert_eq!(
        secret_bearing_local,
        Err(CoreError::InvalidInput(
            "local model must not reference an API secret"
        ))
    );
}

#[test]
fn provider_profile_round_trips_without_a_secret_value() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let profile = remote_profile("https://api.example.com/v1")
        .expect("remote provider profile should be valid");

    storage
        .save_provider_profile(&profile)
        .expect("profile should save");
    let profiles = storage
        .provider_profiles()
        .expect("profiles should be readable");

    assert_eq!(profiles, vec![profile]);
    assert_eq!(
        profiles[0].secret_ref(),
        Some("yixue.provider.remote.openai-compatible.api-key")
    );
}

#[test]
fn discovered_model_and_role_assignment_round_trip() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let model = ModelCatalogEntry::new(ModelCatalogEntryDraft {
        id: "catalog.qwen.1234".to_owned(),
        path: "D:\\models\\Qwen3.5-4B".to_owned(),
        display_name: "Qwen3.5-4B".to_owned(),
        family: "qwen".to_owned(),
        readiness: "runtime_required".to_owned(),
        capabilities: vec!["translation".to_owned(), "summarization".to_owned()],
        assigned_roles: vec!["understanding".to_owned()],
        source_language: Some("english".to_owned()),
        target_language: Some("chinese".to_owned()),
    })
    .expect("catalog entry should be valid");

    storage
        .save_model_catalog_entry(&model)
        .expect("catalog entry should save");
    let reopened = storage
        .model_catalog_entries()
        .expect("catalog entries should load");

    assert_eq!(reopened, vec![model]);
    assert_eq!(reopened[0].source_language(), Some("english"));
    assert_eq!(reopened[0].target_language(), Some("chinese"));
}

#[test]
fn version_one_database_migrates_without_adding_secret_columns() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock should be after epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "yixue-provider-migration-{}-{unique}.db",
        std::process::id()
    ));
    let connection = Connection::open(&path).expect("legacy database should open");
    connection
        .execute_batch(
            r"
            CREATE TABLE provider_profiles (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                display_name TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
                settings_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            PRAGMA user_version = 1;
            ",
        )
        .expect("legacy schema should be created");
    drop(connection);

    let storage = Storage::open(&path).expect("storage should migrate");
    assert_eq!(
        storage
            .health()
            .expect("health should work")
            .schema_version(),
        15
    );
    drop(storage);

    let connection = Connection::open(&path).expect("migrated database should open");
    let mut statement = connection
        .prepare("PRAGMA table_info(provider_profiles)")
        .expect("table metadata should be readable");
    let columns: Vec<String> = statement
        .query_map([], |row| row.get(1))
        .expect("column query should work")
        .collect::<Result<_, _>>()
        .expect("columns should decode");

    assert!(columns.contains(&"model_id".to_owned()));
    assert!(columns.contains(&"endpoint".to_owned()));
    assert!(columns.contains(&"model_path".to_owned()));
    assert!(columns.contains(&"secret_ref".to_owned()));
    let mut model_columns = connection
        .prepare("PRAGMA table_info(model_catalog)")
        .expect("model catalog metadata should be readable");
    let model_column_names: Vec<String> = model_columns
        .query_map([], |row| row.get(1))
        .expect("model catalog column query should work")
        .collect::<Result<_, _>>()
        .expect("model catalog columns should decode");
    assert!(model_column_names.contains(&"source_language".to_owned()));
    assert!(model_column_names.contains(&"target_language".to_owned()));
    drop(model_columns);
    assert!(!columns.iter().any(|name| {
        let normalized = name.to_ascii_lowercase();
        normalized == "api_key" || normalized == "secret" || normalized == "token"
    }));

    drop(statement);
    drop(connection);
    fs::remove_file(path).expect("temporary database should be removable");
}
