use serde::{Deserialize, Serialize};

use crate::CoreError;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ContentSourceDraft {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub local_path: Option<String>,
    pub content_text: String,
    pub reading_position: u32,
    pub translated_paragraphs_json: String,
    pub created_at: String,
    #[serde(default)]
    pub is_favorite: bool,
    #[serde(default)]
    pub deleted_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContentSource {
    id: String,
    kind: String,
    title: String,
    local_path: Option<String>,
    content_text: String,
    reading_position: u32,
    translated_paragraphs_json: String,
    created_at: String,
    is_favorite: bool,
    deleted_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContentSourceVersion {
    id: String,
    source_id: String,
    version: u32,
    kind: String,
    title: String,
    local_path: Option<String>,
    content_text: String,
    reading_position: u32,
    translated_paragraphs_json: String,
    created_at: String,
}

impl ContentSourceVersion {
    #[must_use]
    pub fn from_source(source: &ContentSource, id: String, version: u32) -> Self {
        Self {
            id,
            source_id: source.id.clone(),
            version,
            kind: source.kind.clone(),
            title: source.title.clone(),
            local_path: source.local_path.clone(),
            content_text: source.content_text.clone(),
            reading_position: source.reading_position,
            translated_paragraphs_json: source.translated_paragraphs_json.clone(),
            created_at: source.created_at.clone(),
        }
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn source_id(&self) -> &str {
        &self.source_id
    }

    #[must_use]
    pub const fn version(&self) -> u32 {
        self.version
    }

    #[must_use]
    pub fn kind(&self) -> &str {
        &self.kind
    }

    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    #[must_use]
    pub fn local_path(&self) -> Option<&str> {
        self.local_path.as_deref()
    }

    #[must_use]
    pub fn content_text(&self) -> &str {
        &self.content_text
    }

    #[must_use]
    pub const fn reading_position(&self) -> u32 {
        self.reading_position
    }

    #[must_use]
    pub fn translated_paragraphs_json(&self) -> &str {
        &self.translated_paragraphs_json
    }

    #[must_use]
    pub fn created_at(&self) -> &str {
        &self.created_at
    }

    /// Converts a validated version snapshot back into the current source model.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when persisted version data is invalid.
    pub fn to_source(&self) -> Result<ContentSource, CoreError> {
        ContentSource::from_draft(ContentSourceDraft {
            id: self.source_id.clone(),
            kind: self.kind.clone(),
            title: self.title.clone(),
            local_path: self.local_path.clone(),
            content_text: self.content_text.clone(),
            reading_position: self.reading_position,
            translated_paragraphs_json: self.translated_paragraphs_json.clone(),
            created_at: self.created_at.clone(),
            is_favorite: false,
            deleted_at: None,
        })
    }
}

impl ContentSource {
    /// Validates one locally stored article snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when fields are blank, oversized,
    /// malformed, or contain invalid JSON.
    pub fn from_draft(mut draft: ContentSourceDraft) -> Result<Self, CoreError> {
        draft.id = draft.id.trim().to_owned();
        draft.kind = draft.kind.trim().to_owned();
        draft.title = draft.title.trim().to_owned();
        draft.local_path = draft.local_path.map(|value| value.trim().to_owned());
        draft.created_at = draft.created_at.trim().to_owned();
        if draft.id.is_empty() || draft.id.len() > 96 {
            return Err(CoreError::InvalidInput("content source id is invalid"));
        }
        if draft.kind != "article" {
            return Err(CoreError::InvalidInput(
                "content source kind is unsupported",
            ));
        }
        if draft.title.is_empty() || draft.title.len() > 240 {
            return Err(CoreError::InvalidInput("content source title is invalid"));
        }
        if draft.content_text.is_empty() || draft.content_text.chars().count() > 2_000_000 {
            return Err(CoreError::InvalidInput("content source text is invalid"));
        }
        if serde_json::from_str::<serde_json::Value>(&draft.translated_paragraphs_json).is_err() {
            return Err(CoreError::InvalidInput(
                "content source translations are invalid",
            ));
        }
        if draft.created_at.len() < 10 || draft.created_at.as_bytes().get(4) != Some(&b'-') {
            return Err(CoreError::InvalidInput(
                "content source timestamp is invalid",
            ));
        }
        Ok(Self {
            id: draft.id,
            kind: draft.kind,
            title: draft.title,
            local_path: draft.local_path,
            content_text: draft.content_text,
            reading_position: draft.reading_position,
            translated_paragraphs_json: draft.translated_paragraphs_json,
            created_at: draft.created_at,
            is_favorite: draft.is_favorite,
            deleted_at: draft.deleted_at,
        })
    }

    #[must_use]
    pub fn with_library_state(mut self, is_favorite: bool, deleted_at: Option<String>) -> Self {
        self.is_favorite = is_favorite;
        self.deleted_at = deleted_at;
        self
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
    #[must_use]
    pub fn kind(&self) -> &str {
        &self.kind
    }
    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }
    #[must_use]
    pub fn local_path(&self) -> Option<&str> {
        self.local_path.as_deref()
    }
    #[must_use]
    pub fn content_text(&self) -> &str {
        &self.content_text
    }
    #[must_use]
    pub const fn reading_position(&self) -> u32 {
        self.reading_position
    }
    #[must_use]
    pub fn translated_paragraphs_json(&self) -> &str {
        &self.translated_paragraphs_json
    }
    #[must_use]
    pub fn created_at(&self) -> &str {
        &self.created_at
    }

    #[must_use]
    pub const fn is_favorite(&self) -> bool {
        self.is_favorite
    }

    #[must_use]
    pub fn deleted_at(&self) -> Option<&str> {
        self.deleted_at.as_deref()
    }
}
