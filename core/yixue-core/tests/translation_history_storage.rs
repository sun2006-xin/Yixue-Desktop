use yixue_core::{
    ActivityKind, CompletedTranslation, CompletedTranslationDraft, CoreError, Language, Storage,
};

fn completed_translation() -> CompletedTranslation {
    CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::QuickTranslation,
        id: "translation-1".to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "Technology changes life.".to_owned(),
        translated_text: "技术改变生活。".to_owned(),
        provider_id: "remote.example".to_owned(),
        created_at: "2026-09-09T12:00:00+08:00".to_owned(),
    })
    .expect("completed translation should be valid")
}

fn screenshot_layout_json() -> serde_json::Value {
    serde_json::json!({
        "version": 1,
        "coordinateSpace": "image_pixels",
        "imageWidth": 640,
        "imageHeight": 480,
        "sourceText": "First source\n\nSecond source",
        "blocks": [
            {"text": "First source", "left": 12, "top": 20, "width": 180, "height": 34},
            {"text": "Second source", "left": 22, "top": 90, "width": 220, "height": 34}
        ]
    })
}

fn aligned_screenshot_translation(id: &str) -> CompletedTranslation {
    let draft = serde_json::from_value::<CompletedTranslationDraft>(serde_json::json!({
        "origin": "screenshot_translation",
        "id": id,
        "screenshot_capture_id": "capture-aligned",
        "source_language": "english",
        "target_language": "chinese",
        "source_text": "First source\n\nSecond source",
        "translated_text": "第二段译文\n\n第一段译文",
        "provider_id": "local.test",
        "created_at": "2026-10-24T12:00:00+08:00",
        "screenshot_ocr_layout": screenshot_layout_json(),
        "translated_source_block_indices": [1, 0]
    }))
    .expect("aligned screenshot draft should decode");
    CompletedTranslation::from_draft(draft).expect("aligned screenshot should validate")
}

fn translation_with(
    id: &str,
    origin: yixue_core::TranslationOrigin,
    source_text: &str,
    translated_text: &str,
    created_at: &str,
) -> CompletedTranslation {
    CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin,
        id: id.to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: source_text.to_owned(),
        translated_text: translated_text.to_owned(),
        provider_id: "local.test".to_owned(),
        created_at: created_at.to_owned(),
    })
    .expect("completed translation should be valid")
}

#[test]
fn saving_translation_atomically_adds_history_and_activity() {
    let storage = Storage::open_in_memory().expect("storage should open");

    storage
        .save_completed_translation(&completed_translation())
        .expect("translation should save");

    let history = storage
        .recent_translations(10)
        .expect("history should load");
    let snapshot = storage
        .home_snapshot("2026-09-09", 10)
        .expect("snapshot should load");
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].translated_text(), "技术改变生活。");
    assert_eq!(snapshot.recent().len(), 1);
    assert_eq!(snapshot.recent()[0].kind(), ActivityKind::Translation);
    assert_eq!(snapshot.recent()[0].item_count(), 1);
}

#[test]
fn saving_the_same_translation_is_idempotent() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let translation = completed_translation();

    storage
        .save_completed_translation(&translation)
        .expect("first save should work");
    storage
        .save_completed_translation(&translation)
        .expect("duplicate save should work");
    let changed_retry = translation_with(
        translation.id(),
        yixue_core::TranslationOrigin::QuickTranslation,
        "replacement source",
        "replacement result",
        "2026-09-09T12:05:00+08:00",
    );
    storage
        .save_completed_translation(&changed_retry)
        .expect("same-source retry should remain idempotent");

    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].source_text(), "Technology changes life.");
    let activity = storage.home_snapshot("2026-09-09", 10).unwrap();
    assert_eq!(activity.recent().len(), 1);
    assert_eq!(activity.recent()[0].title(), "Technology changes life.");
}

