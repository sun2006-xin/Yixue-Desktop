use serde::{Deserialize, Serialize};

use crate::CoreError;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Language {
    English,
    Chinese,
}

impl Language {
    pub(crate) const fn as_storage_value(self) -> &'static str {
        match self {
            Self::English => "english",
            Self::Chinese => "chinese",
        }
    }

    pub(crate) fn from_storage_value(value: &str) -> Result<Self, CoreError> {
        match value {
            "english" => Ok(Self::English),
            "chinese" => Ok(Self::Chinese),
            _ => Err(CoreError::Storage(
                "translation contains an unknown language".to_owned(),
            )),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TranslationRequest {
    id: String,
    source_language: Language,
    target_language: Language,
    text: String,
}

impl TranslationRequest {
    /// Creates a validated translation request.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when `text` is blank.
    pub fn new(
        id: impl Into<String>,
        source_language: Language,
        target_language: Language,
        text: impl Into<String>,
    ) -> Result<Self, CoreError> {
        let id = id.into();
        let text = text.into();
        if text.trim().is_empty() || text.chars().count() > 5_000 {
            return Err(CoreError::InvalidInput("text is blank"));
        }

        Ok(Self {
            id,
            source_language,
            target_language,
            text,
        })
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }

    #[must_use]
    pub fn source_language(&self) -> Language {
        self.source_language
    }

    #[must_use]
    pub fn target_language(&self) -> Language {
        self.target_language
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TranslationResult {
    request_id: String,
    provider_id: String,
    text: String,
}

impl TranslationResult {
    #[must_use]
    pub fn new(
        request_id: impl Into<String>,
        provider_id: impl Into<String>,
        text: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            provider_id: provider_id.into(),
            text: text.into(),
        }
    }

    #[must_use]
    pub fn request_id(&self) -> &str {
        &self.request_id
    }

    #[must_use]
    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }
}
