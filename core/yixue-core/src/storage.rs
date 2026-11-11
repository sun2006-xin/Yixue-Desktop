use std::{fmt::Write, path::Path};

use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::{
    ActivityEvent, ActivityEventDraft, ActivityKind, CompletedTranslation,
    CompletedTranslationDraft, ContentSource, ContentSourceVersion, CoreError, DictionaryEntry,
    DictionaryEntryDraft, HomeMetricData, HomeSnapshot, HomeWorkbenchSnapshot,
    HomeWorkbenchSummary, Language, ModelCatalogEntry, ModelCatalogEntryDraft, ProviderProfile,
    ProviderProfileDraft, ProviderProfileKind, TranslationAnnotation, TranslationAnnotationDraft,
    TranslationOrigin, WordAnnotation, WordAnnotationDraft,
};

const LATEST_SCHEMA_VERSION: u32 = 15;

fn sha256_hex(input: &[u8]) -> String {
    let mut encoded = String::with_capacity(64);
    for byte in Sha256::digest(input) {
        write!(&mut encoded, "{byte:02x}").expect("writing to a string should succeed");
    }
    encoded
}

const REQUIRED_TABLES: [&str; 12] = [
    "activity_events",
    "content_sources",
    "content_source_versions",
    "learning_items",
    "model_catalog",
    "provider_profiles",
    "study_attempts",
    "translation_history",
    "translation_annotations",
    "word_annotations",
    "dictionary_entries",
    "favorite_words",
];

