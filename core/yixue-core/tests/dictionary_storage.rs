use yixue_core::{
    DictionaryEntry, DictionaryEntryDraft, Storage, WordAnnotation, WordAnnotationDraft,
};

#[test]
fn dictionary_entries_and_favorites_survive_round_trip() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let entry = DictionaryEntry::new(DictionaryEntryDraft {
        id: "seed.apple".into(),
        word: "Apple".into(),
        ipa: "/ˈæpəl/".into(),
        part_of_speech: "n. 名词".into(),
        meanings: vec!["苹果".into()],
        example: "An apple a day keeps the doctor away.".into(),
        example_translation: "一天一苹果，医生远离我。".into(),
        source: "yixue-basic".into(),
    })
    .expect("dictionary entry should validate");

    storage
        .save_dictionary_entry(&entry)
        .expect("dictionary entry should save");
    let entries = storage
        .dictionary_entries("APPLE", 10)
        .expect("dictionary entry should load");
    assert_eq!(entries, vec![entry]);

    storage
        .set_favorite_word(" Apple ", true)
        .expect("favorite should save");
    assert_eq!(storage.favorite_words(10).unwrap(), vec!["apple"]);
    storage
        .set_favorite_word("APPLE", false)
        .expect("favorite should remove");
    assert!(storage.favorite_words(10).unwrap().is_empty());
}

#[test]
fn dictionary_search_finds_chinese_meanings_and_ranks_exact_headwords_first() {
    let storage = Storage::open_in_memory().expect("storage should open");
    for (id, word, meaning) in [
        ("seed.arun", "arun", "prefix result"),
        ("seed.run", "run", "to move quickly"),
        ("seed.apple", "apple", "苹果"),
        ("seed.assistant", "assistant", "助理教师"),
        ("seed.teacher", "teacher", "教师；老师"),
    ] {
        let entry = DictionaryEntry::new(DictionaryEntryDraft {
            id: id.into(),
            word: word.into(),
            ipa: "/test/".into(),
            part_of_speech: "n.".into(),
            meanings: vec![meaning.into()],
            example: "Example.".into(),
            example_translation: "示例。".into(),
            source: "test".into(),
        })
        .expect("dictionary entry should validate");
        storage
            .save_dictionary_entry(&entry)
            .expect("dictionary entry should save");
    }

    let english = storage
        .dictionary_entries("run", 10)
        .expect("English dictionary results should load");
    assert_eq!(english.first().map(DictionaryEntry::word), Some("run"));

    let chinese = storage
        .dictionary_entries("教师", 10)
        .expect("Chinese meaning results should load");
    assert_eq!(chinese.first().map(DictionaryEntry::word), Some("teacher"));

    let apple = storage
        .dictionary_entries("苹果", 10)
        .expect("Chinese meaning results should load");
    assert_eq!(apple.first().map(DictionaryEntry::word), Some("apple"));
}

#[test]
fn dictionary_entry_pages_reach_entries_after_the_legacy_limit() {
    let storage = Storage::open_in_memory().expect("storage should open");
    for index in 0..117 {
        let word = format!("word-{index:03}");
        let entry = DictionaryEntry::new(DictionaryEntryDraft {
            id: format!("page-entry-{index:03}"),
            word: word.clone(),
            ipa: "/test/".into(),
            part_of_speech: "n.".into(),
            meanings: vec![format!("释义 {index}")],
            example: "Example.".into(),
            example_translation: "示例。".into(),
            source: (if index < 100 {
                "disabled-source"
            } else {
                "enabled-source"
            })
            .into(),
        })
        .expect("dictionary entry should validate");
        storage.save_dictionary_entry(&entry).unwrap();
    }

    let first = storage.dictionary_entry_page("", 50, 0).unwrap();
    let second = storage.dictionary_entry_page("", 50, 50).unwrap();
    let third = storage.dictionary_entry_page("", 50, 100).unwrap();

    assert_eq!(first.entries.len(), 50);
    assert!(first.has_more);
    assert_eq!(second.entries.len(), 50);
    assert!(second.has_more);
    assert_eq!(third.entries.len(), 17);
    assert!(!third.has_more);
    assert_eq!(third.entries[0].source(), "enabled-source");
}

