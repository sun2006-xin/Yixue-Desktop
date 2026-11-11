//! Stable C ABI bridge between Flutter and the Rust core.

#![deny(unsafe_code)]

#[allow(unsafe_code)]
mod ffi;

use std::{
    collections::HashMap,
    path::Path,
    sync::{Arc, Mutex},
};

use serde::Deserialize;
use serde_json::{Value, json};
use yixue_core::{
    ActivityEvent, ActivityEventDraft, CTranslate2Provider, CancellationToken,
    CompletedTranslation, CompletedTranslationDraft, ContentSource, ContentSourceDraft, CoreError,
    DictionaryEntry, DictionaryEntryDraft, Language, ModelCatalogEntry, ModelCatalogEntryDraft,
    ProcessCTranslate2Runtime, ProviderProfile, ProviderProfileDraft, ProviderProfileKind, Storage,
    TranslationAnnotation, TranslationAnnotationDraft, TranslationOrigin, TranslationProvider,
    TranslationRequest, WordAnnotation, WordAnnotationDraft, validate_model_package,
};

pub const BRIDGE_SCHEMA_VERSION: u32 = 1;

pub use ffi::{
    yixue_bridge_schema_version, yixue_engine_free, yixue_engine_open, yixue_engine_process_json,
    yixue_process_json, yixue_string_free,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeRequest {
    schema_version: u32,
    command: String,
    #[serde(default)]
    payload: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TranslationRequestPayload {
    id: String,
    source_language: Language,
    target_language: Language,
    text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HomeSnapshotPayload {
    local_date: String,
    recent_limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListHistoryPayload {
    limit: u32,
    #[serde(default)]
    offset: u32,
    #[serde(default)]
    origin: Option<TranslationOrigin>,
    #[serde(default)]
    query: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteHistoryPayload {
    ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ValidateScreenshotTranslationHistoryPayload {
    id: String,
    source_text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SaveScreenshotTranslationSummaryPayload {
    id: String,
    source_text: String,
    summary_text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScreenshotCaptureImageDeletionCandidatesPayload {
    ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScreenshotCaptureImageReferencesPayload {
    ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TranslationAnnotationPayload {
    translation_id: String,
    note: String,
    favorite: bool,
    added_to_learning: bool,
    updated_at: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListTranslationAnnotationsPayload {
    limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WordAnnotationPayload {
    word: String,
    note: String,
    added_to_learning: bool,
    updated_at: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WordAnnotationLookupPayload {
    word: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListContentSourcesPayload {
    limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListContentSourceVersionsPayload {
    source_id: String,
    limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RestoreContentSourceVersionPayload {
    source_id: String,
    version_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetContentSourceFavoritePayload {
    source_id: String,
    favorite: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ContentSourceIdPayload {
    source_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DictionaryLookupPayload {
    word: String,
    limit: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DictionaryEntryPagePayload {
    #[serde(default)]
    word: String,
    #[serde(default = "default_dictionary_entry_page_limit")]
    limit: u32,
    #[serde(default)]
    offset: u32,
}

fn default_dictionary_entry_page_limit() -> u32 {
    50
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FavoriteWordPayload {
    word: String,
    favorite: bool,
    #[serde(default)]
    created_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListFavoriteWordPagePayload {
    #[serde(default)]
    query: String,
    #[serde(default = "default_favorite_word_page_limit")]
    limit: u32,
    #[serde(default)]
    offset: u32,
}

fn default_favorite_word_page_limit() -> u32 {
    40
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelPackagePayload {
    model_path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigureLocalTranslationPayload {
    model_path: String,
    worker_path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CancelTranslationPayload {
    id: String,
}

/// Processes one versioned JSON command and always returns a JSON envelope.
#[must_use]
pub fn process_json(input: &str) -> String {
    process_json_with_engine(input, None)
}

pub struct BridgeEngine {
    storage: Mutex<Storage>,
    translation_provider: Mutex<Option<Arc<dyn TranslationProvider>>>,
    active_translations: Mutex<HashMap<String, CancellationToken>>,
}

impl BridgeEngine {
    /// Opens a persistent local engine database.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite cannot open or migrate the database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, CoreError> {
        Ok(Self {
            storage: Mutex::new(Storage::open(path)?),
            translation_provider: Mutex::new(None),
            active_translations: Mutex::new(HashMap::new()),
        })
    }

    /// Opens an isolated in-memory engine for tests.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite initialization fails.
    pub fn open_in_memory() -> Result<Self, CoreError> {
        Ok(Self {
            storage: Mutex::new(Storage::open_in_memory()?),
            translation_provider: Mutex::new(None),
            active_translations: Mutex::new(HashMap::new()),
        })
    }

    /// Replaces the active translation provider for subsequent requests.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::ProviderUnavailable`] if provider state is poisoned.
    pub fn set_translation_provider(
        &self,
        provider: Arc<dyn TranslationProvider>,
    ) -> Result<(), CoreError> {
        let mut active = self.translation_provider.lock().map_err(|_| {
            CoreError::ProviderUnavailable("translation provider state is unavailable".into())
        })?;
        *active = Some(provider);
        Ok(())
    }

    /// Processes one stateful, versioned JSON command.
    #[must_use]
    pub fn process_json(&self, input: &str) -> String {
        process_json_with_engine(input, Some(self))
    }
}

fn process_json_with_engine(input: &str, engine: Option<&BridgeEngine>) -> String {
    let request: BridgeRequest = match serde_json::from_str(input) {
        Ok(request) => request,
        Err(_) => return error_response("invalid_json", "request is not valid JSON"),
    };

    if request.schema_version != BRIDGE_SCHEMA_VERSION {
        return error_response("unsupported_schema", "bridge schema version is unsupported");
    }

    match request.command.as_str() {
        "health" => success_response(&json!({
            "core_version": yixue_core::CORE_VERSION,
        })),
        "validate_translation_request" => validate_translation_request(request.payload),
        "configure_local_translation" => with_engine(engine, |engine| {
            configure_local_translation(engine, request.payload)
        }),
        "translate" => with_engine(engine, |engine| translate(engine, request.payload)),
        "cancel_translation" => {
            with_engine(engine, |engine| cancel_translation(engine, request.payload))
        }
        "validate_model_package" => validate_model_package_command(request.payload),
        "save_provider_profile" => with_engine(engine, |engine| {
            save_provider_profile(engine, request.payload)
        }),
        "delete_provider_profile" => with_engine(engine, |engine| {
            delete_provider_profile(engine, &request.payload)
        }),
        "list_provider_profiles" => with_engine(engine, list_provider_profiles),
        "save_model_catalog_entry" => with_engine(engine, |engine| {
            save_model_catalog_entry(engine, request.payload)
        }),
        "delete_model_catalog_entry" => with_engine(engine, |engine| {
            delete_model_catalog_entry(engine, &request.payload)
        }),
        "list_model_catalog_entries" => with_engine(engine, list_model_catalog_entries),
        "record_activity" => with_engine(engine, |engine| record_activity(engine, request.payload)),
        "record_completed_translation" => with_engine(engine, |engine| {
            record_completed_translation(engine, request.payload)
        }),
        "list_translation_history" => with_engine(engine, |engine| {
            list_translation_history(engine, request.payload)
        }),
        "save_screenshot_translation_summary" => with_engine(engine, |engine| {
            save_screenshot_translation_summary(engine, request.payload)
        }),
        "validate_screenshot_translation_history" => with_engine(engine, |engine| {
            validate_screenshot_translation_history(engine, request.payload)
        }),
        "screenshot_capture_image_deletion_candidates" => with_engine(engine, |engine| {
            screenshot_capture_image_deletion_candidates(engine, request.payload)
        }),
        "screenshot_capture_image_references" => with_engine(engine, |engine| {
            screenshot_capture_image_references(engine, request.payload)
        }),
        "delete_translation_history" => with_engine(engine, |engine| {
            delete_translation_history(engine, request.payload)
        }),
        "save_translation_annotation" => with_engine(engine, |engine| {
            save_translation_annotation(engine, request.payload)
        }),
        "list_translation_annotations" => with_engine(engine, |engine| {
            list_translation_annotations(engine, request.payload)
        }),
        "save_word_annotation" => with_engine(engine, |engine| {
            save_word_annotation(engine, request.payload)
        }),
        "get_word_annotation" => with_engine(engine, |engine| {
            get_word_annotation(engine, request.payload)
        }),
        "save_content_source" => with_engine(engine, |engine| {
            save_content_source(engine, request.payload)
        }),
        "list_content_sources" => with_engine(engine, |engine| {
            list_content_sources(engine, request.payload)
        }),
        "save_content_source_version" => with_engine(engine, |engine| {
            save_content_source_version(engine, request.payload)
        }),
        "list_content_source_versions" => with_engine(engine, |engine| {
            list_content_source_versions(engine, request.payload)
        }),
        "restore_content_source_version" => with_engine(engine, |engine| {
            restore_content_source_version(engine, request.payload)
        }),
        "set_content_source_favorite" => with_engine(engine, |engine| {
            set_content_source_favorite(engine, request.payload)
        }),
        "trash_content_source" => with_engine(engine, |engine| {
            trash_content_source(engine, request.payload)
        }),
        "restore_content_source" => with_engine(engine, |engine| {
            restore_content_source(engine, request.payload)
        }),
        "delete_content_source" => with_engine(engine, |engine| {
            delete_content_source(engine, request.payload)
        }),
        "save_dictionary_entry" => with_engine(engine, |engine| {
            save_dictionary_entry(engine, request.payload)
        }),
        "list_dictionary_entries" => with_engine(engine, |engine| {
            list_dictionary_entries(engine, request.payload)
        }),
        "list_dictionary_entry_page" => with_engine(engine, |engine| {
            list_dictionary_entry_page(engine, request.payload)
        }),
        "set_favorite_word" => {
            with_engine(engine, |engine| set_favorite_word(engine, request.payload))
        }
        "list_favorite_words" => with_engine(engine, list_favorite_words),
        "list_favorite_word_page" => with_engine(engine, |engine| {
            list_favorite_word_page(engine, request.payload)
        }),
        "storage_usage" => with_engine(engine, storage_usage),
        "clear_user_data" => {
            with_engine(engine, |engine| clear_user_data(engine, &request.payload))
        }
        "home_snapshot" => with_engine(engine, |engine| home_snapshot(engine, request.payload)),
        "home_workbench_snapshot" => with_engine(engine, |engine| {
            home_workbench_snapshot(engine, request.payload)
        }),
        _ => error_response("unknown_command", "bridge command is unknown"),
    }
}

fn save_dictionary_entry(engine: &BridgeEngine, payload: Value) -> String {
    let draft: DictionaryEntryDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => return error_response("invalid_payload", "dictionary entry is invalid"),
    };
    let entry = match DictionaryEntry::new(draft) {
        Ok(entry) => entry,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_dictionary_entry(&entry) {
        Ok(()) => success_response(&json!({"entry": entry})),
        Err(error) => core_error_response(&error),
    }
}

fn list_dictionary_entries(engine: &BridgeEngine, payload: Value) -> String {
    let payload: DictionaryLookupPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "dictionary lookup is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.dictionary_entries(&payload.word, payload.limit) {
        Ok(entries) => success_response(&json!({"entries": entries})),
        Err(error) => core_error_response(&error),
    }
}

fn list_dictionary_entry_page(engine: &BridgeEngine, payload: Value) -> String {
    let payload: DictionaryEntryPagePayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "dictionary entry page is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.dictionary_entry_page(&payload.word, payload.limit, payload.offset) {
        Ok(page) => match serde_json::to_value(page) {
            Ok(data) => success_response(&data),
            Err(_) => error_response("serialization_error", "dictionary entry page is invalid"),
        },
        Err(error) => core_error_response(&error),
    }
}

fn set_favorite_word(engine: &BridgeEngine, payload: Value) -> String {
    let payload: FavoriteWordPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "favorite word is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    let result = match payload.created_at.as_deref() {
        Some(created_at) => {
            storage.set_favorite_word_at(&payload.word, payload.favorite, created_at)
        }
        None => storage.set_favorite_word(&payload.word, payload.favorite),
    };
    match result {
        Ok(()) => success_response(&json!({"word": payload.word, "favorite": payload.favorite})),
        Err(error) => core_error_response(&error),
    }
}

fn list_favorite_words(engine: &BridgeEngine) -> String {
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.favorite_words(200) {
        Ok(words) => success_response(&json!({"words": words})),
        Err(error) => core_error_response(&error),
    }
}

fn list_favorite_word_page(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ListFavoriteWordPagePayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "favorite word page is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.favorite_word_page(&payload.query, payload.limit, payload.offset) {
        Ok(page) => match serde_json::to_value(page) {
            Ok(data) => success_response(&data),
            Err(_) => error_response("serialization_error", "favorite word page is invalid"),
        },
        Err(error) => core_error_response(&error),
    }
}

fn storage_usage(engine: &BridgeEngine) -> String {
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.storage_usage() {
        Ok(usage) => match serde_json::to_value(usage) {
            Ok(data) => success_response(&data),
            Err(_) => error_response("serialization_error", "storage usage is invalid"),
        },
        Err(error) => core_error_response(&error),
    }
}

fn clear_user_data(engine: &BridgeEngine, payload: &Value) -> String {
    let Some(category) = payload.get("category").and_then(Value::as_str) else {
        return error_response("invalid_payload", "user-data category is invalid");
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.clear_user_data(category) {
        Ok(()) => success_response(&json!({"category": category, "cleared": true})),
        Err(error) => core_error_response(&error),
    }
}

fn configure_local_translation(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ConfigureLocalTranslationPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response(
                "invalid_payload",
                "local translation configuration is invalid",
            );
        }
    };
    let package = match validate_model_package(payload.model_path) {
        Ok(package) => package,
        Err(error) => return model_package_error_response(&error),
    };
    let runtime = match ProcessCTranslate2Runtime::new(payload.worker_path) {
        Ok(runtime) => Arc::new(runtime),
        Err(error) => return core_error_response(&error),
    };
    let provider = match CTranslate2Provider::new(package, runtime) {
        Ok(provider) => Arc::new(provider),
        Err(error) => return core_error_response(&error),
    };
    let provider_id = provider.capabilities().id().to_owned();
    match engine.set_translation_provider(provider) {
        Ok(()) => success_response(&json!({
            "configured": true,
            "provider_id": provider_id,
        })),
        Err(error) => core_error_response(&error),
    }
}

fn translate(engine: &BridgeEngine, payload: Value) -> String {
    let payload: TranslationRequestPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "translation payload is invalid"),
    };
    let request = match TranslationRequest::new(
        payload.id,
        payload.source_language,
        payload.target_language,
        payload.text,
    ) {
        Ok(request) => request,
        Err(error) => return core_error_response(&error),
    };
    let provider = match engine.translation_provider.lock() {
        Ok(active) => active.clone(),
        Err(_) => {
            return error_response(
                "provider_unavailable",
                "translation provider is unavailable",
            );
        }
    };
    let Some(provider) = provider else {
        return error_response(
            "provider_unavailable",
            "translation provider is unavailable",
        );
    };
    let cancellation = CancellationToken::new();
    {
        let Ok(mut active) = engine.active_translations.lock() else {
            return error_response(
                "provider_unavailable",
                "translation cancellation state is unavailable",
            );
        };
        if active.contains_key(request.id()) {
            return error_response("duplicate_request", "translation request is already active");
        }
        active.insert(request.id().to_owned(), cancellation.clone());
    }
    let result = provider.translate(&request, &cancellation);
    if let Ok(mut active) = engine.active_translations.lock() {
        active.remove(request.id());
    }
    match result {
        Ok(result) => success_response(&json!({ "translation": result })),
        Err(error) => core_error_response(&error),
    }
}

fn cancel_translation(engine: &BridgeEngine, payload: Value) -> String {
    let payload = match serde_json::from_value::<CancelTranslationPayload>(payload) {
        Ok(payload) if !payload.id.trim().is_empty() => payload,
        _ => return error_response("invalid_payload", "translation request id is invalid"),
    };
    let Ok(active) = engine.active_translations.lock() else {
        return error_response(
            "provider_unavailable",
            "translation cancellation state is unavailable",
        );
    };
    let cancellation = active.get(&payload.id).cloned();
    drop(active);
    if let Some(ref cancellation) = cancellation {
        cancellation.cancel();
    }
    success_response(&json!({
        "id": payload.id,
        "cancelled": cancellation.is_some(),
    }))
}

fn with_engine(
    engine: Option<&BridgeEngine>,
    operation: impl FnOnce(&BridgeEngine) -> String,
) -> String {
    match engine {
        Some(engine) => operation(engine),
        None => error_response("engine_required", "bridge command requires a local engine"),
    }
}

fn save_provider_profile(engine: &BridgeEngine, payload: Value) -> String {
    let draft: ProviderProfileDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => return error_response("invalid_payload", "provider profile payload is invalid"),
    };
    let profile = match ProviderProfile::new(draft) {
        Ok(profile) => profile,
        Err(error) => return core_error_response(&error),
    };
    if profile.kind() == ProviderProfileKind::LocalModel && profile.enabled() {
        let Some(model_path) = profile.model_path() else {
            return error_response("invalid_input", "local model path is required");
        };
        if let Err(error) = validate_model_package(model_path) {
            return model_package_error_response(&error);
        }
    }
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_provider_profile(&profile) {
        Ok(()) => success_response(&json!({ "profile": profile })),
        Err(error) => core_error_response(&error),
    }
}

fn list_provider_profiles(engine: &BridgeEngine) -> String {
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.provider_profiles() {
        Ok(profiles) => success_response(&json!({ "profiles": profiles })),
        Err(error) => core_error_response(&error),
    }
}

fn delete_provider_profile(engine: &BridgeEngine, payload: &Value) -> String {
    let Some(provider_id) = payload.get("id").and_then(Value::as_str) else {
        return error_response("invalid_payload", "provider id is invalid");
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.delete_provider_profile(provider_id) {
        Ok(()) => success_response(&json!({"id": provider_id, "deleted": true})),
        Err(error) => core_error_response(&error),
    }
}

fn save_model_catalog_entry(engine: &BridgeEngine, payload: Value) -> String {
    let draft: ModelCatalogEntryDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => return error_response("invalid_payload", "model catalog payload is invalid"),
    };
    let model = match ModelCatalogEntry::new(draft) {
        Ok(model) => model,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_model_catalog_entry(&model) {
        Ok(()) => success_response(&json!({ "model": model })),
        Err(error) => core_error_response(&error),
    }
}

fn list_model_catalog_entries(engine: &BridgeEngine) -> String {
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.model_catalog_entries() {
        Ok(models) => success_response(&json!({ "models": models })),
        Err(error) => core_error_response(&error),
    }
}

fn delete_model_catalog_entry(engine: &BridgeEngine, payload: &Value) -> String {
    let Some(model_id) = payload.get("id").and_then(Value::as_str) else {
        return error_response("invalid_payload", "model catalog id is invalid");
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.delete_model_catalog_entry(model_id) {
        Ok(()) => success_response(&json!({"id": model_id, "deleted": true})),
        Err(error) => core_error_response(&error),
    }
}

fn record_activity(engine: &BridgeEngine, payload: Value) -> String {
    let draft: ActivityEventDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => return error_response("invalid_payload", "activity payload is invalid"),
    };
    let activity = match ActivityEvent::from_draft(draft) {
        Ok(activity) => activity,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.record_activity(&activity) {
        Ok(()) => success_response(&json!({ "activity": activity })),
        Err(error) => core_error_response(&error),
    }
}

fn record_completed_translation(engine: &BridgeEngine, payload: Value) -> String {
    // Core serde defaults preserve old requests; provenance remains text metadata.
    let draft: CompletedTranslationDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => {
            return error_response("invalid_payload", "translation record payload is invalid");
        }
    };
    let translation = match CompletedTranslation::from_draft(draft) {
        Ok(translation) => translation,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_completed_translation(&translation) {
        Ok(()) => success_response(&json!({ "translation": translation })),
        Err(error) => core_error_response(&error),
    }
}

fn list_translation_history(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ListHistoryPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "history list payload is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.recent_translations_page_filtered(
        payload.limit.min(500),
        payload.offset.min(5000),
        payload.origin,
        &payload.query,
    ) {
        Ok(translations) => success_response(&json!({ "translations": translations })),
        Err(error) => core_error_response(&error),
    }
}

fn save_screenshot_translation_summary(engine: &BridgeEngine, payload: Value) -> String {
    let payload: SaveScreenshotTranslationSummaryPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response("invalid_payload", "screenshot summary payload is invalid");
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_screenshot_translation_summary(
        &payload.id,
        &payload.source_text,
        &payload.summary_text,
    ) {
        Ok(()) => success_response(&json!({ "saved": true })),
        Err(error) => core_error_response(&error),
    }
}

fn validate_screenshot_translation_history(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ValidateScreenshotTranslationHistoryPayload = match serde_json::from_value(payload)
    {
        Ok(payload) => payload,
        Err(_) => {
            return error_response(
                "invalid_payload",
                "screenshot translation history validation payload is invalid",
            );
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.screenshot_translation_history_matches(&payload.id, &payload.source_text) {
        Ok(matches) => success_response(&json!({ "matches": matches })),
        Err(error) => core_error_response(&error),
    }
}

fn screenshot_capture_image_deletion_candidates(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ScreenshotCaptureImageDeletionCandidatesPayload =
        match serde_json::from_value(payload) {
            Ok(payload) => payload,
            Err(_) => {
                return error_response(
                    "invalid_payload",
                    "screenshot image deletion candidate payload is invalid",
                );
            }
        };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.screenshot_capture_ids_orphaned_by_history_deletion(&payload.ids) {
        Ok(ids) => success_response(&json!({ "captureIds": ids })),
        Err(error) => core_error_response(&error),
    }
}

fn screenshot_capture_image_references(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ScreenshotCaptureImageReferencesPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response(
                "invalid_payload",
                "screenshot image reference payload is invalid",
            );
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.screenshot_capture_ids_still_referenced(&payload.ids) {
        Ok(ids) => success_response(&json!({ "captureIds": ids })),
        Err(error) => core_error_response(&error),
    }
}

fn delete_translation_history(engine: &BridgeEngine, payload: Value) -> String {
    let payload: DeleteHistoryPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "history delete payload is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.delete_translation_history(&payload.ids) {
        Ok(()) => success_response(&json!({
            "deleted": payload.ids.len(),
        })),
        Err(error) => core_error_response(&error),
    }
}

fn save_translation_annotation(engine: &BridgeEngine, payload: Value) -> String {
    let draft: TranslationAnnotationPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "translation annotation is invalid"),
    };
    let annotation = match TranslationAnnotation::new(TranslationAnnotationDraft {
        translation_id: draft.translation_id,
        note: draft.note,
        favorite: draft.favorite,
        added_to_learning: draft.added_to_learning,
        updated_at: draft.updated_at,
    }) {
        Ok(annotation) => annotation,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_translation_annotation(&annotation) {
        Ok(()) => success_response(&json!({ "annotation": annotation })),
        Err(error) => core_error_response(&error),
    }
}

fn list_translation_annotations(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ListTranslationAnnotationsPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response("invalid_payload", "translation annotation list is invalid");
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.translation_annotations(payload.limit.min(500)) {
        Ok(annotations) => success_response(&json!({ "annotations": annotations })),
        Err(error) => core_error_response(&error),
    }
}

fn save_word_annotation(engine: &BridgeEngine, payload: Value) -> String {
    let draft: WordAnnotationPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "word annotation is invalid"),
    };
    let annotation = match WordAnnotation::new(WordAnnotationDraft {
        word: draft.word,
        note: draft.note,
        added_to_learning: draft.added_to_learning,
        updated_at: draft.updated_at,
    }) {
        Ok(annotation) => annotation,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_word_annotation(&annotation) {
        Ok(()) => success_response(&json!({ "annotation": annotation })),
        Err(error) => core_error_response(&error),
    }
}

fn get_word_annotation(engine: &BridgeEngine, payload: Value) -> String {
    let payload: WordAnnotationLookupPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "word annotation lookup is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.word_annotation(&payload.word) {
        Ok(annotation) => success_response(&json!({ "annotation": annotation })),
        Err(error) => core_error_response(&error),
    }
}

fn save_content_source(engine: &BridgeEngine, payload: Value) -> String {
    let draft: ContentSourceDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => return error_response("invalid_payload", "content source payload is invalid"),
    };
    let source = match ContentSource::from_draft(draft) {
        Ok(source) => source,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_content_source(&source) {
        Ok(()) => success_response(&json!({ "source": source })),
        Err(error) => core_error_response(&error),
    }
}

fn list_content_sources(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ListContentSourcesPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response("invalid_payload", "content source list payload is invalid");
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.content_sources(payload.limit.min(100)) {
        Ok(sources) => success_response(&json!({ "sources": sources })),
        Err(error) => core_error_response(&error),
    }
}

fn save_content_source_version(engine: &BridgeEngine, payload: Value) -> String {
    let draft: ContentSourceDraft = match serde_json::from_value(payload) {
        Ok(draft) => draft,
        Err(_) => return error_response("invalid_payload", "content source payload is invalid"),
    };
    let source = match ContentSource::from_draft(draft) {
        Ok(source) => source,
        Err(error) => return core_error_response(&error),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.save_content_source_version(&source) {
        Ok(version) => success_response(&json!({ "version": version })),
        Err(error) => core_error_response(&error),
    }
}

fn list_content_source_versions(engine: &BridgeEngine, payload: Value) -> String {
    let payload: ListContentSourceVersionsPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response(
                "invalid_payload",
                "content source version list payload is invalid",
            );
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.content_source_versions(&payload.source_id, payload.limit.min(100)) {
        Ok(versions) => success_response(&json!({ "versions": versions })),
        Err(error) => core_error_response(&error),
    }
}

fn restore_content_source_version(engine: &BridgeEngine, payload: Value) -> String {
    let payload: RestoreContentSourceVersionPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response(
                "invalid_payload",
                "content source version restore payload is invalid",
            );
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.restore_content_source_version(&payload.source_id, &payload.version_id) {
        Ok(source) => success_response(&json!({ "source": source })),
        Err(error) => core_error_response(&error),
    }
}

fn set_content_source_favorite(engine: &BridgeEngine, payload: Value) -> String {
    let payload: SetContentSourceFavoritePayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => {
            return error_response(
                "invalid_payload",
                "content source favorite payload is invalid",
            );
        }
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.set_content_source_favorite(&payload.source_id, payload.favorite) {
        Ok(()) => success_response(&json!({
            "source_id": payload.source_id,
            "favorite": payload.favorite,
        })),
        Err(error) => core_error_response(&error),
    }
}

fn trash_content_source(engine: &BridgeEngine, payload: Value) -> String {
    change_content_source_state(engine, payload, |storage, source_id| {
        storage.trash_content_source(source_id)
    })
}

fn restore_content_source(engine: &BridgeEngine, payload: Value) -> String {
    change_content_source_state(engine, payload, |storage, source_id| {
        storage.restore_content_source(source_id)
    })
}

fn delete_content_source(engine: &BridgeEngine, payload: Value) -> String {
    change_content_source_state(engine, payload, |storage, source_id| {
        storage.delete_content_source(source_id)
    })
}

fn change_content_source_state(
    engine: &BridgeEngine,
    payload: Value,
    action: impl FnOnce(&Storage, &str) -> Result<(), CoreError>,
) -> String {
    let payload: ContentSourceIdPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "content source id payload is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match action(&storage, &payload.source_id) {
        Ok(()) => success_response(&json!({ "source_id": payload.source_id })),
        Err(error) => core_error_response(&error),
    }
}

fn home_snapshot(engine: &BridgeEngine, payload: Value) -> String {
    let payload: HomeSnapshotPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "home snapshot payload is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.home_snapshot(&payload.local_date, payload.recent_limit.min(20)) {
        Ok(snapshot) => success_response(&json!({ "snapshot": snapshot })),
        Err(error) => core_error_response(&error),
    }
}

fn home_workbench_snapshot(engine: &BridgeEngine, payload: Value) -> String {
    let payload: HomeSnapshotPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "home snapshot payload is invalid"),
    };
    let Ok(storage) = engine.storage.lock() else {
        return error_response("storage_error", "local storage operation failed");
    };
    match storage.home_workbench_snapshot(&payload.local_date, payload.recent_limit.min(100)) {
        Ok(snapshot) => success_response(&json!({ "snapshot": snapshot })),
        Err(error) => core_error_response(&error),
    }
}

fn validate_translation_request(payload: Value) -> String {
    let payload: TranslationRequestPayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "translation payload is invalid"),
    };

    match TranslationRequest::new(
        payload.id,
        payload.source_language,
        payload.target_language,
        payload.text,
    ) {
        Ok(_) => success_response(&json!({ "valid": true })),
        Err(error) => core_error_response(&error),
    }
}

fn validate_model_package_command(payload: Value) -> String {
    let payload: ModelPackagePayload = match serde_json::from_value(payload) {
        Ok(payload) => payload,
        Err(_) => return error_response("invalid_payload", "model package payload is invalid"),
    };
    match validate_model_package(payload.model_path) {
        Ok(package) => success_response(&json!({
            "package_id": package.package_id(),
            "display_name": package.display_name(),
            "source_language": package.source_language(),
            "target_language": package.target_language(),
            "base_model": package.base_model(),
            "license": package.license(),
            "verified_file_count": package.verified_file_count(),
            "total_bytes": package.total_bytes(),
        })),
        Err(error) => model_package_error_response(&error),
    }
}

fn model_package_error_response(error: &yixue_core::ModelPackageError) -> String {
    error_response(
        "model_package_invalid",
        &format!("local model package failed verification: {error}"),
    )
}

fn success_response(data: &Value) -> String {
    json!({
        "ok": true,
        "schema_version": BRIDGE_SCHEMA_VERSION,
        "data": data,
    })
    .to_string()
}

fn core_error_response(error: &CoreError) -> String {
    match error {
        CoreError::InvalidInput(message) => error_response("invalid_input", message),
        CoreError::Cancelled => error_response("cancelled", "operation was cancelled"),
        CoreError::ProviderUnavailable(_) => error_response(
            "provider_unavailable",
            "translation provider is unavailable",
        ),
        CoreError::DuplicateProvider(_) => {
            error_response("duplicate_provider", "translation provider already exists")
        }
        CoreError::UnsupportedLanguagePair => {
            error_response("unsupported_language_pair", "language pair is unsupported")
        }
        CoreError::InvalidProviderOutput => error_response(
            "invalid_provider_output",
            "translation provider returned invalid output",
        ),
        CoreError::Storage(_) => error_response("storage_error", "local storage operation failed"),
    }
}

fn error_response(code: &str, message: &str) -> String {
    json!({
        "ok": false,
        "schema_version": BRIDGE_SCHEMA_VERSION,
        "error": {
            "code": code,
            "message": message,
        },
    })
    .to_string()
}

pub(crate) fn bridge_error(code: &str, message: &str) -> String {
    error_response(code, message)
}
