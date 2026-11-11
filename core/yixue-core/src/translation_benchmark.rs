use std::collections::HashSet;

use serde::Deserialize;
use thiserror::Error;

use crate::Language;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum BenchmarkCategory {
    Daily,
    Spoken,
    Ambiguity,
    Technical,
    Academic,
    Terminology,
    Formatting,
    LongSentence,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TranslationBenchmarkCase {
    id: String,
    category: BenchmarkCategory,
    source_language: Language,
    target_language: Language,
    source: String,
    references: Vec<String>,
    #[serde(default)]
    preserve: Vec<String>,
}

impl TranslationBenchmarkCase {
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub const fn category(&self) -> BenchmarkCategory {
        self.category
    }

    #[must_use]
    pub const fn source_language(&self) -> Language {
        self.source_language
    }

    #[must_use]
    pub const fn target_language(&self) -> Language {
        self.target_language
    }

    #[must_use]
    pub fn source(&self) -> &str {
        &self.source
    }

    #[must_use]
    pub fn references(&self) -> &[String] {
        &self.references
    }

    #[must_use]
    pub fn preserve(&self) -> &[String] {
        &self.preserve
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TranslationBenchmarkSuite {
    schema_version: u32,
    id: String,
    cases: Vec<TranslationBenchmarkCase>,
}

impl TranslationBenchmarkSuite {
    /// Parses and validates a deterministic translation benchmark suite.
    ///
    /// # Errors
    ///
    /// Returns [`TranslationBenchmarkError`] for malformed JSON, unsupported
    /// schemas, duplicate case identifiers, or invalid case content.
    pub fn from_json(json: &str) -> Result<Self, TranslationBenchmarkError> {
        let suite: Self =
            serde_json::from_str(json).map_err(|_| TranslationBenchmarkError::InvalidJson)?;
        if suite.schema_version != 1 {
            return Err(TranslationBenchmarkError::UnsupportedSchema(
                suite.schema_version,
            ));
        }
        if suite.id.trim().is_empty() || suite.cases.is_empty() || suite.cases.len() > 500 {
            return Err(TranslationBenchmarkError::InvalidSuite);
        }
        let mut ids = HashSet::with_capacity(suite.cases.len());
        for case in &suite.cases {
            if !ids.insert(case.id.as_str()) {
                return Err(TranslationBenchmarkError::DuplicateCase(case.id.clone()));
            }
            validate_case(case)?;
        }
        Ok(suite)
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn cases(&self) -> &[TranslationBenchmarkCase] {
        &self.cases
    }
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum TranslationBenchmarkError {
    #[error("translation benchmark JSON is invalid")]
    InvalidJson,
    #[error("unsupported translation benchmark schema: {0}")]
    UnsupportedSchema(u32),
    #[error("translation benchmark suite is invalid")]
    InvalidSuite,
    #[error("duplicate benchmark case: {0}")]
    DuplicateCase(String),
    #[error("invalid benchmark case: {0}")]
    InvalidCase(String),
}

fn validate_case(case: &TranslationBenchmarkCase) -> Result<(), TranslationBenchmarkError> {
    let invalid = case.id.trim().is_empty()
        || case.source_language == case.target_language
        || case.source.trim().is_empty()
        || case.source.chars().count() > 5_000
        || case.references.is_empty()
        || case.references.len() > 4
        || case.references.iter().any(|value| value.trim().is_empty())
        || case.preserve.iter().any(|value| {
            value.is_empty() || value.chars().count() > 100 || !case.source.contains(value)
        });
    if invalid {
        return Err(TranslationBenchmarkError::InvalidCase(case.id.clone()));
    }
    Ok(())
}
