use yixue_core::{ContentSource, ContentSourceDraft, Storage};

#[test]
fn new_storage_installs_the_initial_schema() {
    let storage = Storage::open_in_memory().expect("storage should open");

    let health = storage.health().expect("health check should succeed");

    assert_eq!(health.schema_version(), 15);
    assert!(health.foreign_keys_enabled());
    assert!(health.missing_tables().is_empty());
}

#[test]
fn applying_migrations_twice_is_safe() {
    let storage = Storage::open_in_memory().expect("storage should open");

    storage
        .ensure_schema()
        .expect("reapplying migrations should succeed");

    assert_eq!(
        storage
            .health()
            .expect("health check should succeed")
            .schema_version(),
        15
    );
}

#[test]
fn content_source_survives_reload_and_updates_in_place() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let source = ContentSource::from_draft(ContentSourceDraft {
        id: "article-1".into(),
        kind: "article".into(),
        title: "A short article".into(),
        local_path: Some("D:/notes/article.txt".into()),
        content_text: "First\n\nSecond".into(),
        reading_position: 1,
        translated_paragraphs_json: r#"{"paragraph-1":"第二段"}"#.into(),
        created_at: "2026-09-12T12:00:00Z".into(),
        is_favorite: false,
        deleted_at: None,
    })
    .expect("source should validate");
    storage
        .save_content_source(&source)
        .expect("source should save");
    let updated = ContentSource::from_draft(ContentSourceDraft {
        id: "article-1".into(),
        kind: "article".into(),
        title: "Updated".into(),
        local_path: Some("D:/notes/article.txt".into()),
        content_text: "First\n\nSecond".into(),
        reading_position: 2,
        translated_paragraphs_json: r#"{"paragraph-1":"第二段","paragraph-2":""}"#.into(),
        created_at: "2026-09-12T12:00:00Z".into(),
        is_favorite: false,
        deleted_at: None,
    })
    .expect("updated source should validate");
    storage
        .save_content_source(&updated)
        .expect("source should update");
    let sources = storage.content_sources(10).expect("sources should list");
    assert_eq!(sources, vec![updated]);
}

#[test]
fn content_source_versions_are_append_only_and_restorable() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let first = ContentSource::from_draft(ContentSourceDraft {
        id: "versioned-article".into(),
        kind: "article".into(),
        title: "Versioned article".into(),
        local_path: Some("D:/notes/versioned.md".into()),
        content_text: "First source".into(),
        reading_position: 0,
        translated_paragraphs_json: r#"{"version":"one"}"#.into(),
        created_at: "2026-09-19T10:00:00Z".into(),
        is_favorite: false,
        deleted_at: None,
    })
    .expect("first source should validate");
    storage
        .save_content_source(&first)
        .expect("first source should save");
    let first_version = storage
        .save_content_source_version(&first)
        .expect("first version should save");

    let second = ContentSource::from_draft(ContentSourceDraft {
        id: "versioned-article".into(),
        kind: "article".into(),
        title: "Versioned article".into(),
        local_path: Some("D:/notes/versioned.md".into()),
        content_text: "Second source".into(),
        reading_position: 1,
        translated_paragraphs_json: r#"{"version":"two"}"#.into(),
        created_at: "2026-09-19T10:05:00Z".into(),
        is_favorite: false,
        deleted_at: None,
    })
    .expect("second source should validate");
    storage
        .save_content_source(&second)
        .expect("second source should save");
    let second_version = storage
        .save_content_source_version(&second)
        .expect("second version should save");

    assert_eq!(first_version.version(), 1);
    assert_eq!(second_version.version(), 2);
    let versions = storage
        .content_source_versions("versioned-article", 10)
        .expect("versions should list");
    assert_eq!(versions.len(), 2);
    assert_eq!(versions[0], second_version);
    assert_eq!(versions[1], first_version);

    let restored = storage
        .restore_content_source_version("versioned-article", first_version.id())
        .expect("first version should restore");
    assert_eq!(restored.content_text(), "First source");
    assert_eq!(
        restored.translated_paragraphs_json(),
        r#"{"version":"one"}"#
    );
}

#[test]
fn content_source_library_state_is_recoverable_without_deleting_the_file() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let source = ContentSource::from_draft(ContentSourceDraft {
        id: "library-state".into(),
        kind: "article".into(),
        title: "Library state".into(),
        local_path: Some("D:/notes/library-state.md".into()),
        content_text: "Keep this source".into(),
        reading_position: 0,
        translated_paragraphs_json: "{}".into(),
        created_at: "2026-09-20T10:00:00Z".into(),
        is_favorite: false,
        deleted_at: None,
    })
    .expect("source should validate");
    storage
        .save_content_source(&source)
        .expect("source should save");

    storage
        .set_content_source_favorite("library-state", true)
        .expect("favorite should save");
    storage
        .trash_content_source("library-state")
        .expect("trash should save");
    let trashed = storage
        .content_sources(10)
        .expect("trashed source should list")
        .pop()
        .expect("source should exist");
    assert!(trashed.is_favorite());
    assert!(trashed.deleted_at().is_some());
    assert_eq!(trashed.local_path(), source.local_path());

    storage
        .restore_content_source("library-state")
        .expect("source should restore");
    let restored = storage
        .content_sources(10)
        .expect("restored source should list")
        .pop()
        .expect("source should exist");
    assert!(restored.is_favorite());
    assert!(restored.deleted_at().is_none());

    storage
        .delete_content_source("library-state")
        .expect("project record should delete");
    assert!(
        storage
            .content_sources(10)
            .expect("sources should list")
            .is_empty()
    );
}