#[test]
fn screenshot_retranslation_updates_history_and_matching_activity() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let original = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::ScreenshotTranslation,
        id: "screenshot-retranslation".to_owned(),
        screenshot_capture_id: Some("screenshot-retranslation".to_owned()),
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "Hello there".to_owned(),
        translated_text: "你好".to_owned(),
        provider_id: "remote.en-zh".to_owned(),
        created_at: "2026-09-09T12:00:00+08:00".to_owned(),
    })
    .expect("original screenshot translation should be valid");
    let corrected = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::ScreenshotTranslation,
        id: "screenshot-retranslation".to_owned(),
        screenshot_capture_id: Some("screenshot-retranslation".to_owned()),
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::Chinese,
        target_language: Language::English,
        source_text: "你好".to_owned(),
        translated_text: "Hello there".to_owned(),
        provider_id: "local.zh-en".to_owned(),
        created_at: "2026-09-09T12:05:00+08:00".to_owned(),
    })
    .expect("corrected screenshot translation should be valid");

    storage
        .save_completed_translation(&original)
        .expect("original should save");
    storage
        .save_completed_translation(&corrected)
        .expect("corrected direction should update the screenshot row");
    storage.clear_user_data("activity").unwrap();
    storage
        .save_completed_translation(&corrected)
        .expect("a missing same-source activity should be restored");

    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].id(), "screenshot-retranslation");
    assert_eq!(history[0].source_language(), Language::Chinese);
    assert_eq!(history[0].target_language(), Language::English);
    assert_eq!(history[0].source_text(), "你好");
    assert_eq!(history[0].translated_text(), "Hello there");
    assert_eq!(history[0].provider_id(), "local.zh-en");
    assert_eq!(history[0].created_at(), "2026-09-09T12:05:00+08:00");

    let snapshot = storage.home_snapshot("2026-09-09", 10).unwrap();
    assert_eq!(snapshot.recent().len(), 1);
    assert_eq!(snapshot.recent()[0].title(), "你好");
    assert_eq!(snapshot.recent()[0].detail(), Some("截屏翻译 · 中译英"));
    assert_eq!(
        snapshot.recent()[0].occurred_at(),
        "2026-09-09T12:05:00+08:00"
    );
}

#[test]
fn screenshot_history_summary_requires_exact_source_and_clears_after_source_change() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let original = translation_with(
        "summary-history",
        yixue_core::TranslationOrigin::ScreenshotTranslation,
        "Exact OCR source",
        "原译文",
        "2026-10-09T12:00:00+08:00",
    );
    storage.save_completed_translation(&original).unwrap();

    assert!(
        storage
            .save_screenshot_translation_summary("summary-history", " Exact OCR source ", "摘要",)
            .is_err()
    );
    storage
        .save_screenshot_translation_summary("summary-history", "Exact OCR source", "学习摘要")
        .unwrap();
    let saved = storage.recent_translations(10).unwrap();
    assert_eq!(
        serde_json::to_value(&saved[0]).unwrap()["summary_text"],
        "学习摘要"
    );

    let corrected = translation_with(
        "summary-history",
        yixue_core::TranslationOrigin::ScreenshotTranslation,
        "Corrected OCR source",
        "修正译文",
        "2026-10-09T12:05:00+08:00",
    );
    storage.save_completed_translation(&corrected).unwrap();
    let updated = storage.recent_translations(10).unwrap();
    assert!(
        serde_json::to_value(&updated[0])
            .unwrap()
            .get("summary_text")
            .is_none()
    );
}

