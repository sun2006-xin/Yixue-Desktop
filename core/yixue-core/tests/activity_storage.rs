use yixue_core::{
    ActivityEvent, ActivityEventDraft, ActivityKind, CompletedTranslation,
    CompletedTranslationDraft, ContentSource, ContentSourceDraft, Language, Storage,
    TranslationAnnotation, TranslationAnnotationDraft,
};

fn event(
    id: &str,
    kind: ActivityKind,
    title: &str,
    duration_seconds: u32,
    item_count: u32,
    occurred_at: &str,
) -> ActivityEvent {
    ActivityEvent::new(
        id,
        kind,
        title,
        None,
        duration_seconds,
        item_count,
        occurred_at,
    )
    .expect("activity should be valid")
}

fn event_for_source(
    id: &str,
    kind: ActivityKind,
    title: &str,
    source_id: &str,
    item_count: u32,
    occurred_at: &str,
) -> ActivityEvent {
    ActivityEvent::from_draft(ActivityEventDraft {
        id: id.to_owned(),
        kind,
        title: title.to_owned(),
        detail: None,
        source_id: Some(source_id.to_owned()),
        duration_seconds: 0,
        item_count,
        occurred_at: occurred_at.to_owned(),
    })
    .expect("activity with source should be valid")
}

fn save_article(storage: &Storage, id: &str, title: &str, text: &str, created_at: &str) {
    let article = ContentSource::from_draft(ContentSourceDraft {
        id: id.to_owned(),
        kind: "article".to_owned(),
        title: title.to_owned(),
        local_path: None,
        content_text: text.to_owned(),
        reading_position: 0,
        translated_paragraphs_json: "{}".to_owned(),
        created_at: created_at.to_owned(),
        is_favorite: false,
        deleted_at: None,
    })
    .expect("article should be valid");
    storage
        .save_content_source(&article)
        .expect("article should save");
}

fn save_reading(
    storage: &Storage,
    id: &str,
    title: &str,
    source_id: &str,
    item_count: u32,
    occurred_at: &str,
) {
    storage
        .record_activity(&event_for_source(
            id,
            ActivityKind::Reading,
            title,
            source_id,
            item_count,
            occurred_at,
        ))
        .expect("reading progress should save");
}

#[test]
fn daily_snapshot_aggregates_metrics_and_orders_recent_activity() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let activities = [
        event(
            "reading-1",
            ActivityKind::Reading,
            "Human-AI Collaboration.pdf",
            1_200,
            8,
            "2026-09-09T09:00:00+08:00",
        ),
        event(
            "vocabulary-1",
            ActivityKind::Vocabulary,
            "考研核心词",
            600,
            12,
            "2026-09-09T10:00:00+08:00",
        ),
        event(
            "exercise-1",
            ActivityKind::Exercise,
            "中英互译练习",
            360,
            6,
            "2026-09-09T11:00:00+08:00",
        ),
        event(
            "yesterday",
            ActivityKind::Reading,
            "Yesterday.pdf",
            900,
            99,
            "2026-09-08T11:00:00+08:00",
        ),
    ];
    for activity in &activities {
        storage
            .record_activity(activity)
            .expect("activity should save");
    }

    let snapshot = storage
        .home_snapshot("2026-09-09", 2)
        .expect("snapshot should load");

    assert_eq!(snapshot.learning_minutes(), 36);
    assert_eq!(snapshot.reading_pages(), 8);
    assert_eq!(snapshot.mastered_words(), 12);
    assert_eq!(snapshot.completed_exercises(), 6);
    assert_eq!(snapshot.recent().len(), 2);
    assert_eq!(snapshot.recent()[0].id(), "exercise-1");
    assert_eq!(snapshot.recent()[1].id(), "vocabulary-1");
}

#[test]
fn recording_the_same_activity_id_is_idempotent() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let activity = event(
        "reading-1",
        ActivityKind::Reading,
        "Paper.pdf",
        600,
        4,
        "2026-09-09T09:00:00+08:00",
    );

    storage
        .record_activity(&activity)
        .expect("first write should succeed");
    storage
        .record_activity(&activity)
        .expect("duplicate delivery should be safe");

    let snapshot = storage
        .home_snapshot("2026-09-09", 10)
        .expect("snapshot should load");
    assert_eq!(snapshot.learning_minutes(), 10);
    assert_eq!(snapshot.reading_pages(), 4);
    assert_eq!(snapshot.recent().len(), 1);
}

