use serde::{Deserialize, Serialize};

use crate::CoreError;

const MAX_TRANSLATION_ID_LENGTH: usize = 80;
const MAX_NOTE_LENGTH: usize = 4_000;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TranslationAnnotationDraft {
    pub translation_id: String,
    pub note: String,
    pub favorite: bool,
    pub added_to_learning: bool,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct TranslationAnnotation {
    translation_id: String,
    note: String,
    favorite: bool,
    added_to_learning: bool,
    updated_at: String,
}

impl TranslationAnnotation {
    /// Validates a local annotation attached to one completed translation.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the identifier, note, or
    /// timestamp is blank or oversized.
    pub fn new(mut draft: TranslationAnnotationDraft) -> Result<Self, CoreError> {
        draft.translation_id = draft.translation_id.trim().to_owned();
        draft.note = draft.note.trim().to_owned();
        draft.updated_at = draft.updated_at.trim().to_owned();
        if draft.translation_id.is_empty() || draft.translation_id.len() > MAX_TRANSLATION_ID_LENGTH
        {
            return Err(CoreError::InvalidInput(
                "translation annotation id is invalid",
            ));
        }
        if draft.note.chars().count() > MAX_NOTE_LENGTH {
            return Err(CoreError::InvalidInput(
                "translation annotation note is too long",
            ));
        }
        if !is_timestamp_like(&draft.updated_at) {
            return Err(CoreError::InvalidInput(
                "translation annotation timestamp is invalid",
            ));
        }
        Ok(Self {
            translation_id: draft.translation_id,
            note: draft.note,
            favorite: draft.favorite,
            added_to_learning: draft.added_to_learning,
            updated_at: draft.updated_at,
        })
    }

    #[must_use]
    pub fn translation_id(&self) -> &str {
        &self.translation_id
    }

    #[must_use]
    pub fn note(&self) -> &str {
        &self.note
    }

    #[must_use]
    pub const fn favorite(&self) -> bool {
        self.favorite
    }

    #[must_use]
    pub const fn added_to_learning(&self) -> bool {
        self.added_to_learning
    }

    #[must_use]
    pub fn updated_at(&self) -> &str {
        &self.updated_at
    }
}

fn is_timestamp_like(value: &str) -> bool {
    value.len() >= 10
        && value.as_bytes().get(4) == Some(&b'-')
        && value.as_bytes().get(7) == Some(&b'-')
}