const LATEST_SCHEMA: &str = r"
CREATE TABLE IF NOT EXISTS content_sources (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    local_path TEXT,
    created_at TEXT NOT NULL,
    content_text TEXT NOT NULL DEFAULT '',
    reading_position INTEGER NOT NULL DEFAULT 0 CHECK (reading_position >= 0),
    translated_paragraphs_json TEXT NOT NULL DEFAULT '{}',
    is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
    deleted_at TEXT,
    updated_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS content_source_versions (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES content_sources(id) ON DELETE CASCADE,
    version INTEGER NOT NULL CHECK (version > 0),
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    local_path TEXT,
    content_text TEXT NOT NULL,
    reading_position INTEGER NOT NULL DEFAULT 0 CHECK (reading_position >= 0),
    translated_paragraphs_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    UNIQUE(source_id, version)
);
CREATE INDEX IF NOT EXISTS content_source_versions_source_id
    ON content_source_versions(source_id, version DESC);

CREATE TABLE IF NOT EXISTS translation_history (
    id TEXT PRIMARY KEY,
    origin TEXT NOT NULL DEFAULT 'quick_translation' CHECK (origin IN ('quick_translation', 'screenshot_translation')),
    source_language TEXT NOT NULL,
    target_language TEXT NOT NULL,
    source_text TEXT NOT NULL,
    translated_text TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    source_id TEXT REFERENCES content_sources(id) ON DELETE SET NULL,
    screenshot_capture_id TEXT,
    screenshot_ocr_layout TEXT,
    translated_source_block_indices TEXT,
    summary_text TEXT,
    summary_source_hash TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS translation_annotations (
    translation_id TEXT PRIMARY KEY REFERENCES translation_history(id) ON DELETE CASCADE,
    note TEXT NOT NULL DEFAULT '',
    favorite INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1)),
    added_to_learning INTEGER NOT NULL DEFAULT 0 CHECK (added_to_learning IN (0, 1)),
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS word_annotations (
    word TEXT PRIMARY KEY,
    note TEXT NOT NULL DEFAULT '',
    added_to_learning INTEGER NOT NULL DEFAULT 0 CHECK (added_to_learning IN (0, 1)),
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS learning_items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    prompt TEXT NOT NULL,
    expected_answer TEXT,
    source_id TEXT REFERENCES content_sources(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS study_attempts (
    id TEXT PRIMARY KEY,
    learning_item_id TEXT NOT NULL REFERENCES learning_items(id) ON DELETE CASCADE,
    answer TEXT NOT NULL,
    judgement TEXT NOT NULL,
    feedback TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS provider_profiles (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    display_name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
    model_id TEXT NOT NULL,
    endpoint TEXT,
    model_path TEXT,
    secret_ref TEXT,
    assigned_roles_json TEXT NOT NULL DEFAULT '[]',
    settings_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS activity_events (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    detail TEXT,
    source_id TEXT,
    duration_seconds INTEGER NOT NULL DEFAULT 0 CHECK (duration_seconds >= 0),
    item_count INTEGER NOT NULL DEFAULT 0 CHECK (item_count >= 0),
    occurred_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS activity_events_occurred_at
    ON activity_events(occurred_at DESC);

CREATE TABLE IF NOT EXISTS model_catalog (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    display_name TEXT NOT NULL,
    family TEXT NOT NULL,
    readiness TEXT NOT NULL,
    capabilities_json TEXT NOT NULL,
    assigned_roles_json TEXT NOT NULL DEFAULT '[]',
    source_language TEXT,
    target_language TEXT,
    discovered_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS dictionary_entries (
    id TEXT PRIMARY KEY,
    word TEXT NOT NULL,
    ipa TEXT NOT NULL,
    part_of_speech TEXT NOT NULL,
    meanings_json TEXT NOT NULL,
    example TEXT NOT NULL,
    example_translation TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS dictionary_entries_word ON dictionary_entries(word COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS favorite_words (
    word TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
);
";

const MIGRATE_V1_TO_V2: &str = r"
ALTER TABLE provider_profiles ADD COLUMN model_id TEXT NOT NULL DEFAULT '';
ALTER TABLE provider_profiles ADD COLUMN endpoint TEXT;
ALTER TABLE provider_profiles ADD COLUMN model_path TEXT;
ALTER TABLE provider_profiles ADD COLUMN secret_ref TEXT;
UPDATE provider_profiles SET settings_json = '{}';
";

const MIGRATE_V2_TO_V3: &str = r"
CREATE TABLE activity_events (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    detail TEXT,
    duration_seconds INTEGER NOT NULL DEFAULT 0 CHECK (duration_seconds >= 0),
    item_count INTEGER NOT NULL DEFAULT 0 CHECK (item_count >= 0),
    occurred_at TEXT NOT NULL
);
CREATE INDEX activity_events_occurred_at ON activity_events(occurred_at DESC);
";

const MIGRATE_V3_TO_V4: &str = r"
CREATE TABLE model_catalog (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    display_name TEXT NOT NULL,
    family TEXT NOT NULL,
    readiness TEXT NOT NULL,
    capabilities_json TEXT NOT NULL,
    assigned_roles_json TEXT NOT NULL DEFAULT '[]',
    discovered_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
";

const MIGRATE_V4_TO_V5: &str = r"
CREATE TABLE IF NOT EXISTS content_sources (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    local_path TEXT,
    created_at TEXT NOT NULL
);
ALTER TABLE content_sources ADD COLUMN content_text TEXT NOT NULL DEFAULT '';
ALTER TABLE content_sources ADD COLUMN reading_position INTEGER NOT NULL DEFAULT 0;
ALTER TABLE content_sources ADD COLUMN translated_paragraphs_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE content_sources ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';
";

const MIGRATE_V5_TO_V6: &str = r"
CREATE TABLE dictionary_entries (
    id TEXT PRIMARY KEY,
    word TEXT NOT NULL,
    ipa TEXT NOT NULL,
    part_of_speech TEXT NOT NULL,
    meanings_json TEXT NOT NULL,
    example TEXT NOT NULL,
    example_translation TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX dictionary_entries_word ON dictionary_entries(word COLLATE NOCASE);
CREATE TABLE favorite_words (
    word TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
);
";

const MIGRATE_V6_TO_V7: &str = r"
ALTER TABLE model_catalog ADD COLUMN source_language TEXT;
ALTER TABLE model_catalog ADD COLUMN target_language TEXT;
";

const MIGRATE_V7_TO_V8: &str = r"
ALTER TABLE provider_profiles ADD COLUMN assigned_roles_json TEXT NOT NULL DEFAULT '[]';
";

const MIGRATE_V8_TO_V9: &str = r"
CREATE TABLE IF NOT EXISTS translation_annotations (
    translation_id TEXT PRIMARY KEY REFERENCES translation_history(id) ON DELETE CASCADE,
    note TEXT NOT NULL DEFAULT '',
    favorite INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1)),
    added_to_learning INTEGER NOT NULL DEFAULT 0 CHECK (added_to_learning IN (0, 1)),
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS word_annotations (
    word TEXT PRIMARY KEY,
    note TEXT NOT NULL DEFAULT '',
    added_to_learning INTEGER NOT NULL DEFAULT 0 CHECK (added_to_learning IN (0, 1)),
    updated_at TEXT NOT NULL
);
";

const MIGRATE_V9_TO_V10: &str = r"
CREATE INDEX IF NOT EXISTS activity_events_source_id
    ON activity_events(source_id);
";

const MIGRATE_V10_TO_V11: &str = r"
CREATE TABLE IF NOT EXISTS content_source_versions (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES content_sources(id) ON DELETE CASCADE,
    version INTEGER NOT NULL CHECK (version > 0),
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    local_path TEXT,
    content_text TEXT NOT NULL,
    reading_position INTEGER NOT NULL DEFAULT 0 CHECK (reading_position >= 0),
    translated_paragraphs_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    UNIQUE(source_id, version)
);
CREATE INDEX IF NOT EXISTS content_source_versions_source_id
    ON content_source_versions(source_id, version DESC);
";

const MIGRATE_V11_TO_V12: &str = r"
ALTER TABLE content_sources ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0
    CHECK (is_favorite IN (0, 1));
ALTER TABLE content_sources ADD COLUMN deleted_at TEXT;
";

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FavoriteWordRecord {
    pub word: String,
    pub favorited_at: String,
    pub language_pair: String,
    pub dictionary_entries: Vec<DictionaryEntry>,
    pub annotation: Option<WordAnnotation>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FavoriteWordPage {
    pub records: Vec<FavoriteWordRecord>,
    pub has_more: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DictionaryEntryPage {
    pub entries: Vec<DictionaryEntry>,
    pub has_more: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StorageUsageRecord {
    pub category: String,
    pub used_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StorageUsageSnapshot {
    pub records: Vec<StorageUsageRecord>,
}

pub struct Storage {
    connection: Connection,
}

impl Storage {
    /// Opens a local database and installs pending schema changes.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when the database cannot be opened or migrated.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, CoreError> {
        let connection = Connection::open(path).map_err(CoreError::from)?;
        let storage = Self { connection };
        storage.ensure_schema()?;
        Ok(storage)
    }

    /// Opens an isolated in-memory database and installs the schema.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite initialization fails.
    pub fn open_in_memory() -> Result<Self, CoreError> {
        let connection = Connection::open_in_memory().map_err(CoreError::from)?;
        let storage = Self { connection };
        storage.ensure_schema()?;
        Ok(storage)
    }

    /// Applies all schema changes that are safe to run for the current version.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite rejects the migration batch.
    pub fn ensure_schema(&self) -> Result<(), CoreError> {
        self.connection
            .execute_batch("PRAGMA foreign_keys = ON;")
            .map_err(CoreError::from)?;
        let current_version: u32 = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(CoreError::from)?;

        match current_version {
            0 => self.install_latest_schema(),
            1 => {
                self.migrate_version_one()?;
                self.migrate_version_two()?;
                self.migrate_version_three()?;
                self.migrate_version_five()?;
                self.migrate_version_six()?;
                self.migrate_version_seven()?;
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            2 => {
                self.migrate_version_two()?;
                self.migrate_version_three()?;
                self.migrate_version_five()?;
                self.migrate_version_six()?;
                self.migrate_version_seven()?;
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            3 => {
                self.migrate_version_three()?;
                self.migrate_version_five()?;
                self.migrate_version_six()?;
                self.migrate_version_seven()?;
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            4 => {
                self.migrate_version_five()?;
                self.migrate_version_six()?;
                self.migrate_version_seven()?;
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            5 => {
                self.migrate_version_six()?;
                self.migrate_version_seven()?;
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            6 => {
                self.migrate_version_seven()?;
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            7 => {
                self.migrate_version_eight()?;
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            8 => {
                self.migrate_version_nine()?;
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            9 => {
                self.migrate_version_ten()?;
                self.migrate_version_eleven()
            }
            10 => self.migrate_version_eleven(),
            11 => self.migrate_version_twelve(),
            12 => self.migrate_version_thirteen(),
            13 => self.migrate_version_fourteen(),
            14 => self.migrate_version_fifteen(),
            // A pre-release v15 candidate added only screenshot summary
            // columns. Complete that schema in place without downgrading its
            // version marker or disturbing existing history.
            15 => {
                self.ensure_screenshot_translation_summary_columns()?;
                self.ensure_screenshot_translation_alignment_columns()
            }
            version => Err(CoreError::Storage(format!(
                "database schema version {version} is newer than supported version {LATEST_SCHEMA_VERSION}"
            ))),
        }
    }

    fn install_latest_schema(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(LATEST_SCHEMA)
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(
                "CREATE INDEX IF NOT EXISTS translation_history_screenshot_capture_id
                 ON translation_history(screenshot_capture_id)
                 WHERE origin = 'screenshot_translation';",
            )
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", LATEST_SCHEMA_VERSION)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn ensure_screenshot_translation_summary_columns(&self) -> Result<(), CoreError> {
        // These nullable fields are a compatible extension of v14: older
        // desktop Core builds query named columns and reject only a newer
        // user_version, so leave PRAGMA user_version unchanged here.
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        let has_summary_text: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('translation_history') WHERE name = 'summary_text'",
                [],
                |row| row.get(0),
            )
            .map_err(CoreError::from)?;
        if has_summary_text == 0 {
            transaction
                .execute_batch("ALTER TABLE translation_history ADD COLUMN summary_text TEXT;")
                .map_err(CoreError::from)?;
        }
        let has_summary_source_hash: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('translation_history') WHERE name = 'summary_source_hash'",
                [],
                |row| row.get(0),
            )
            .map_err(CoreError::from)?;
        if has_summary_source_hash == 0 {
            transaction
                .execute_batch(
                    "ALTER TABLE translation_history ADD COLUMN summary_source_hash TEXT;",
                )
                .map_err(CoreError::from)?;
        }
        transaction.commit().map_err(CoreError::from)
    }

    fn ensure_screenshot_translation_alignment_columns(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        for (column, sql_type) in [
            ("screenshot_ocr_layout", "TEXT"),
            ("translated_source_block_indices", "TEXT"),
        ] {
            let has_column: i64 = transaction
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_info('translation_history') WHERE name = ?1",
                    [column],
                    |row| row.get(0),
                )
                .map_err(CoreError::from)?;
            if has_column == 0 {
                transaction
                    .execute_batch(&format!(
                        "ALTER TABLE translation_history ADD COLUMN {column} {sql_type};"
                    ))
                    .map_err(CoreError::from)?;
            }
        }
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_fifteen(&self) -> Result<(), CoreError> {
        self.ensure_screenshot_translation_summary_columns()?;
        self.ensure_screenshot_translation_alignment_columns()?;
        self.connection
            .pragma_update(None, "user_version", LATEST_SCHEMA_VERSION)
            .map_err(CoreError::from)
    }

    fn migrate_version_one(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V1_TO_V2)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 2)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_three(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V3_TO_V4)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 4)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_five(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V4_TO_V5)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 5)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_six(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V5_TO_V6)
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(LATEST_SCHEMA)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 6)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_seven(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V6_TO_V7)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 7)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_eight(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V7_TO_V8)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 8)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_nine(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V8_TO_V9)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 9)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_ten(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        let has_source_id: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('activity_events') WHERE name = 'source_id'",
                [],
                |row| row.get(0),
            )
            .map_err(CoreError::from)?;
        if has_source_id == 0 {
            transaction
                .execute_batch("ALTER TABLE activity_events ADD COLUMN source_id TEXT;")
                .map_err(CoreError::from)?;
        }
        transaction
            .execute_batch(MIGRATE_V9_TO_V10)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 10)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    fn migrate_version_eleven(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V10_TO_V11)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 11)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)?;
        self.migrate_version_twelve()
    }

    fn migrate_version_twelve(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V11_TO_V12)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 12)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)?;
        self.migrate_version_thirteen()
    }

    fn migrate_version_thirteen(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        // Early migrations may already install the latest table definition.
        let has_origin: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('translation_history') WHERE name = 'origin'",
                [],
                |row| row.get(0),
            )
            .map_err(CoreError::from)?;
        if has_origin == 0 {
            transaction
                .execute_batch(
                    "ALTER TABLE translation_history ADD COLUMN origin TEXT NOT NULL DEFAULT 'quick_translation' CHECK (origin IN ('quick_translation', 'screenshot_translation'));",
                )
                .map_err(CoreError::from)?;
        }
        transaction
            .pragma_update(None, "user_version", 13)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)?;
        self.migrate_version_fourteen()
    }

    fn migrate_version_fourteen(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        // Fresh databases already contain the column through LATEST_SCHEMA.
        // Existing databases from v13 receive the nullable association field.
        let has_capture_id: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('translation_history') WHERE name = 'screenshot_capture_id'",
                [],
                |row| row.get(0),
            )
            .map_err(CoreError::from)?;
        if has_capture_id == 0 {
            transaction
                .execute_batch(
                    "ALTER TABLE translation_history ADD COLUMN screenshot_capture_id TEXT;",
                )
                .map_err(CoreError::from)?;
        }
        transaction
            .execute_batch(
                "CREATE INDEX IF NOT EXISTS translation_history_screenshot_capture_id
                 ON translation_history(screenshot_capture_id)
                 WHERE origin = 'screenshot_translation';",
            )
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 14)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)?;
        self.migrate_version_fifteen()
    }

    /// Saves or updates one dictionary entry.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite or JSON serialization fails.
    pub fn save_dictionary_entry(&self, entry: &DictionaryEntry) -> Result<(), CoreError> {
        let meanings = serde_json::to_string(entry.meanings())
            .map_err(|error| CoreError::Storage(error.to_string()))?;
        self.connection.execute(
            "INSERT INTO dictionary_entries (id, word, ipa, part_of_speech, meanings_json, example, example_translation, source, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,datetime('now'),datetime('now')) ON CONFLICT(id) DO UPDATE SET word=excluded.word, ipa=excluded.ipa, part_of_speech=excluded.part_of_speech, meanings_json=excluded.meanings_json, example=excluded.example, example_translation=excluded.example_translation, source=excluded.source, updated_at=datetime('now')",
            params![entry.id(), entry.word(), entry.ipa(), entry.part_of_speech(), meanings, entry.example(), entry.example_translation(), entry.source()]
        ).map_err(CoreError::from)?;
        Ok(())
    }

    /// Finds dictionary entries by a case-insensitive word or meaning fragment.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite or stored JSON is invalid.
    pub fn dictionary_entries(
        &self,
        word: &str,
        limit: u32,
    ) -> Result<Vec<DictionaryEntry>, CoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        Ok(self.dictionary_entry_page(word, limit.min(50), 0)?.entries)
    }

    /// Lists dictionary records in bounded, deterministic pages.
    ///
    /// The blank query is used by learning workspaces to enumerate the local
    /// dictionary. The extra row determines whether another page exists.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite or stored JSON is invalid.
    pub fn dictionary_entry_page(
        &self,
        word: &str,
        limit: u32,
        offset: u32,
    ) -> Result<DictionaryEntryPage, CoreError> {
        let query = word.trim();
        let word_pattern = format!("%{}%", query);
        let meaning_pattern = format!("%{}%", query);
        let page_limit = limit.clamp(1, 100);
        let fetch_limit = page_limit + 1;
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, word, ipa, part_of_speech, meanings_json, example, example_translation, source \
                 FROM dictionary_entries \
                 WHERE word LIKE ?1 COLLATE NOCASE OR meanings_json LIKE ?2 \
                 ORDER BY CASE WHEN word = ?3 COLLATE NOCASE THEN 0 ELSE 1 END, \
                          CASE WHEN instr( \
                            '|' || \
                            replace(replace(replace(replace(replace(replace(replace( \
                              meanings_json, '\"', '|'), '；', '|'), ';', '|'), \
                              '，', '|'), ',', '|'), '、', '|'), '/', '|') || '|', \
                            '|' || ?4 || '|') > 0 THEN 0 ELSE 1 END, \
                          word COLLATE NOCASE, id \
                  LIMIT ?5 OFFSET ?6",
            )
            .map_err(CoreError::from)?;
        let mut entries = statement
            .query_map(
                params![
                    word_pattern,
                    meaning_pattern,
                    query,
                    query,
                    fetch_limit,
                    offset,
                ],
                |row| {
                    Ok(DictionaryEntryDraft {
                        id: row.get(0)?,
                        word: row.get(1)?,
                        ipa: row.get(2)?,
                        part_of_speech: row.get(3)?,
                        meanings: serde_json::from_str(&row.get::<_, String>(4)?)
                            .unwrap_or_default(),
                        example: row.get(5)?,
                        example_translation: row.get(6)?,
                        source: row.get(7)?,
                    })
                },
            )
            .map_err(CoreError::from)?;
        let mut entries = entries
            .by_ref()
            .map(|row| DictionaryEntry::new(row.map_err(CoreError::from)?))
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = entries.len() > page_limit as usize;
        entries.truncate(page_limit as usize);
        Ok(DictionaryEntryPage { entries, has_more })
    }

    fn dictionary_entries_exact(
        &self,
        word: &str,
        limit: u32,
    ) -> Result<Vec<DictionaryEntry>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, word, ipa, part_of_speech, meanings_json, example, example_translation, source FROM dictionary_entries WHERE word = ?1 COLLATE NOCASE ORDER BY id LIMIT ?2",
            )
            .map_err(CoreError::from)?;
        let rows = statement
            .query_map(params![word, limit.min(50)], |row| {
                Ok(DictionaryEntryDraft {
                    id: row.get(0)?,
                    word: row.get(1)?,
                    ipa: row.get(2)?,
                    part_of_speech: row.get(3)?,
                    meanings: serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or_default(),
                    example: row.get(5)?,
                    example_translation: row.get(6)?,
                    source: row.get(7)?,
                })
            })
            .map_err(CoreError::from)?;
        rows.map(|row| DictionaryEntry::new(row.map_err(CoreError::from)?))
            .collect()
    }

    /// Adds or removes one favorite word.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an invalid word or
    /// [`CoreError::Storage`] when SQLite cannot be updated.
    pub fn set_favorite_word(&self, word: &str, favorite: bool) -> Result<(), CoreError> {
        let word = word.trim().to_lowercase();
        if word.is_empty() || word.len() > 160 {
            return Err(CoreError::InvalidInput("favorite word is invalid"));
        }
        if favorite {
            self.connection.execute("INSERT OR IGNORE INTO favorite_words (word, created_at) VALUES (?1, datetime('now'))", [word]).map_err(CoreError::from)?;
        } else {
            self.connection
                .execute("DELETE FROM favorite_words WHERE word = ?1", [word])
                .map_err(CoreError::from)?;
        }
        Ok(())
    }

    /// Adds a favorite word with a caller-provided local timestamp.
    ///
    /// The timestamp is used by date-scoped homepage statistics. The legacy
    /// [`Self::set_favorite_word`] method remains available for callers that
    /// do not need deterministic event time.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an invalid word or timestamp,
    /// and [`CoreError::Storage`] when SQLite cannot be updated.
    pub fn set_favorite_word_at(
        &self,
        word: &str,
        favorite: bool,
        created_at: &str,
    ) -> Result<(), CoreError> {
        let word = word.trim().to_lowercase();
        let created_at = created_at.trim();
        if word.is_empty() || word.len() > 160 {
            return Err(CoreError::InvalidInput("favorite word is invalid"));
        }
        if created_at.len() < 10
            || created_at.as_bytes().get(4) != Some(&b'-')
            || created_at.as_bytes().get(7) != Some(&b'-')
        {
            return Err(CoreError::InvalidInput(
                "favorite word timestamp is invalid",
            ));
        }
        if favorite {
            self.connection
                .execute(
                    "INSERT OR IGNORE INTO favorite_words (word, created_at) VALUES (?1, ?2)",
                    params![word, created_at],
                )
                .map_err(CoreError::from)?;
        } else {
            self.connection
                .execute("DELETE FROM favorite_words WHERE word = ?1", [word])
                .map_err(CoreError::from)?;
        }
        Ok(())
    }

    /// Lists favorite words, newest first.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite cannot be queried.
    pub fn favorite_words(&self, limit: u32) -> Result<Vec<String>, CoreError> {
        let mut statement = self
            .connection
            .prepare("SELECT word FROM favorite_words ORDER BY created_at DESC, word LIMIT ?1")
            .map_err(CoreError::from)?;
        statement
            .query_map([limit.min(200)], |row| row.get(0))
            .map_err(CoreError::from)?
            .map(|row| row.map_err(CoreError::from))
            .collect()
    }

    /// Loads a searchable page of favorite words with their dictionary and
    /// learning details.
    ///
    /// `limit` is only a per-request response bound. It is not a storage cap;
    /// the caller can request later pages using `offset`.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an oversized search query or
    /// [`CoreError::Storage`] when SQLite or stored JSON cannot be read.
    pub fn favorite_word_page(
        &self,
        query: &str,
        limit: u32,
        offset: u32,
    ) -> Result<FavoriteWordPage, CoreError> {
        let query = query.trim().to_lowercase();
        if query.chars().count() > 160 {
            return Err(CoreError::InvalidInput("favorite word query is invalid"));
        }
        let page_limit = limit.clamp(1, 100);
        let mut statement = self
            .connection
            .prepare(
                "SELECT word, created_at FROM favorite_words WHERE instr(lower(word), lower(?1)) > 0 ORDER BY created_at DESC, word COLLATE NOCASE LIMIT ?2 OFFSET ?3",
            )
            .map_err(CoreError::from)?;
        let favorites: Vec<(String, String)> = statement
            .query_map(params![query, page_limit + 1, offset], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .map_err(CoreError::from)?
            .map(|row| row.map_err(CoreError::from))
            .collect::<Result<_, _>>()?;

        let has_more = favorites.len() > page_limit as usize;
        let records = favorites
            .into_iter()
            .take(page_limit as usize)
            .map(|(word, favorited_at)| {
                Ok(FavoriteWordRecord {
                    dictionary_entries: self.dictionary_entries_exact(&word, 50)?,
                    annotation: self.word_annotation(&word)?,
                    word,
                    favorited_at,
                    // The current dictionary schema is English-Chinese. A
                    // future multilingual migration can replace this field
                    // without changing the page contract.
                    language_pair: "en-zh".to_owned(),
                })
            })
            .collect::<Result<Vec<_>, CoreError>>()?;

        Ok(FavoriteWordPage { records, has_more })
    }

    fn estimated_bytes(&self, query: &str) -> Result<u64, CoreError> {
        let bytes: i64 = self
            .connection
            .query_row(query, [], |row| row.get(0))
            .map_err(CoreError::from)?;
        u64::try_from(bytes)
            .map_err(|_| CoreError::Storage("estimated storage usage is invalid".to_owned()))
    }

    /// Estimates logical UTF-8 bytes owned by each local data category.
    ///
    /// SQLite stores these categories in one database file, so this is a
    /// transparent logical estimate for user-facing quota decisions rather
    /// than an operating-system file-system partition measurement.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when a usage query cannot be evaluated.
    pub fn storage_usage(&self) -> Result<StorageUsageSnapshot, CoreError> {
        let translation_history = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(source_language AS BLOB)) + length(CAST(target_language AS BLOB)) + length(CAST(source_text AS BLOB)) + length(CAST(translated_text AS BLOB)) + length(CAST(provider_id AS BLOB)) + length(CAST(origin AS BLOB)) + COALESCE(length(CAST(source_id AS BLOB)), 0) + COALESCE(length(CAST(screenshot_ocr_layout AS BLOB)), 0) + COALESCE(length(CAST(translated_source_block_indices AS BLOB)), 0) + COALESCE(length(CAST(summary_text AS BLOB)), 0) + COALESCE(length(CAST(summary_source_hash AS BLOB)), 0) + length(CAST(created_at AS BLOB))), 0) FROM translation_history",
        )? + self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(translation_id AS BLOB)) + length(CAST(note AS BLOB)) + 2 + length(CAST(updated_at AS BLOB))), 0) FROM translation_annotations",
        )?;
        let favorite_words = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(word AS BLOB)) + length(CAST(created_at AS BLOB))), 0) FROM favorite_words",
        )? + self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(word AS BLOB)) + length(CAST(note AS BLOB)) + 2 + length(CAST(updated_at AS BLOB))), 0) FROM word_annotations",
        )?;
        let dictionary = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(word AS BLOB)) + length(CAST(ipa AS BLOB)) + length(CAST(part_of_speech AS BLOB)) + length(CAST(meanings_json AS BLOB)) + length(CAST(example AS BLOB)) + length(CAST(example_translation AS BLOB)) + length(CAST(source AS BLOB)) + length(CAST(created_at AS BLOB)) + length(CAST(updated_at AS BLOB))), 0) FROM dictionary_entries",
        )?;
        let learning_records = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(kind AS BLOB)) + length(CAST(prompt AS BLOB)) + COALESCE(length(CAST(expected_answer AS BLOB)), 0) + COALESCE(length(CAST(source_id AS BLOB)), 0) + length(CAST(created_at AS BLOB))), 0) FROM learning_items",
        )? + self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(learning_item_id AS BLOB)) + length(CAST(answer AS BLOB)) + length(CAST(judgement AS BLOB)) + COALESCE(length(CAST(feedback AS BLOB)), 0) + length(CAST(created_at AS BLOB))), 0) FROM study_attempts",
        )?;
        let reading_documents = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(kind AS BLOB)) + length(CAST(title AS BLOB)) + COALESCE(length(CAST(local_path AS BLOB)), 0) + length(CAST(created_at AS BLOB)) + length(CAST(content_text AS BLOB)) + length(CAST(reading_position AS BLOB)) + length(CAST(translated_paragraphs_json AS BLOB)) + length(CAST(updated_at AS BLOB))), 0) FROM content_sources",
        )?;
        let activity = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(kind AS BLOB)) + length(CAST(title AS BLOB)) + COALESCE(length(CAST(detail AS BLOB)), 0) + COALESCE(length(CAST(source_id AS BLOB)), 0) + length(CAST(duration_seconds AS BLOB)) + length(CAST(item_count AS BLOB)) + length(CAST(occurred_at AS BLOB))), 0) FROM activity_events",
        )?;
        let model_catalog = self.estimated_bytes(
            "SELECT COALESCE(SUM(length(CAST(id AS BLOB)) + length(CAST(path AS BLOB)) + length(CAST(display_name AS BLOB)) + length(CAST(family AS BLOB)) + length(CAST(readiness AS BLOB)) + length(CAST(capabilities_json AS BLOB)) + length(CAST(assigned_roles_json AS BLOB)) + COALESCE(length(CAST(source_language AS BLOB)), 0) + COALESCE(length(CAST(target_language AS BLOB)), 0) + length(CAST(discovered_at AS BLOB)) + length(CAST(updated_at AS BLOB))), 0) FROM model_catalog",
        )?;

        Ok(StorageUsageSnapshot {
            records: vec![
                StorageUsageRecord {
                    category: "translation_history".to_owned(),
                    used_bytes: translation_history,
                },
                StorageUsageRecord {
                    category: "favorite_words".to_owned(),
                    used_bytes: favorite_words,
                },
                StorageUsageRecord {
                    category: "dictionary".to_owned(),
                    used_bytes: dictionary,
                },
                StorageUsageRecord {
                    category: "learning_records".to_owned(),
                    used_bytes: learning_records,
                },
                StorageUsageRecord {
                    category: "reading_documents".to_owned(),
                    used_bytes: reading_documents,
                },
                StorageUsageRecord {
                    category: "activity".to_owned(),
                    used_bytes: activity,
                },
                StorageUsageRecord {
                    category: "model_catalog".to_owned(),
                    used_bytes: model_catalog,
                },
            ],
        })
    }

    /// Saves or updates one local article snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite rejects the write.
    pub fn save_content_source(&self, source: &ContentSource) -> Result<(), CoreError> {
        self.connection
            .execute(
                r"INSERT INTO content_sources (
                id, kind, title, local_path, created_at, content_text,
                reading_position, translated_paragraphs_json, is_favorite,
                deleted_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, datetime('now'))
            ON CONFLICT(id) DO UPDATE SET
                kind=excluded.kind, title=excluded.title, local_path=excluded.local_path,
                content_text=excluded.content_text, reading_position=excluded.reading_position,
                translated_paragraphs_json=excluded.translated_paragraphs_json,
                is_favorite=excluded.is_favorite, deleted_at=excluded.deleted_at,
                updated_at=datetime('now')",
                params![
                    source.id(),
                    source.kind(),
                    source.title(),
                    source.local_path(),
                    source.created_at(),
                    source.content_text(),
                    source.reading_position(),
                    source.translated_paragraphs_json(),
                    source.is_favorite(),
                    source.deleted_at(),
                ],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Lists the most recently updated local article snapshots.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite data or stored JSON is invalid.
    pub fn content_sources(&self, limit: u32) -> Result<Vec<ContentSource>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, kind, title, local_path, content_text, reading_position,
                    translated_paragraphs_json, created_at, is_favorite, deleted_at
             FROM content_sources ORDER BY updated_at DESC, id LIMIT ?1",
            )
            .map_err(CoreError::from)?;
        statement
            .query_map([limit.min(500)], |row| {
                Ok((
                    crate::ContentSourceDraft {
                        id: row.get(0)?,
                        kind: row.get(1)?,
                        title: row.get(2)?,
                        local_path: row.get(3)?,
                        content_text: row.get(4)?,
                        reading_position: row.get(5)?,
                        translated_paragraphs_json: row.get(6)?,
                        created_at: row.get(7)?,
                        is_favorite: row.get(8)?,
                        deleted_at: row.get(9)?,
                    },
                    row.get::<_, bool>(8)?,
                    row.get::<_, Option<String>>(9)?,
                ))
            })
            .map_err(CoreError::from)?
            .map(|row| {
                let (draft, is_favorite, deleted_at) = row.map_err(CoreError::from)?;
                Ok(ContentSource::from_draft(draft)?.with_library_state(is_favorite, deleted_at))
            })
            .collect()
    }

    /// Updates the document-center favorite flag without touching document content.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the project does not exist.
    pub fn set_content_source_favorite(
        &self,
        source_id: &str,
        favorite: bool,
    ) -> Result<(), CoreError> {
        let changed = self
            .connection
            .execute(
                "UPDATE content_sources
                 SET is_favorite = ?2, updated_at = datetime('now')
                 WHERE id = ?1",
                params![source_id.trim(), favorite],
            )
            .map_err(CoreError::from)?;
        if changed == 0 {
            return Err(CoreError::InvalidInput("content source not found"));
        }
        Ok(())
    }

    /// Moves a document-center project to the recoverable trash state.
    ///
    /// The original file on disk is never removed by this operation.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the project does not exist.
    pub fn trash_content_source(&self, source_id: &str) -> Result<(), CoreError> {
        let changed = self
            .connection
            .execute(
                "UPDATE content_sources
                 SET deleted_at = datetime('now'), updated_at = datetime('now')
                 WHERE id = ?1",
                [source_id.trim()],
            )
            .map_err(CoreError::from)?;
        if changed == 0 {
            return Err(CoreError::InvalidInput("content source not found"));
        }
        Ok(())
    }

    /// Restores a document-center project from the recoverable trash state.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the project does not exist.
    pub fn restore_content_source(&self, source_id: &str) -> Result<(), CoreError> {
        let changed = self
            .connection
            .execute(
                "UPDATE content_sources
                 SET deleted_at = NULL, updated_at = datetime('now')
                 WHERE id = ?1",
                [source_id.trim()],
            )
            .map_err(CoreError::from)?;
        if changed == 0 {
            return Err(CoreError::InvalidInput("content source not found"));
        }
        Ok(())
    }

    /// Permanently removes only the local project record and its version history.
    ///
    /// The source file selected by the user is never deleted.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the project does not exist.
    pub fn delete_content_source(&self, source_id: &str) -> Result<(), CoreError> {
        let changed = self
            .connection
            .execute(
                "DELETE FROM content_sources WHERE id = ?1",
                [source_id.trim()],
            )
            .map_err(CoreError::from)?;
        if changed == 0 {
            return Err(CoreError::InvalidInput("content source not found"));
        }
        Ok(())
    }

    /// Appends one manually saved version for a local article project.
    ///
    /// The current project row is intentionally not changed here. Automatic
    /// progress saves therefore remain cheap and do not create unbounded
    /// history records.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite rejects the snapshot.
    pub fn save_content_source_version(
        &self,
        source: &ContentSource,
    ) -> Result<ContentSourceVersion, CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        let version: u32 = transaction
            .query_row(
                "SELECT COALESCE(MAX(version), 0) + 1 FROM content_source_versions WHERE source_id = ?1",
                params![source.id()],
                |row| row.get(0),
            )
            .map_err(CoreError::from)?;
        let id = format!("{}:v{}", source.id(), version);
        transaction
            .execute(
                r"INSERT INTO content_source_versions (
                    id, source_id, version, kind, title, local_path, content_text,
                    reading_position, translated_paragraphs_json, created_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    id,
                    source.id(),
                    version,
                    source.kind(),
                    source.title(),
                    source.local_path(),
                    source.content_text(),
                    source.reading_position(),
                    source.translated_paragraphs_json(),
                    source.created_at(),
                ],
            )
            .map_err(CoreError::from)?;
        let snapshot = ContentSourceVersion::from_source(source, id, version);
        transaction.commit().map_err(CoreError::from)?;
        Ok(snapshot)
    }

    /// Lists manually saved versions newest first for one article project.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite data or stored JSON is invalid.
    pub fn content_source_versions(
        &self,
        source_id: &str,
        limit: u32,
    ) -> Result<Vec<ContentSourceVersion>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, source_id, version, kind, title, local_path, content_text,
                    reading_position, translated_paragraphs_json, created_at
                 FROM content_source_versions
                 WHERE source_id = ?1
                 ORDER BY version DESC, id DESC
                 LIMIT ?2",
            )
            .map_err(CoreError::from)?;
        statement
            .query_map(params![source_id.trim(), limit.min(500)], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u32>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, u32>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, String>(9)?,
                ))
            })
            .map_err(CoreError::from)?
            .map(|row| {
                let (
                    id,
                    source_id,
                    version,
                    kind,
                    title,
                    local_path,
                    content_text,
                    reading_position,
                    translated_paragraphs_json,
                    created_at,
                ) = row.map_err(CoreError::from)?;
                let source = ContentSource::from_draft(crate::ContentSourceDraft {
                    id: source_id,
                    kind,
                    title,
                    local_path,
                    content_text,
                    reading_position,
                    translated_paragraphs_json,
                    created_at,
                    is_favorite: false,
                    deleted_at: None,
                })?;
                Ok(ContentSourceVersion::from_source(&source, id, version))
            })
            .collect()
    }

    /// Restores one manually saved version into the current article project.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the version does not exist.
    pub fn restore_content_source_version(
        &self,
        source_id: &str,
        version_id: &str,
    ) -> Result<ContentSource, CoreError> {
        let draft = self
            .connection
            .query_row(
                "SELECT source_id, kind, title, local_path, content_text, reading_position,
                    translated_paragraphs_json, created_at
                 FROM content_source_versions
                 WHERE source_id = ?1 AND id = ?2",
                params![source_id.trim(), version_id.trim()],
                |row| {
                    Ok(crate::ContentSourceDraft {
                        id: row.get(0)?,
                        kind: row.get(1)?,
                        title: row.get(2)?,
                        local_path: row.get(3)?,
                        content_text: row.get(4)?,
                        reading_position: row.get(5)?,
                        translated_paragraphs_json: row.get(6)?,
                        created_at: row.get(7)?,
                        is_favorite: false,
                        deleted_at: None,
                    })
                },
            )
            .optional()
            .map_err(CoreError::from)?
            .ok_or(CoreError::InvalidInput("content source version not found"))?;
        let library_state = self
            .connection
            .query_row(
                "SELECT is_favorite, deleted_at FROM content_sources WHERE id = ?1",
                [source_id.trim()],
                |row| Ok((row.get::<_, bool>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()
            .map_err(CoreError::from)?
            .unwrap_or((false, None));
        let source =
            ContentSource::from_draft(draft)?.with_library_state(library_state.0, library_state.1);
        self.save_content_source(&source)?;
        Ok(source)
    }

    /// Inserts or updates one locally discovered model and its assigned role.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when serialization or SQLite fails.
    pub fn save_model_catalog_entry(&self, model: &ModelCatalogEntry) -> Result<(), CoreError> {
        let capabilities = serde_json::to_string(model.capabilities())
            .map_err(|error| CoreError::Storage(error.to_string()))?;
        let roles = serde_json::to_string(model.assigned_roles())
            .map_err(|error| CoreError::Storage(error.to_string()))?;
        self.connection
            .execute(
                r"INSERT INTO model_catalog (
                id, path, display_name, family, readiness, capabilities_json,
                assigned_roles_json, source_language, target_language,
                discovered_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, datetime('now'), datetime('now'))
            ON CONFLICT(id) DO UPDATE SET
                path=excluded.path, display_name=excluded.display_name,
                family=excluded.family, readiness=excluded.readiness,
                capabilities_json=excluded.capabilities_json,
                assigned_roles_json=excluded.assigned_roles_json,
                source_language=excluded.source_language,
                target_language=excluded.target_language,
                updated_at=datetime('now')",
                params![
                    model.id(),
                    model.path(),
                    model.display_name(),
                    model.family(),
                    model.readiness(),
                    capabilities,
                    roles,
                    model.source_language(),
                    model.target_language(),
                ],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Removes a discovered-model index entry without touching its files.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite cannot be updated.
    pub fn delete_model_catalog_entry(&self, model_id: &str) -> Result<(), CoreError> {
        self.connection
            .execute("DELETE FROM model_catalog WHERE id = ?1", params![model_id])
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Lists remembered local models without loading or executing them.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite or stored JSON is invalid.
    pub fn model_catalog_entries(&self) -> Result<Vec<ModelCatalogEntry>, CoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, path, display_name, family, readiness, capabilities_json, assigned_roles_json, source_language, target_language FROM model_catalog ORDER BY display_name COLLATE NOCASE, id"
        ).map_err(CoreError::from)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                ))
            })
            .map_err(CoreError::from)?;
        rows.map(|row| {
            let (
                id,
                path,
                display_name,
                family,
                readiness,
                capabilities,
                assigned_roles,
                source_language,
                target_language,
            ) = row.map_err(CoreError::from)?;
            ModelCatalogEntry::new(ModelCatalogEntryDraft {
                id,
                path,
                display_name,
                family,
                readiness,
                capabilities: serde_json::from_str(&capabilities)
                    .map_err(|error| CoreError::Storage(error.to_string()))?,
                assigned_roles: serde_json::from_str(&assigned_roles)
                    .map_err(|error| CoreError::Storage(error.to_string()))?,
                source_language,
                target_language,
            })
        })
        .collect()
    }

    fn migrate_version_two(&self) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        transaction
            .execute_batch(MIGRATE_V2_TO_V3)
            .map_err(CoreError::from)?;
        transaction
            .pragma_update(None, "user_version", 3)
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    /// Deletes one user-data category while leaving provider and model settings intact.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an unknown category or
    /// [`CoreError::Storage`] when the transaction cannot be committed.
    pub fn clear_user_data(&self, category: &str) -> Result<(), CoreError> {
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        match category {
            "translation_history" => {
                transaction
                    .execute("DELETE FROM translation_annotations", [])
                    .map_err(CoreError::from)?;
                transaction
                    .execute("DELETE FROM translation_history", [])
                    .map_err(CoreError::from)?;
            }
            "reading_documents" => {
                transaction
                    .execute("DELETE FROM content_sources", [])
                    .map_err(CoreError::from)?;
            }
            "learning_records" => {
                transaction
                    .execute("DELETE FROM study_attempts", [])
                    .map_err(CoreError::from)?;
                transaction
                    .execute("DELETE FROM learning_items", [])
                    .map_err(CoreError::from)?;
            }
            "dictionary" => {
                transaction
                    .execute("DELETE FROM word_annotations", [])
                    .map_err(CoreError::from)?;
                transaction
                    .execute("DELETE FROM favorite_words", [])
                    .map_err(CoreError::from)?;
                transaction
                    .execute("DELETE FROM dictionary_entries", [])
                    .map_err(CoreError::from)?;
            }
            "activity" => {
                transaction
                    .execute("DELETE FROM activity_events", [])
                    .map_err(CoreError::from)?;
            }
            _ => return Err(CoreError::InvalidInput("unknown user-data category")),
        }
        transaction.commit().map_err(CoreError::from)
    }

    /// Deletes a bounded, explicitly selected set of translation records.
    ///
    /// Matching annotations are removed by the foreign-key cascade and the
    /// corresponding homepage activity rows are removed in the same
    /// transaction. An empty selection is a no-op; the caller cannot use this
    /// method to turn a single-item action into an unbounded table clear.
    pub fn delete_translation_history(&self, ids: &[String]) -> Result<(), CoreError> {
        if ids.len() > 500 {
            return Err(CoreError::InvalidInput("too many translation history ids"));
        }
        if ids.iter().any(|id| id.trim().is_empty() || id.len() > 300) {
            return Err(CoreError::InvalidInput("translation history id is invalid"));
        }
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        for id in ids {
            transaction
                .execute("DELETE FROM translation_history WHERE id = ?1", [id])
                .map_err(CoreError::from)?;
            transaction
                .execute(
                    "DELETE FROM activity_events WHERE id = ?1",
                    [format!("translation:{id}")],
                )
                .map_err(CoreError::from)?;
        }
        transaction.commit().map_err(CoreError::from)
    }

    /// Saves a generated summary only when the exact screenshot history row
    /// and OCR source text are still present.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for invalid values or when the
    /// selected screenshot row has already been removed or changed.
    pub fn save_screenshot_translation_summary(
        &self,
        id: &str,
        source_text: &str,
        summary_text: &str,
    ) -> Result<(), CoreError> {
        let id = id.trim();
        let summary_text = summary_text.trim();
        if id.is_empty() || id.len() > 80 {
            return Err(CoreError::InvalidInput("screenshot history id is invalid"));
        }
        if source_text.trim().is_empty() || source_text.chars().count() > 5_000 {
            return Err(CoreError::InvalidInput(
                "screenshot history source is invalid",
            ));
        }
        if summary_text.is_empty() || summary_text.chars().count() > 20_000 {
            return Err(CoreError::InvalidInput(
                "screenshot history summary is invalid",
            ));
        }
        let summary_source_hash = sha256_hex(source_text.as_bytes());
        let changed = self
            .connection
            .execute(
                "UPDATE translation_history SET summary_text = ?1, summary_source_hash = ?2 WHERE id = ?3 AND source_text = ?4 AND origin = 'screenshot_translation'",
                params![summary_text, summary_source_hash, id, source_text],
            )
            .map_err(CoreError::from)?;
        if changed == 0 {
            return Err(CoreError::InvalidInput(
                "screenshot history row is no longer available",
            ));
        }
        Ok(())
    }

    /// Checks whether the exact screenshot translation row is still persisted.
    ///
    /// The primary-key lookup on `id` is constrained by both screenshot origin
    /// and exact source text, so another translation with a matching ID or text
    /// cannot authorize screenshot archive operations.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for blank or oversized values and
    /// [`CoreError::Storage`] when SQLite cannot perform the lookup.
    pub fn screenshot_translation_history_matches(
        &self,
        id: &str,
        source_text: &str,
    ) -> Result<bool, CoreError> {
        if id.trim().is_empty() || id.len() > 80 {
            return Err(CoreError::InvalidInput(
                "screenshot translation history id is invalid",
            ));
        }
        if source_text.trim().is_empty() || source_text.chars().count() > 5_000 {
            return Err(CoreError::InvalidInput(
                "screenshot translation history source is invalid",
            ));
        }

        self.connection
            .query_row(
                r"
                SELECT EXISTS(
                    SELECT 1
                    FROM translation_history
                    WHERE id = ?1
                      AND origin = 'screenshot_translation'
                      AND source_text = ?2
                )
                ",
                params![id, source_text],
                |row| row.get(0),
            )
            .map_err(CoreError::from)
    }

    /// Returns screenshot image identifiers that become unreferenced if the
    /// supplied history rows are deleted. Legacy rows without an explicit
    /// capture identifier are treated as owning an image named after their
    /// history ID. The caller must finish the corresponding image deletions
    /// before deleting the selected history rows.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an oversized or malformed
    /// selection and [`CoreError::Storage`] when SQLite fails.
    pub fn screenshot_capture_ids_orphaned_by_history_deletion(
        &self,
        ids: &[String],
    ) -> Result<Vec<String>, CoreError> {
        if ids.len() > 500 {
            return Err(CoreError::InvalidInput("too many translation history ids"));
        }
        if ids.iter().any(|id| id.trim().is_empty() || id.len() > 300) {
            return Err(CoreError::InvalidInput("translation history id is invalid"));
        }
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = (1..=ids.len())
            .map(|index| format!("(?{index})"))
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "WITH selected_ids(id) AS (VALUES {placeholders})
             SELECT DISTINCT COALESCE(selected.screenshot_capture_id, selected.id)
             FROM translation_history AS selected
             WHERE selected.origin = 'screenshot_translation'
               AND selected.id IN (SELECT id FROM selected_ids)
               AND NOT EXISTS (
                   SELECT 1
                   FROM translation_history AS remaining
                   WHERE remaining.origin = 'screenshot_translation'
                     AND COALESCE(remaining.screenshot_capture_id, remaining.id)
                         = COALESCE(selected.screenshot_capture_id, selected.id)
                     AND remaining.id NOT IN (SELECT id FROM selected_ids)
               )"
        );
        let values = ids.iter().map(String::as_str).collect::<Vec<_>>();
        let mut statement = self.connection.prepare(&sql).map_err(CoreError::from)?;
        statement
            .query_map(params_from_iter(values), |row| row.get(0))
            .map_err(CoreError::from)?
            .map(|row| row.map_err(CoreError::from))
            .collect()
    }

    /// Returns the supplied capture IDs that are still referenced by
    /// screenshot translation history. Legacy rows without an explicit
    /// capture ID use their history ID as the image identifier.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an oversized or malformed
    /// selection and [`CoreError::Storage`] when SQLite fails.
    pub fn screenshot_capture_ids_still_referenced(
        &self,
        capture_ids: &[String],
    ) -> Result<Vec<String>, CoreError> {
        if capture_ids.len() > 500 {
            return Err(CoreError::InvalidInput("too many screenshot capture ids"));
        }
        if capture_ids
            .iter()
            .any(|id| id.trim().is_empty() || id.len() > 300)
        {
            return Err(CoreError::InvalidInput("screenshot capture id is invalid"));
        }
        if capture_ids.is_empty() {
            return Ok(Vec::new());
        }

        let placeholders = (1..=capture_ids.len())
            .map(|index| format!("(?{index})"))
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "WITH requested_ids(id) AS (VALUES {placeholders})
             SELECT DISTINCT requested.id
             FROM requested_ids AS requested
             WHERE EXISTS (
                 SELECT 1
                 FROM translation_history AS history
                 WHERE history.origin = 'screenshot_translation'
                   AND COALESCE(history.screenshot_capture_id, history.id)
                       = requested.id
             )
             ORDER BY requested.id"
        );
        let values = capture_ids.iter().map(String::as_str).collect::<Vec<_>>();
        let mut statement = self.connection.prepare(&sql).map_err(CoreError::from)?;
        statement
            .query_map(params_from_iter(values), |row| row.get(0))
            .map_err(CoreError::from)?
            .map(|row| row.map_err(CoreError::from))
            .collect()
    }

    /// Persists one idempotent local activity event.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite rejects the write.
    pub fn record_activity(&self, activity: &ActivityEvent) -> Result<(), CoreError> {
        self.connection
            .execute(
                r"
                INSERT OR IGNORE INTO activity_events (
                    id, kind, title, detail, source_id, duration_seconds, item_count, occurred_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ",
                params![
                    activity.id(),
                    activity.kind().as_storage_value(),
                    activity.title(),
                    activity.detail(),
                    activity.source_id(),
                    activity.duration_seconds(),
                    activity.item_count(),
                    activity.occurred_at(),
                ],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Persists history and its matching home activity in one transaction.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite rejects either write.
    pub fn save_completed_translation(
        &self,
        translation: &CompletedTranslation,
    ) -> Result<(), CoreError> {
        let origin_label = match translation.origin() {
            TranslationOrigin::QuickTranslation => "快速翻译",
            TranslationOrigin::ScreenshotTranslation => "截屏翻译",
        };
        let activity_detail = match (translation.source_language(), translation.target_language()) {
            (Language::English, Language::Chinese) => format!("{origin_label} · 英译中"),
            (Language::Chinese, Language::English) => format!("{origin_label} · 中译英"),
            _ => origin_label.to_owned(),
        };
        let screenshot_ocr_layout = translation
            .screenshot_ocr_layout()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| CoreError::Storage(error.to_string()))?;
        let translated_source_block_indices = translation
            .translated_source_block_indices()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| CoreError::Storage(error.to_string()))?;
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(CoreError::from)?;
        // Screenshot versions have independent history IDs and carry a stable
        // capture ID. Repeated IDs remain idempotent for retried writes.
        transaction
            .execute(
                r"
                INSERT INTO translation_history (
                    id, source_language, target_language, source_text,
                    translated_text, provider_id, created_at, origin,
                    screenshot_capture_id, screenshot_ocr_layout,
                    translated_source_block_indices
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                ON CONFLICT(id) DO UPDATE SET
                    source_language = excluded.source_language,
                    target_language = excluded.target_language,
                    source_text = excluded.source_text,
                    translated_text = excluded.translated_text,
                    provider_id = excluded.provider_id,
                    created_at = excluded.created_at,
                    screenshot_capture_id = excluded.screenshot_capture_id,
                    screenshot_ocr_layout = excluded.screenshot_ocr_layout,
                    translated_source_block_indices = excluded.translated_source_block_indices,
                    summary_text = CASE
                        WHEN translation_history.source_text <> excluded.source_text THEN NULL
                        ELSE translation_history.summary_text
                    END,
                    summary_source_hash = CASE
                        WHEN translation_history.source_text <> excluded.source_text THEN NULL
                        ELSE translation_history.summary_source_hash
                    END
                WHERE translation_history.origin = 'screenshot_translation'
                  AND excluded.origin = 'screenshot_translation'
                ",
                params![
                    translation.id(),
                    translation.source_language().as_storage_value(),
                    translation.target_language().as_storage_value(),
                    translation.source_text(),
                    translation.translated_text(),
                    translation.provider_id(),
                    translation.created_at(),
                    translation.origin().as_storage_value(),
                    translation.screenshot_capture_id(),
                    screenshot_ocr_layout,
                    translated_source_block_indices,
                ],
            )
            .map_err(CoreError::from)?;
        let title = translation
            .source_text()
            .chars()
            .take(80)
            .collect::<String>();
        // Insert the activity only when the persisted history row still has
        // this origin; otherwise an ID collision could create an orphan event.
        transaction
            .execute(
                r"
                INSERT INTO activity_events (
                    id, kind, title, detail, duration_seconds, item_count, occurred_at
                )
                SELECT ?1, 'translation', ?2, ?4, 0, 1, ?3
                WHERE EXISTS (
                    SELECT 1 FROM translation_history
                    WHERE translation_history.id = ?5
                      AND translation_history.origin = ?6
                )
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    detail = excluded.detail,
                    occurred_at = excluded.occurred_at
                WHERE activity_events.kind = 'translation'
                  AND ?6 = 'screenshot_translation'
                ",
                params![
                    format!("translation:{}", translation.id()),
                    title,
                    translation.created_at(),
                    activity_detail,
                    translation.id(),
                    translation.origin().as_storage_value(),
                ],
            )
            .map_err(CoreError::from)?;
        transaction.commit().map_err(CoreError::from)
    }

    /// Returns the newest local translation records.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite fails or stored data is invalid.
    pub fn recent_translations(&self, limit: u32) -> Result<Vec<CompletedTranslation>, CoreError> {
        self.recent_translations_page(limit, 0)
    }

    /// Returns one bounded page of the newest local translation records.
    ///
    /// The offset is capped so a malformed UI request cannot turn into an
    /// unbounded SQLite scan. Records remain newest-first and use the same
    /// tie-breaker as [`Self::recent_translations`].
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite fails or stored data is invalid.
    pub fn recent_translations_page(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<CompletedTranslation>, CoreError> {
        self.recent_translations_page_filtered(limit, offset, None, "")
    }

    /// Returns one bounded page of local translation records matching the
    /// optional origin and a literal substring in either text field.
    ///
    /// `%`, `_`, and `\\` in the query are treated as literal characters.
    /// Empty or whitespace-only queries do not filter the page.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite fails or stored data is invalid.
    pub fn recent_translations_page_filtered(
        &self,
        limit: u32,
        offset: u32,
        origin: Option<TranslationOrigin>,
        query: &str,
    ) -> Result<Vec<CompletedTranslation>, CoreError> {
        let trimmed_query = query.trim();
        let query_pattern = if trimmed_query.is_empty() {
            None
        } else {
            let escaped_query = trimmed_query
                .replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_");
            Some(format!("%{escaped_query}%"))
        };
        let origin_filter = origin.map(TranslationOrigin::as_storage_value);
        let mut statement = self
            .connection
            .prepare(
                r"
                SELECT id, source_language, target_language, source_text,
                       translated_text, provider_id, created_at, origin,
                       screenshot_capture_id, screenshot_ocr_layout,
                       translated_source_block_indices, summary_text,
                       summary_source_hash
                FROM translation_history
                WHERE (?1 IS NULL OR origin = ?1)
                  AND (
                      ?2 IS NULL
                      OR source_text LIKE ?2 ESCAPE '\'
                      OR translated_text LIKE ?2 ESCAPE '\'
                  )
                ORDER BY created_at DESC, id
                LIMIT ?3
                OFFSET ?4
                ",
            )
            .map_err(CoreError::from)?;
        statement
            .query_map(
                params![
                    origin_filter,
                    query_pattern.as_deref(),
                    limit.min(500),
                    offset.min(5000)
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, Option<String>>(8)?,
                        row.get::<_, Option<String>>(9)?,
                        row.get::<_, Option<String>>(10)?,
                        row.get::<_, Option<String>>(11)?,
                        row.get::<_, Option<String>>(12)?,
                    ))
                },
            )
            .map_err(CoreError::from)?
            .map(|row| {
                let (
                    id,
                    source_language,
                    target_language,
                    source_text,
                    translated_text,
                    provider_id,
                    created_at,
                    origin,
                    screenshot_capture_id,
                    screenshot_ocr_layout,
                    translated_source_block_indices,
                    summary_text,
                    summary_source_hash,
                ) = row.map_err(CoreError::from)?;
                let expected_summary_source_hash = sha256_hex(source_text.as_bytes());
                let summary_text = (summary_source_hash.as_deref()
                    == Some(expected_summary_source_hash.as_str()))
                .then_some(summary_text)
                .flatten();
                let screenshot_ocr_layout =
                    screenshot_ocr_layout.and_then(|json| serde_json::from_str(&json).ok());
                let translated_source_block_indices = translated_source_block_indices
                    .and_then(|json| serde_json::from_str(&json).ok());
                CompletedTranslation::from_stored_draft(CompletedTranslationDraft {
                    id,
                    origin: TranslationOrigin::from_storage_value(&origin)?,
                    screenshot_capture_id,
                    screenshot_ocr_layout,
                    translated_source_block_indices,
                    source_language: Language::from_storage_value(&source_language)?,
                    target_language: Language::from_storage_value(&target_language)?,
                    source_text,
                    translated_text,
                    provider_id,
                    created_at,
                })
                .map(|translation| translation.with_summary_text(summary_text))
            })
            .collect()
    }

    /// Saves or updates one annotation attached to a completed translation.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when the translation does not exist or
    /// SQLite cannot persist the annotation.
    pub fn save_translation_annotation(
        &self,
        annotation: &TranslationAnnotation,
    ) -> Result<(), CoreError> {
        self.connection
            .execute(
                r"
                INSERT INTO translation_annotations (
                    translation_id, note, favorite, added_to_learning, updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5)
                ON CONFLICT(translation_id) DO UPDATE SET
                    note=excluded.note,
                    favorite=excluded.favorite,
                    added_to_learning=excluded.added_to_learning,
                    updated_at=excluded.updated_at
                ",
                params![
                    annotation.translation_id(),
                    annotation.note(),
                    i64::from(annotation.favorite()),
                    i64::from(annotation.added_to_learning()),
                    annotation.updated_at(),
                ],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Saves or updates one note attached to a dictionary word.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite cannot persist the note.
    pub fn save_word_annotation(&self, annotation: &WordAnnotation) -> Result<(), CoreError> {
        self.connection
            .execute(
                r"
                INSERT INTO word_annotations (word, note, added_to_learning, updated_at)
                VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(word) DO UPDATE SET
                    note=excluded.note,
                    added_to_learning=excluded.added_to_learning,
                    updated_at=excluded.updated_at
                ",
                params![
                    annotation.word(),
                    annotation.note(),
                    i64::from(annotation.added_to_learning()),
                    annotation.updated_at(),
                ],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Finds one exact word note, if it exists.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite data is invalid or cannot be queried.
    pub fn word_annotation(&self, word: &str) -> Result<Option<WordAnnotation>, CoreError> {
        let word = word.trim().to_lowercase();
        if word.is_empty() || word.chars().count() > 160 {
            return Err(CoreError::InvalidInput("word annotation word is invalid"));
        }
        self.connection
            .query_row(
                r"
                SELECT word, note, added_to_learning, updated_at
                FROM word_annotations WHERE word = ?1
                ",
                [word],
                |row| {
                    Ok(WordAnnotationDraft {
                        word: row.get(0)?,
                        note: row.get(1)?,
                        added_to_learning: row.get::<_, i64>(2)? != 0,
                        updated_at: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(CoreError::from)?
            .map(WordAnnotation::new)
            .transpose()
    }

    /// Lists word notes newest first.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite data is invalid or cannot be queried.
    pub fn word_annotations(&self, limit: u32) -> Result<Vec<WordAnnotation>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                r"
                SELECT word, note, added_to_learning, updated_at
                FROM word_annotations
                ORDER BY updated_at DESC, word
                LIMIT ?1
                ",
            )
            .map_err(CoreError::from)?;
        statement
            .query_map([limit.min(500)], |row| {
                Ok(WordAnnotationDraft {
                    word: row.get(0)?,
                    note: row.get(1)?,
                    added_to_learning: row.get::<_, i64>(2)? != 0,
                    updated_at: row.get(3)?,
                })
            })
            .map_err(CoreError::from)?
            .map(|row| WordAnnotation::new(row.map_err(CoreError::from)?))
            .collect()
    }

    /// Lists annotations newest first without loading translation contents.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite data is invalid or cannot be queried.
    pub fn translation_annotations(
        &self,
        limit: u32,
    ) -> Result<Vec<TranslationAnnotation>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                r"
                SELECT translation_id, note, favorite, added_to_learning, updated_at
                FROM translation_annotations
                ORDER BY updated_at DESC, translation_id
                LIMIT ?1
                ",
            )
            .map_err(CoreError::from)?;
        statement
            .query_map([limit.min(500)], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, i64>(3)? != 0,
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(CoreError::from)?
            .map(|row| {
                let (translation_id, note, favorite, added_to_learning, updated_at) =
                    row.map_err(CoreError::from)?;
                TranslationAnnotation::new(TranslationAnnotationDraft {
                    translation_id,
                    note,
                    favorite,
                    added_to_learning,
                    updated_at,
                })
            })
            .collect()
    }

    /// Aggregates today's metrics and returns the newest local activities.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when the date is invalid, SQLite fails, or stored
    /// activity data is outside the supported contract.
    pub fn home_snapshot(
        &self,
        local_date: &str,
        recent_limit: u32,
    ) -> Result<HomeSnapshot, CoreError> {
        if local_date.len() != 10
            || local_date.as_bytes().get(4) != Some(&b'-')
            || local_date.as_bytes().get(7) != Some(&b'-')
        {
            return Err(CoreError::InvalidInput("local date is invalid"));
        }
        let totals = self
            .connection
            .query_row(
                r"
                SELECT
                    COALESCE(SUM(duration_seconds), 0),
                    COALESCE(SUM(CASE WHEN kind = 'reading' THEN item_count ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'vocabulary' THEN item_count ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'exercise' THEN item_count ELSE 0 END), 0)
                FROM activity_events
                WHERE substr(occurred_at, 1, 10) = ?1
                ",
                [local_date],
                |row| {
                    Ok((
                        row.get::<_, u32>(0)?,
                        row.get::<_, u32>(1)?,
                        row.get::<_, u32>(2)?,
                        row.get::<_, u32>(3)?,
                    ))
                },
            )
            .map_err(CoreError::from)?;
        let mut statement = self
            .connection
            .prepare(
                r"
                SELECT id, kind, title, detail, source_id, duration_seconds, item_count, occurred_at
                FROM activity_events
                ORDER BY occurred_at DESC, id
                LIMIT ?1
                ",
            )
            .map_err(CoreError::from)?;
        let recent =
            statement
                .query_map([recent_limit], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, u32>(5)?,
                        row.get::<_, u32>(6)?,
                        row.get::<_, String>(7)?,
                    ))
                })
                .map_err(CoreError::from)?
                .map(|row| {
                    let (
                        id,
                        kind,
                        title,
                        detail,
                        source_id,
                        duration_seconds,
                        item_count,
                        occurred_at,
                    ) = row.map_err(CoreError::from)?;
                    ActivityEvent::from_draft(ActivityEventDraft {
                        id,
                        kind: ActivityKind::from_storage_value(&kind)?,
                        title,
                        detail,
                        source_id,
                        duration_seconds,
                        item_count,
                        occurred_at,
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
        Ok(HomeSnapshot::new(
            totals.0 / 60,
            totals.1,
            totals.2,
            totals.3,
            recent,
        ))
    }

    /// Aggregates the versioned homepage workbench metrics for one local date.
    ///
    /// Relation-derived metrics are joined to their local tables here. Any
    /// metric that is genuinely unsupported remains explicitly unavailable
    /// instead of being represented by a misleading zero.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for an invalid local date and
    /// [`CoreError::Storage`] when the SQLite query or stored activity data is
    /// invalid.
    pub fn home_workbench_snapshot(
        &self,
        local_date: &str,
        recent_limit: u32,
    ) -> Result<HomeWorkbenchSnapshot, CoreError> {
        if local_date.len() != 10
            || local_date.as_bytes().get(4) != Some(&b'-')
            || local_date.as_bytes().get(7) != Some(&b'-')
        {
            return Err(CoreError::InvalidInput("local date is invalid"));
        }
        let totals = self.home_workbench_totals(local_date)?;
        let recent = self.home_workbench_activities(local_date, recent_limit)?;
        let summary = HomeWorkbenchSummary::new(
            HomeMetricData::available(totals[0]),
            HomeMetricData::available(totals[1]),
            HomeMetricData::available(totals[2]),
            HomeMetricData::available(totals[7]),
            HomeMetricData::available(totals[3]),
            HomeMetricData::available(totals[8]),
            HomeMetricData::available(totals[9]),
            HomeMetricData::available(totals[4]),
            HomeMetricData::available(totals[5]),
            HomeMetricData::available(totals[6]),
        );
        let details = recent.clone();
        Ok(HomeWorkbenchSnapshot::new(
            local_date, summary, recent, details,
        ))
    }

    fn home_workbench_totals(&self, local_date: &str) -> Result<[u32; 10], CoreError> {
        self.connection
            .query_row(
                r"
                SELECT
                    COALESCE(SUM(CASE WHEN kind = 'translation' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'translation' THEN item_count ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'vocabulary' THEN item_count ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'reading' THEN item_count ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'speaking' THEN duration_seconds ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'focus' THEN duration_seconds ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN kind = 'focus' THEN 1 ELSE 0 END), 0),
                    (SELECT COUNT(DISTINCT activity.source_id)
                     FROM activity_events AS activity
                     INNER JOIN content_sources AS source ON source.id = activity.source_id
                     WHERE activity.kind = 'reading'
                       AND substr(activity.occurred_at, 1, 10) = ?1),
                    (SELECT COUNT(*)
                     FROM translation_annotations AS annotation
                     INNER JOIN translation_history AS translation
                       ON translation.id = annotation.translation_id
                     WHERE annotation.favorite = 1
                       AND substr(annotation.updated_at, 1, 10) = ?1),
                    (SELECT COUNT(*)
                     FROM favorite_words
                     WHERE substr(created_at, 1, 10) = ?1)
                FROM activity_events
                WHERE substr(occurred_at, 1, 10) = ?1
                ",
                [local_date],
                |row| {
                    Ok([
                        row.get::<_, u32>(0)?,
                        row.get::<_, u32>(1)?,
                        row.get::<_, u32>(2)?,
                        row.get::<_, u32>(3)?,
                        row.get::<_, u32>(4)?,
                        row.get::<_, u32>(5)?,
                        row.get::<_, u32>(6)?,
                        row.get::<_, u32>(7)?,
                        row.get::<_, u32>(8)?,
                        row.get::<_, u32>(9)?,
                    ])
                },
            )
            .map_err(CoreError::from)
    }

    fn home_workbench_activities(
        &self,
        local_date: &str,
        recent_limit: u32,
    ) -> Result<Vec<ActivityEvent>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                r"
                SELECT id, kind, title, detail, source_id, duration_seconds, item_count, occurred_at
                FROM activity_events
                WHERE substr(occurred_at, 1, 10) = ?1
                ORDER BY occurred_at DESC, id
                LIMIT ?2
                ",
            )
            .map_err(CoreError::from)?;
        statement
            .query_map(params![local_date, recent_limit], |row| {
                Ok(ActivityEventDraft {
                    id: row.get(0)?,
                    kind: ActivityKind::from_storage_value(&row.get::<_, String>(1)?)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    title: row.get(2)?,
                    detail: row.get(3)?,
                    source_id: row.get(4)?,
                    duration_seconds: row.get(5)?,
                    item_count: row.get(6)?,
                    occurred_at: row.get(7)?,
                })
            })
            .map_err(CoreError::from)?
            .map(|row| {
                let draft = row.map_err(CoreError::from)?;
                ActivityEvent::from_draft(draft)
            })
            .collect()
    }

    /// Inserts or updates non-secret provider metadata.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite rejects the parameterized write.
    pub fn save_provider_profile(&self, profile: &ProviderProfile) -> Result<(), CoreError> {
        let assigned_roles = serde_json::to_string(profile.assigned_roles())
            .map_err(|error| CoreError::Storage(error.to_string()))?;
        self.connection
            .execute(
                r"
                INSERT INTO provider_profiles (
                    id, kind, display_name, enabled, model_id, endpoint, model_path,
                    secret_ref, assigned_roles_json, settings_json, created_at, updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, '{}', datetime('now'), datetime('now'))
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind,
                    display_name = excluded.display_name,
                    enabled = excluded.enabled,
                    model_id = excluded.model_id,
                    endpoint = excluded.endpoint,
                    model_path = excluded.model_path,
                    secret_ref = excluded.secret_ref,
                    assigned_roles_json = excluded.assigned_roles_json,
                    settings_json = '{}',
                    updated_at = datetime('now')
                ",
                params![
                    profile.id(),
                    profile.kind().as_storage_value(),
                    profile.display_name(),
                    profile.enabled(),
                    profile.model_id(),
                    profile.endpoint(),
                    profile.model_path(),
                    profile.secret_ref(),
                    assigned_roles,
                ],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Deletes provider metadata only. Local model files are never touched.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when SQLite cannot be updated.
    pub fn delete_provider_profile(&self, provider_id: &str) -> Result<(), CoreError> {
        self.connection
            .execute(
                "DELETE FROM provider_profiles WHERE id = ?1",
                params![provider_id],
            )
            .map_err(CoreError::from)?;
        Ok(())
    }

    /// Lists validated provider metadata without secret values.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError`] when SQLite fails or stored metadata is invalid.
    pub fn provider_profiles(&self) -> Result<Vec<ProviderProfile>, CoreError> {
        let mut statement = self
            .connection
            .prepare(
                r"
                SELECT id, display_name, kind, enabled, model_id, endpoint, model_path, secret_ref,
                       assigned_roles_json
                FROM provider_profiles
                ORDER BY display_name COLLATE NOCASE, id
                ",
            )
            .map_err(CoreError::from)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, String>(8)?,
                ))
            })
            .map_err(CoreError::from)?;

        rows.map(|row| {
            let (
                id,
                display_name,
                kind,
                enabled,
                model_id,
                endpoint,
                model_path,
                secret_ref,
                assigned_roles,
            ) = row.map_err(CoreError::from)?;
            let assigned_roles = serde_json::from_str(&assigned_roles)
                .map_err(|error| CoreError::Storage(error.to_string()))?;
            ProviderProfile::new(ProviderProfileDraft {
                id,
                display_name,
                kind: ProviderProfileKind::from_storage_value(&kind)?,
                enabled,
                model_id,
                endpoint,
                model_path,
                secret_ref,
                assigned_roles,
            })
        })
        .collect()
    }

    /// Reports schema and foreign-key readiness for diagnostics.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Storage`] when a diagnostic query fails.
    pub fn health(&self) -> Result<StorageHealth, CoreError> {
        let schema_version = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(CoreError::from)?;
        let foreign_keys_enabled = self
            .connection
            .query_row("PRAGMA foreign_keys", [], |row| row.get::<_, i64>(0))
            .map_err(CoreError::from)?
            == 1;
        let mut missing_tables = Vec::new();

        for table in REQUIRED_TABLES {
            let exists = self
                .connection
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
                    [table],
                    |row| row.get::<_, i64>(0),
                )
                .map_err(CoreError::from)?
                == 1;
            if !exists {
                missing_tables.push(table);
            }
        }

        Ok(StorageHealth {
            schema_version,
            foreign_keys_enabled,
            missing_tables,
        })
    }
}

#[derive(Debug, Eq, PartialEq)]
pub struct StorageHealth {
    schema_version: u32,
    foreign_keys_enabled: bool,
    missing_tables: Vec<&'static str>,
}

impl StorageHealth {
    #[must_use]
    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }

    #[must_use]
    pub fn foreign_keys_enabled(&self) -> bool {
        self.foreign_keys_enabled
    }

    #[must_use]
    pub fn missing_tables(&self) -> &[&'static str] {
        &self.missing_tables
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::sha256_hex;

    #[test]
    fn sha256_hex_uses_standard_lowercase_encoding() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