#[test]
fn screenshot_history_persists_ocr_geometry_and_explicit_translation_indices() {
    let path = std::env::temp_dir().join(format!(
        "yixue-screenshot-layout-history-{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    {
        let storage = Storage::open(&path).expect("storage should open");
        storage
            .save_completed_translation(&aligned_screenshot_translation("aligned-history"))
            .expect("aligned screenshot history should save");
    }

    let storage = Storage::open(&path).expect("saved screenshot history should reopen");
    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 1);
    let saved = serde_json::to_value(&history[0]).unwrap();
    assert_eq!(saved["screenshot_ocr_layout"], screenshot_layout_json());
    assert_eq!(
        saved["translated_source_block_indices"],
        serde_json::json!([1, 0])
    );
    drop(storage);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn screenshot_layout_metadata_is_rejected_for_quick_translation() {
    let mut value = serde_json::to_value(completed_translation()).unwrap();
    value["screenshot_ocr_layout"] = screenshot_layout_json();
    value["translated_source_block_indices"] = serde_json::json!([0, 1]);
    let draft = serde_json::from_value::<CompletedTranslationDraft>(value).unwrap();

    assert!(matches!(
        CompletedTranslation::from_draft(draft),
        Err(CoreError::InvalidInput(_))
    ));
}

#[test]
fn older_translation_drafts_default_to_missing_screenshot_metadata() {
    let mut value = serde_json::to_value(completed_translation()).unwrap();
    value
        .as_object_mut()
        .unwrap()
        .remove("screenshot_ocr_layout");
    value
        .as_object_mut()
        .unwrap()
        .remove("translated_source_block_indices");
    let draft = serde_json::from_value::<CompletedTranslationDraft>(value).unwrap();

    let translation = CompletedTranslation::from_draft(draft).unwrap();
    assert!(translation.screenshot_ocr_layout().is_none());
    assert!(translation.translated_source_block_indices().is_none());
}

#[test]
fn corrupt_optional_screenshot_metadata_does_not_hide_history_text() {
    let path = std::env::temp_dir().join(format!(
        "yixue-screenshot-layout-corrupt-{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    {
        let storage = Storage::open(&path).expect("storage should open");
        storage
            .save_completed_translation(&aligned_screenshot_translation("corrupt-history"))
            .expect("aligned screenshot history should save");
    }
    {
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute(
                "UPDATE translation_history SET screenshot_ocr_layout = ?1 WHERE id = ?2",
                rusqlite::params!["not valid json", "corrupt-history"],
            )
            .unwrap();
    }

    let storage = Storage::open(&path).expect("storage should reopen");
    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].source_text(), "First source\n\nSecond source");
    assert_eq!(history[0].translated_text(), "第二段译文\n\n第一段译文");
    assert!(history[0].screenshot_ocr_layout().is_none());
    assert!(history[0].translated_source_block_indices().is_none());
    drop(storage);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn screenshot_layout_metadata_requires_a_complete_valid_alignment() {
    let mut value = serde_json::json!({
        "origin": "screenshot_translation",
        "id": "invalid-alignment",
        "screenshot_capture_id": "capture-aligned",
        "source_language": "english",
        "target_language": "chinese",
        "source_text": "First source\n\nSecond source",
        "translated_text": "第一段译文\n\n第二段译文",
        "provider_id": "local.test",
        "created_at": "2026-10-24T12:00:00+08:00",
        "screenshot_ocr_layout": screenshot_layout_json(),
        "translated_source_block_indices": [0, 0]
    });
    let duplicate_indices = serde_json::from_value::<CompletedTranslationDraft>(value.clone())
        .expect("draft shape should decode before domain validation");
    assert!(matches!(
        CompletedTranslation::from_draft(duplicate_indices),
        Err(CoreError::InvalidInput(_))
    ));

    value["translated_source_block_indices"] = serde_json::json!([0]);
    let incomplete = serde_json::from_value::<CompletedTranslationDraft>(value)
        .expect("optional metadata shape should decode");
    assert!(matches!(
        CompletedTranslation::from_draft(incomplete),
        Err(CoreError::InvalidInput(_))
    ));
}

#[test]
fn v14_database_migrates_with_legacy_history_metadata_left_empty() {
    let path = std::env::temp_dir().join(format!(
        "yixue-screenshot-layout-migration-{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    {
        let storage = Storage::open(&path).expect("storage should open");
        storage
            .save_completed_translation(&translation_with(
                "legacy-layout-row",
                yixue_core::TranslationOrigin::ScreenshotTranslation,
                "Legacy source",
                "旧版译文",
                "2026-10-09T12:00:00+08:00",
            ))
            .unwrap();
    }

    {
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "ALTER TABLE translation_history DROP COLUMN summary_source_hash;
                 ALTER TABLE translation_history DROP COLUMN summary_text;
                 ALTER TABLE translation_history DROP COLUMN translated_source_block_indices;
                 ALTER TABLE translation_history DROP COLUMN screenshot_ocr_layout;
                 PRAGMA user_version = 14;",
            )
            .unwrap();
    }
    {
        let storage = Storage::open(&path).expect("v14 storage should migrate");
        assert_eq!(storage.health().unwrap().schema_version(), 15);
        let history = storage.recent_translations(10).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].source_text(), "Legacy source");
        let saved = serde_json::to_value(&history[0]).unwrap();
        assert!(saved.get("screenshot_ocr_layout").is_none());
        assert!(saved.get("translated_source_block_indices").is_none());
        assert!(saved.get("summary_text").is_none());
    }
    std::fs::remove_file(path).unwrap();
}

