use yixue_core::{Language, TranslationBenchmarkSuite};

const BASELINE_V1: &str = include_str!("../../../benchmarks/translation/en-zh-baseline-v1.json");

#[test]
fn bundled_baseline_is_valid_and_balanced() {
    let suite = TranslationBenchmarkSuite::from_json(BASELINE_V1)
        .expect("bundled benchmark should be valid");

    assert_eq!(suite.id(), "yixue-en-zh-baseline-v1");
    assert_eq!(suite.cases().len(), 16);
    assert_eq!(
        suite
            .cases()
            .iter()
            .filter(|case| case.source_language() == Language::English)
            .count(),
        8
    );
    assert_eq!(
        suite
            .cases()
            .iter()
            .filter(|case| case.source_language() == Language::Chinese)
            .count(),
        8
    );
}

#[test]
fn duplicate_case_ids_are_rejected() {
    let duplicated = BASELINE_V1.replace("zh-en-spoken-01", "en-zh-daily-01");

    let error =
        TranslationBenchmarkSuite::from_json(&duplicated).expect_err("duplicate ids should fail");

    assert_eq!(
        error.to_string(),
        "duplicate benchmark case: en-zh-daily-01"
    );
}
