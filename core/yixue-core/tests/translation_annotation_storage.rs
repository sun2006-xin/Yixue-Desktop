use yixue_core::{
    CompletedTranslation, CompletedTranslationDraft, Language, Storage, TranslationAnnotation,
    TranslationAnnotationDraft, WordAnnotation, WordAnnotationDraft,
};

fn completed_translation() -> CompletedTranslation {
    CompletedTranslation::from_draft(CompletedTranslationDraft {
        origin: yixue_core::TranslationOrigin::QuickTranslation,
        id: "translation-annotation-1".to_owned(),
        screenshot_capture_id: None,
        screenshot_ocr_layout: None,
        translated_source_block_indices: None,
        source_language: Language::English,
        target_language: Language::Chinese,
        source_text: "A useful sentence.".to_owned(),
        translated_text: "一句有用的句子。".to_owned(),
        provider_id: "local.test".to_owned(),
        created_at: "2026-09-13T12:00:00+08:00".to_owned(),
    })
    .expect("translation should be valid")
}

#[test]
fn translation_annotation_round_trips_and_updates() {
    let storage = Storage::open_in_memory().expect("storage should open");
    storage
        .save_completed_translation(&completed_translation())
        .expect("translation should save");

    let first = TranslationAnnotation::new(TranslationAnnotationDraft {
        translation_id: "translation-annotation-1".to_owned(),
        note: "保留这个句型，周末复习。".to_owned(),
        favorite: true,
        added_to_learning: true,
        updated_at: "2026-09-13T12:01:00+08:00".to_owned(),
    })
    .expect("annotation should be valid");
    storage
        .save_translation_annotation(&first)
        .expect("annotation should save");

    let updated = TranslationAnnotation::new(TranslationAnnotationDraft {
        translation_id: "translation-annotation-1".to_owned(),
        note: "改成自己的工作例句。".to_owned(),
        favorite: false,
        added_to_learning: true,
        updated_at: "2026-09-13T12:02:00+08:00".to_owned(),
    })
    .expect("updated annotation should be valid");
    storage
        .save_translation_annotation(&updated)
        .expect("annotation update should save");

    let annotations = storage
        .translation_annotations(10)
        .expect("annotations should load");
    assert_eq!(annotations, vec![updated]);
}

#[test]
fn clearing_translation_history_also_removes_annotations() {
    let storage = Storage::open_in_memory().expect("storage should open");
    storage
        .save_completed_translation(&completed_translation())
        .expect("translation should save");
    let annotation = TranslationAnnotation::new(TranslationAnnotationDraft {
        translation_id: "translation-annotation-1".to_owned(),
        note: "待复习".to_owned(),
        favorite: false,
        added_to_learning: true,
        updated_at: "2026-09-13T12:01:00+08:00".to_owned(),
    })
    .expect("annotation should be valid");
    storage
        .save_translation_annotation(&annotation)
        .expect("annotation should save");

    storage
        .clear_user_data("translation_history")
        .expect("history should clear");
    assert!(storage.translation_annotations(10).unwrap().is_empty());
}

#[test]
fn translation_history_pages_are_stable_and_newest_first() {
    let storage = Storage::open_in_memory().expect("storage should open");
    for index in 0..3 {
        let translation = CompletedTranslation::from_draft(CompletedTranslationDraft {
            origin: yixue_core::TranslationOrigin::QuickTranslation,
            id: format!("translation-page-{index}"),
            screenshot_capture_id: None,
            screenshot_ocr_layout: None,
            translated_source_block_indices: None,
            source_language: Language::English,
            target_language: Language::Chinese,
            source_text: format!("Sentence {index}."),
            translated_text: format!("句子 {index}。"),
            provider_id: "local.test".to_owned(),
            created_at: format!("2026-09-14T12:0{index}:00+08:00"),
        })
        .expect("translation should be valid");
        storage
            .save_completed_translation(&translation)
            .expect("translation should save");
    }

    let page = storage
        .recent_translations_page(1, 1)
        .expect("history page should load");
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].id(), "translation-page-1");
}

#[test]
fn word_annotation_round_trips_and_is_removed_with_dictionary_data() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let annotation = WordAnnotation::new(WordAnnotationDraft {
        word: "Apple".to_owned(),
        note: "写一个自己的工作例句。".to_owned(),
        added_to_learning: true,
        updated_at: "2026-09-13T12:03:00+08:00".to_owned(),
    })
    .expect("word annotation should be valid");
    storage
        .save_word_annotation(&annotation)
        .expect("word annotation should save");

    assert_eq!(storage.word_annotation("APPLE").unwrap(), Some(annotation));
    storage
        .clear_user_data("dictionary")
        .expect("dictionary should clear");
    assert!(storage.word_annotation("apple").unwrap().is_none());
}