#[test]
fn existing_v15_summary_candidate_adds_alignment_columns_without_downgrade() {
    let path = std::env::temp_dir().join(format!(
        "yixue-screenshot-layout-v15-candidate-{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    {
        let storage = Storage::open(&path).expect("storage should open");
        storage
            .save_completed_translation(&translation_with(
                "v15-candidate-row",
                yixue_core::TranslationOrigin::ScreenshotTranslation,
                "Candidate source",
                "候选译文",
                "2026-10-09T12:00:00+08:00",
            ))
            .unwrap();
        storage
            .save_screenshot_translation_summary(
                "v15-candidate-row",
                "Candidate source",
                "本机摘要",
            )
            .unwrap();
    }
    {
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "ALTER TABLE translation_history DROP COLUMN translated_source_block_indices;
                 ALTER TABLE translation_history DROP COLUMN screenshot_ocr_layout;
                 PRAGMA user_version = 15;",
            )
            .unwrap();
    }
    {
        let storage = Storage::open(&path).expect("candidate schema should recover");
        assert_eq!(storage.health().unwrap().schema_version(), 15);
        let history = storage.recent_translations(10).unwrap();
        assert_eq!(
            serde_json::to_value(&history[0]).unwrap()["summary_text"],
            "本机摘要"
        );
    }
    std::fs::remove_file(path).unwrap();
}

#[test]
fn screenshot_translation_versions_share_one_capture_without_overwriting_history() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let version = |id: &str, created_at: &str| {
        CompletedTranslation::from_draft(CompletedTranslationDraft {
            origin: yixue_core::TranslationOrigin::ScreenshotTranslation,
            id: id.to_owned(),
            screenshot_capture_id: Some("capture-shared".to_owned()),
            screenshot_ocr_layout: None,
            translated_source_block_indices: None,
            source_language: Language::English,
            target_language: Language::Chinese,
            source_text: format!("source for {id}"),
            translated_text: format!("translation for {id}"),
            provider_id: "local.test".to_owned(),
            created_at: created_at.to_owned(),
        })
        .unwrap()
    };
    let first = version("capture-shared", "2026-10-08T12:00:00+08:00");
    let second = version("capture-shared-v1", "2026-10-08T12:05:00+08:00");
    storage.save_completed_translation(&first).unwrap();
    storage.save_completed_translation(&second).unwrap();

    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 2);
    assert_eq!(history[0].id(), "capture-shared-v1");
    assert_eq!(history[1].id(), "capture-shared");
    assert!(
        history
            .iter()
            .all(|entry| { entry.screenshot_capture_id() == Some("capture-shared") })
    );

    let one_version = vec!["capture-shared".to_owned()];
    assert!(
        storage
            .screenshot_capture_ids_orphaned_by_history_deletion(&one_version)
            .unwrap()
            .is_empty()
    );
    let all_versions = vec!["capture-shared".to_owned(), "capture-shared-v1".to_owned()];
    assert_eq!(
        storage
            .screenshot_capture_ids_orphaned_by_history_deletion(&all_versions)
            .unwrap(),
        vec!["capture-shared".to_owned()]
    );

    storage
        .delete_translation_history(&["capture-shared".to_owned()])
        .unwrap();
    assert_eq!(
        storage
            .screenshot_capture_ids_orphaned_by_history_deletion(&["capture-shared-v1".to_owned()])
            .unwrap(),
        vec!["capture-shared".to_owned()]
    );

    let legacy = translation_with(
        "legacy-capture",
        yixue_core::TranslationOrigin::ScreenshotTranslation,
        "legacy source",
        "legacy translation",
        "2026-10-08T12:10:00+08:00",
    );
    storage.save_completed_translation(&legacy).unwrap();
    assert_eq!(
        storage
            .screenshot_capture_ids_orphaned_by_history_deletion(&["legacy-capture".to_owned()])
            .unwrap(),
        vec!["legacy-capture".to_owned()]
    );
}