#[test]
fn workbench_snapshot_exposes_available_metrics_without_inventing_data() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let activities = [
        event(
            "translation-1",
            ActivityKind::Translation,
            "Technology changes life.",
            12,
            4,
            "2026-09-15T09:00:00+08:00",
        ),
        event(
            "focus-1",
            ActivityKind::Focus,
            "深度学习",
            1_500,
            1,
            "2026-09-15T10:00:00+08:00",
        ),
        event(
            "speaking-other-day",
            ActivityKind::Speaking,
            "语音练习",
            900,
            1,
            "2026-09-14T10:00:00+08:00",
        ),
    ];
    for activity in &activities {
        storage
            .record_activity(activity)
            .expect("activity should save");
    }

    let snapshot = storage
        .home_workbench_snapshot("2026-09-15", 10)
        .expect("workbench snapshot should load");
    let summary = snapshot.summary();

    assert_eq!(snapshot.local_date(), "2026-09-15");
    assert_eq!(summary.translation_count().value(), 1);
    assert_eq!(summary.translation_units().value(), 4);
    assert_eq!(summary.focus_seconds().value(), 1_500);
    assert_eq!(summary.focus_sessions().value(), 1);
    assert_eq!(summary.speaking_seconds().value(), 0);
    assert!(summary.reading_articles().available_value());
    assert!(summary.favorite_sentences().available_value());
    assert!(summary.favorite_words().available_value());
    assert_eq!(snapshot.recent().len(), 2);
    assert_eq!(snapshot.recent()[0].id(), "focus-1");
}

#[test]
fn workbench_snapshot_joins_real_favorites_and_distinct_reading_articles() {
    let storage = Storage::open_in_memory().expect("storage should open");
    save_article(
        &storage,
        "article-1",
        "A local article",
        "First paragraph",
        "2026-09-16T08:00:00+08:00",
    );
    save_article(
        &storage,
        "article-2",
        "Another article",
        "Another paragraph",
        "2026-09-16T08:05:00+08:00",
    );
    save_reading(
        &storage,
        "reading-1a",
        "A local article",
        "article-1",
        2,
        "2026-09-16T09:00:00+08:00",
    );
    save_reading(
        &storage,
        "reading-1b",
        "A local article",
        "article-1",
        3,
        "2026-09-16T09:05:00+08:00",
    );
    save_reading(
        &storage,
        "reading-2",
        "Another article",
        "article-2",
        4,
        "2026-09-16T09:10:00+08:00",
    );

    let translation = CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::QuickTranslation,
        id: "translation-favorite-1".to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "A useful sentence.".to_owned(),
        translated_text: "一句有用的句子。".to_owned(),
        provider_id: "local.test".to_owned(),
        created_at: "2026-09-16T09:20:00+08:00".to_owned(),
    })
    .expect("translation should be valid");
    storage
        .save_completed_translation(&translation)
        .expect("translation should save");
    storage
        .save_translation_annotation(
            &TranslationAnnotation::new(TranslationAnnotationDraft {
                translation_id: translation.id().to_owned(),
                note: "复习这个句型".to_owned(),
                favorite: true,
                added_to_learning: false,
                updated_at: "2026-09-16T09:21:00+08:00".to_owned(),
            })
            .expect("annotation should be valid"),
        )
        .expect("annotation should save");
    storage
        .set_favorite_word_at("consistency", true, "2026-09-16T09:22:00+08:00")
        .expect("favorite word should save");

    let snapshot = storage
        .home_workbench_snapshot("2026-09-16", 20)
        .expect("workbench snapshot should load");
    let summary = snapshot.summary();

    assert_eq!(summary.reading_articles().value(), 2);
    assert_eq!(summary.reading_units().value(), 9);
    assert_eq!(summary.favorite_sentences().value(), 1);
    assert_eq!(summary.favorite_words().value(), 1);
    assert!(summary.reading_articles().available_value());
    assert!(summary.favorite_sentences().available_value());
    assert!(summary.favorite_words().available_value());
    assert_eq!(snapshot.details().len(), 4);
    assert_eq!(
        snapshot.details()[0].id(),
        "translation:translation-favorite-1"
    );
}