#[test]
fn clearing_dictionary_data_does_not_remove_provider_configuration() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let entry = DictionaryEntry::new(DictionaryEntryDraft {
        id: "seed.hello".into(),
        word: "hello".into(),
        ipa: "/həˈləʊ/".into(),
        part_of_speech: "int.".into(),
        meanings: vec!["你好".into()],
        example: "Hello.".into(),
        example_translation: "你好。".into(),
        source: "yixue-basic".into(),
    })
    .unwrap();
    storage.save_dictionary_entry(&entry).unwrap();
    storage.set_favorite_word("hello", true).unwrap();

    storage.clear_user_data("dictionary").unwrap();

    assert!(storage.dictionary_entries("hello", 10).unwrap().is_empty());
    assert!(storage.favorite_words(10).unwrap().is_empty());
    assert!(storage.health().unwrap().missing_tables().is_empty());
}

#[test]
fn favorite_word_page_returns_dictionary_details_and_annotations() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let entry = DictionaryEntry::new(DictionaryEntryDraft {
        id: "seed.consistency".into(),
        word: "consistency".into(),
        ipa: "/kənˈsɪstənsi/".into(),
        part_of_speech: "n. 名词".into(),
        meanings: vec!["一致性；连贯性".into()],
        example: "Consistency is the key to success.".into(),
        example_translation: "一致性是成功的关键。".into(),
        source: "yixue-basic".into(),
    })
    .expect("dictionary entry should validate");
    storage
        .save_dictionary_entry(&entry)
        .expect("dictionary entry should save");
    storage
        .set_favorite_word("consistency", true)
        .expect("favorite should save");
    storage
        .save_word_annotation(
            &WordAnnotation::new(WordAnnotationDraft {
                word: "consistency".into(),
                note: "用于写作和论文表达。".into(),
                added_to_learning: true,
                updated_at: "2026-09-14T12:00:00+08:00".into(),
            })
            .expect("annotation should validate"),
        )
        .expect("annotation should save");

    let page = storage
        .favorite_word_page("cons", 20, 0)
        .expect("favorite page should load");

    assert!(!page.has_more);
    assert_eq!(page.records.len(), 1);
    assert_eq!(page.records[0].word, "consistency");
    assert_eq!(page.records[0].language_pair, "en-zh");
    assert_eq!(page.records[0].dictionary_entries, vec![entry]);
    assert_eq!(
        page.records[0].annotation.as_ref().unwrap().note(),
        "用于写作和论文表达。"
    );
    assert!(
        page.records[0]
            .annotation
            .as_ref()
            .unwrap()
            .added_to_learning()
    );
}

#[test]
fn favorite_word_page_can_reach_records_after_two_hundred() {
    let storage = Storage::open_in_memory().expect("storage should open");
    for index in 0..205 {
        storage
            .set_favorite_word(&format!("word-{index}"), true)
            .expect("favorite should save");
    }

    let page = storage
        .favorite_word_page("", 10, 200)
        .expect("favorite page should load");

    assert_eq!(page.records.len(), 5);
    assert!(!page.has_more);
}

#[test]
fn storage_usage_reports_logical_category_bytes() {
    let storage = Storage::open_in_memory().expect("storage should open");
    let entry = DictionaryEntry::new(DictionaryEntryDraft {
        id: "seed.hello".into(),
        word: "hello".into(),
        ipa: "/həˈləʊ/".into(),
        part_of_speech: "int.".into(),
        meanings: vec!["你好".into()],
        example: "Hello.".into(),
        example_translation: "你好。".into(),
        source: "yixue-basic".into(),
    })
    .expect("dictionary entry should validate");
    storage.save_dictionary_entry(&entry).unwrap();
    storage.set_favorite_word("hello", true).unwrap();

    let usage = storage.storage_usage().expect("usage should load");

    assert_eq!(usage.records.len(), 7);
    assert!(
        usage
            .records
            .iter()
            .any(|record| { record.category == "dictionary" && record.used_bytes > 0 })
    );
    assert!(
        usage
            .records
            .iter()
            .any(|record| { record.category == "favorite_words" && record.used_bytes > 0 })
    );
}