#[test]
fn screenshot_capture_ids_still_referenced_only_by_screenshot_history() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let screenshot_version = |id: &str, capture_id: &str| {
        CompletedTranslation::from_draft(CompletedTranslationDraft {
            origin: yixue_core::TranslationOrigin::ScreenshotTranslation,
            id: id.to_owned(),
            screenshot_capture_id: Some(capture_id.to_owned()),
            screenshot_ocr_layout: None,
            translated_source_block_indices: None,
            source_language: Language::English,
            target_language: Language::Chinese,
            source_text: format!("source for {id}"),
            translated_text: format!("translation for {id}"),
            provider_id: "local.test".to_owned(),
            created_at: "2026-10-08T12:00:00+08:00".to_owned(),
        })
        .unwrap()
    };

    storage
        .save_completed_translation(&screenshot_version(
            "screenshot-version-1",
            "capture-shared",
        ))
        .unwrap();
    storage
        .save_completed_translation(&screenshot_version(
            "screenshot-version-2",
            "capture-shared",
        ))
        .unwrap();
    storage
        .save_completed_translation(&translation_with(
            "legacy-capture",
            yixue_core::TranslationOrigin::ScreenshotTranslation,
            "legacy source",
            "legacy translation",
            "2026-10-08T12:05:00+08:00",
        ))
        .unwrap();
    storage
        .save_completed_translation(&translation_with(
            "quick-only-capture",
            yixue_core::TranslationOrigin::QuickTranslation,
            "quick source",
            "quick translation",
            "2026-10-08T12:10:00+08:00",
        ))
        .unwrap();

    assert_eq!(
        storage
            .screenshot_capture_ids_still_referenced(&[
                "missing-capture".to_owned(),
                "legacy-capture".to_owned(),
                "capture-shared".to_owned(),
                "capture-shared".to_owned(),
                "quick-only-capture".to_owned(),
            ])
            .unwrap(),
        vec!["capture-shared".to_owned(), "legacy-capture".to_owned()]
    );
}

#[test]
fn screenshot_capture_reference_query_rejects_invalid_inputs() {
    let storage = Storage::open_in_memory().expect("storage should open");

    assert!(matches!(
        storage.screenshot_capture_ids_still_referenced(&[String::new()]),
        Err(yixue_core::CoreError::InvalidInput(_))
    ));
    assert!(matches!(
        storage.screenshot_capture_ids_still_referenced(&["x".repeat(301)]),
        Err(yixue_core::CoreError::InvalidInput(_))
    ));
    assert!(
        storage
            .screenshot_capture_ids_still_referenced(&["x".repeat(300)])
            .unwrap()
            .is_empty()
    );
    let too_many_ids = (0..501)
        .map(|index| format!("capture-{index}"))
        .collect::<Vec<_>>();
    assert!(matches!(
        storage.screenshot_capture_ids_still_referenced(&too_many_ids),
        Err(yixue_core::CoreError::InvalidInput(_))
    ));
    assert_eq!(
        storage
            .screenshot_capture_ids_still_referenced(&[])
            .unwrap(),
        Vec::<String>::new()
    );
}

#[test]
fn screenshot_id_collision_does_not_overwrite_quick_translation() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let quick = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::QuickTranslation,
        id: "shared-translation-id".to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "quick source".to_owned(),
        translated_text: "快速译文".to_owned(),
        provider_id: "quick.provider".to_owned(),
        created_at: "2026-09-09T12:00:00+08:00".to_owned(),
    })
    .unwrap();
    let screenshot = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::ScreenshotTranslation,
        id: "shared-translation-id".to_owned(),
        screenshot_capture_id: Some("shared-translation-id".to_owned()),
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "screenshot source".to_owned(),
        translated_text: "截图译文".to_owned(),
        provider_id: "screenshot.provider".to_owned(),
        created_at: "2026-09-09T12:05:00+08:00".to_owned(),
    })
    .unwrap();

    storage.save_completed_translation(&quick).unwrap();
    storage.clear_user_data("activity").unwrap();
    storage.save_completed_translation(&screenshot).unwrap();

    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(
        history[0].origin(),
        yixue_core::TranslationOrigin::QuickTranslation
    );
    assert_eq!(history[0].source_text(), "quick source");
    assert_eq!(history[0].translated_text(), "快速译文");
    let activity = storage.home_snapshot("2026-09-09", 10).unwrap();
    assert!(activity.recent().is_empty());
}

#[test]
fn quick_translation_id_collision_does_not_overwrite_screenshot_translation() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let screenshot = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::ScreenshotTranslation,
        id: "shared-translation-id".to_owned(),
        screenshot_capture_id: Some("shared-translation-id".to_owned()),
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "screenshot source".to_owned(),
        translated_text: "截图译文".to_owned(),
        provider_id: "screenshot.provider".to_owned(),
        created_at: "2026-09-09T12:00:00+08:00".to_owned(),
    })
    .unwrap();
    let quick = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::QuickTranslation,
        id: "shared-translation-id".to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "quick source".to_owned(),
        translated_text: "快速译文".to_owned(),
        provider_id: "quick.provider".to_owned(),
        created_at: "2026-09-09T12:05:00+08:00".to_owned(),
    })
    .unwrap();

    storage.save_completed_translation(&screenshot).unwrap();
    storage.save_completed_translation(&quick).unwrap();

    let history = storage.recent_translations(10).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(
        history[0].origin(),
        yixue_core::TranslationOrigin::ScreenshotTranslation
    );
    assert_eq!(history[0].source_text(), "screenshot source");
    assert_eq!(history[0].translated_text(), "截图译文");
    let activity = storage.home_snapshot("2026-09-09", 10).unwrap();
    assert_eq!(activity.recent().len(), 1);
    assert_eq!(activity.recent()[0].title(), "screenshot source");
    assert_eq!(activity.recent()[0].detail(), Some("截屏翻译 · 英译中"));
}

#[test]
fn chinese_to_english_activity_uses_the_correct_direction() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let translation = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::QuickTranslation,
        id: "translation-zh-en".to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::Chinese,
        target_language: Language::English,
        source_text: "Chinese source".to_owned(),
        translated_text: "English result".to_owned(),
        provider_id: "local.opus-zh-en".to_owned(),
        created_at: "2026-09-10T12:00:00+08:00".to_owned(),
    })
    .expect("translation should be valid");

    storage
        .save_completed_translation(&translation)
        .expect("translation should save");
    let snapshot = storage
        .home_snapshot("2026-09-10", 10)
        .expect("snapshot should load");

    assert_eq!(snapshot.recent()[0].detail(), Some("快速翻译 · 中译英"));
}

#[test]
fn deleting_selected_translation_history_removes_annotations_and_activity() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let translation = completed_translation();
    storage
        .save_completed_translation(&translation)
        .expect("translation should save");

    storage
        .delete_translation_history(&[translation.id().to_owned()])
        .expect("selected history should delete");

    assert!(storage.recent_translations(10).unwrap().is_empty());
    assert!(
        storage
            .home_snapshot("2026-09-09", 10)
            .unwrap()
            .recent()
            .is_empty()
    );
}

#[test]
fn v12_history_rows_migrate_with_quick_translation_origin() {
    let path = std::env::temp_dir().join(format!(
        "yixue-origin-{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    {
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE translation_history (
            id TEXT PRIMARY KEY, source_language TEXT NOT NULL, target_language TEXT NOT NULL,
            source_text TEXT NOT NULL, translated_text TEXT NOT NULL, provider_id TEXT NOT NULL,
            source_id TEXT, created_at TEXT NOT NULL);
            INSERT INTO translation_history VALUES ('legacy', 'english', 'chinese', 'Hello', '你好', 'local.dictionary', NULL, '2026-10-06T12:00:00Z');
            PRAGMA user_version = 12;").unwrap();
    }
    {
        let storage = Storage::open(&path).unwrap();
        assert_eq!(storage.health().unwrap().schema_version(), 15);
        let history = storage.recent_translations(10).unwrap();
        assert_eq!(
            serde_json::to_value(&history[0]).unwrap()["origin"],
            "quick_translation"
        );
        storage.ensure_schema().unwrap();
    }
    let connection = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT origin FROM translation_history", [], |row| row
                .get::<_, String>(
                0
            ))
            .unwrap(),
        "quick_translation"
    );
    assert!(
        connection
            .execute("UPDATE translation_history SET origin = 'invalid'", [])
            .is_err()
    );
    drop(connection);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn screenshot_origin_round_trips_in_history() {
    let storage = Storage::open_in_memory().unwrap();
    let mut value = serde_json::to_value(completed_translation()).unwrap();
    value["origin"] = serde_json::json!("screenshot_translation");
    let draft = serde_json::from_value::<CompletedTranslationDraft>(value).unwrap();
    storage
        .save_completed_translation(&CompletedTranslation::from_draft(draft).unwrap())
        .unwrap();
    assert_eq!(
        serde_json::to_value(&storage.recent_translations(10).unwrap()[0]).unwrap()["origin"],
        "screenshot_translation"
    );
    assert_eq!(
        storage.home_snapshot("2026-09-09", 10).unwrap().recent()[0].detail(),
        Some("截屏翻译 · 英译中")
    );
}

#[test]
fn legacy_serialized_draft_defaults_to_quick_translation() {
    let mut value = serde_json::to_value(completed_translation()).unwrap();
    value.as_object_mut().unwrap().remove("origin");
    let draft = serde_json::from_value::<CompletedTranslationDraft>(value).unwrap();
    let completed = CompletedTranslation::from_draft(draft).unwrap();
    assert_eq!(
        serde_json::to_value(completed).unwrap()["origin"],
        "quick_translation"
    );
}

#[test]
fn filtered_history_combines_origin_query_and_pagination() {
    let storage = Storage::open_in_memory().unwrap();
    for translation in [
        translation_with(
            "quick-1",
            yixue_core::TranslationOrigin::QuickTranslation,
            "capture lesson in quick translation",
            "快速翻译结果",
            "2026-10-07T12:00:00+08:00",
        ),
        translation_with(
            "screenshot-1",
            yixue_core::TranslationOrigin::ScreenshotTranslation,
            "capture lesson screenshot one",
            "截图学习结果一",
            "2026-10-07T12:02:00+08:00",
        ),
        translation_with(
            "screenshot-2",
            yixue_core::TranslationOrigin::ScreenshotTranslation,
            "capture lesson screenshot two",
            "截图学习结果二",
            "2026-10-07T12:01:00+08:00",
        ),
    ] {
        storage.save_completed_translation(&translation).unwrap();
    }

    let first_page = storage
        .recent_translations_page_filtered(
            1,
            0,
            Some(yixue_core::TranslationOrigin::ScreenshotTranslation),
            "capture lesson",
        )
        .unwrap();
    assert_eq!(first_page.len(), 1);
    assert_eq!(first_page[0].id(), "screenshot-1");

    let second_page = storage
        .recent_translations_page_filtered(
            1,
            1,
            Some(yixue_core::TranslationOrigin::ScreenshotTranslation),
            "截图学习",
        )
        .unwrap();
    assert_eq!(second_page.len(), 1);
    assert_eq!(second_page[0].id(), "screenshot-2");
}

#[test]
fn screenshot_history_match_requires_id_origin_and_exact_source_text() {
    let storage = Storage::open_in_memory().unwrap();
    storage
        .save_completed_translation(&translation_with(
            "screenshot-exact-match",
            yixue_core::TranslationOrigin::ScreenshotTranslation,
            "Exact captured source",
            "精确截图译文",
            "2026-10-07T12:00:00+08:00",
        ))
        .unwrap();
    storage
        .save_completed_translation(&translation_with(
            "quick-same-source",
            yixue_core::TranslationOrigin::QuickTranslation,
            "Exact captured source",
            "快速翻译译文",
            "2026-10-07T12:01:00+08:00",
        ))
        .unwrap();

    assert!(
        storage
            .screenshot_translation_history_matches(
                "screenshot-exact-match",
                "Exact captured source"
            )
            .unwrap()
    );
    assert!(
        !storage
            .screenshot_translation_history_matches("screenshot-exact-match", "Exact captured")
            .unwrap()
    );
    assert!(
        !storage
            .screenshot_translation_history_matches("quick-same-source", "Exact captured source")
            .unwrap()
    );
    assert!(
        !storage
            .screenshot_translation_history_matches("missing-id", "Exact captured source")
            .unwrap()
    );
}

#[test]
fn screenshot_history_match_rejects_blank_lookup_values() {
    let storage = Storage::open_in_memory().unwrap();

    assert!(matches!(
        storage.screenshot_translation_history_matches("  ", "Exact captured source"),
        Err(yixue_core::CoreError::InvalidInput(_))
    ));
    assert!(matches!(
        storage.screenshot_translation_history_matches("screenshot-id", "  "),
        Err(yixue_core::CoreError::InvalidInput(_))
    ));
}

#[test]
fn empty_history_query_preserves_unfiltered_page_behavior() {
    let storage = Storage::open_in_memory().unwrap();
    storage
        .save_completed_translation(&translation_with(
            "quick",
            yixue_core::TranslationOrigin::QuickTranslation,
            "Quick source",
            "快速结果",
            "2026-10-07T12:00:00+08:00",
        ))
        .unwrap();
    storage
        .save_completed_translation(&translation_with(
            "screenshot",
            yixue_core::TranslationOrigin::ScreenshotTranslation,
            "Screenshot source",
            "截屏结果",
            "2026-10-07T12:01:00+08:00",
        ))
        .unwrap();

    let legacy_page = storage.recent_translations_page(10, 0).unwrap();
    let empty_query_page = storage
        .recent_translations_page_filtered(10, 0, None, "")
        .unwrap();
    assert_eq!(empty_query_page, legacy_page);
    assert_eq!(legacy_page[0].id(), "screenshot");
    assert_eq!(legacy_page[1].id(), "quick");
}

#[test]
fn history_query_treats_sql_wildcards_as_literal_text() {
    let storage = Storage::open_in_memory().unwrap();
    for (id, source) in [
        ("literal", "Save 100% of your work"),
        ("wildcard", "Save 100x of your work"),
        ("underscore", "Save 100_of your work"),
    ] {
        storage
            .save_completed_translation(&translation_with(
                id,
                yixue_core::TranslationOrigin::QuickTranslation,
                source,
                "已保存",
                "2026-10-07T12:00:00+08:00",
            ))
            .unwrap();
    }

    let percent = storage
        .recent_translations_page_filtered(10, 0, None, "100%")
        .unwrap();
    let underscore = storage
        .recent_translations_page_filtered(10, 0, None, "100_")
        .unwrap();

    assert_eq!(
        percent.iter().map(|item| item.id()).collect::<Vec<_>>(),
        ["literal"]
    );
    assert_eq!(
        underscore.iter().map(|item| item.id()).collect::<Vec<_>>(),
        ["underscore"]
    );

    for (id, source) in [
        ("slash_literal", r"Save C:\100%_notes today"),
        ("slash_missing", r"Save C:/100%_notes today"),
        ("slash_percent", r"Save C:\100x_notes today"),
        ("slash_underscore", r"Save C:\100%Xnotes today"),
    ] {
        storage
            .save_completed_translation(&translation_with(
                id,
                yixue_core::TranslationOrigin::QuickTranslation,
                source,
                "已保存",
                "2026-10-07T12:01:00+08:00",
            ))
            .unwrap();
    }

    let backslash_and_wildcards = storage
        .recent_translations_page_filtered(10, 0, None, r"\100%_")
        .unwrap();
    assert_eq!(
        backslash_and_wildcards
            .iter()
            .map(|item| item.id())
            .collect::<Vec<_>>(),
        ["slash_literal"]
    );
}
