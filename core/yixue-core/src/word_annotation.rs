use serde::{Deserialize, Serialize};

use crate::CoreError;

const MAX_WORD_LENGTH: usize = 160;
const MAX_NOTE_LENGTH: usize = 4_000;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WordAnnotationDraft {
    pub word: String,
    pub note: String,
    pub added_to_learning: bool,
    pub updated_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct WordAnnotation {
    word: String,
    note: String,
    added_to_learning: bool,
    updated_at: String,
}

impl WordAnnotation {
    /// Validates one local note attached to a dictionary word.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when the word, note, or timestamp
    /// is blank or oversized.
    pub fn new(mut draft: WordAnnotationDraft) -> Result<Self, CoreError> {
        draft.word = draft.word.trim().to_lowercase();
        draft.note = draft.note.trim().to_owned();
        draft.updated_at = draft.updated_at.trim().to_owned();
        if draft.word.is_empty() || draft.word.chars().count() > MAX_WORD_LENGTH {
            return Err(CoreError::InvalidInput("word annotation word is invalid"));
        }
        if draft.note.chars().count() > MAX_NOTE_LENGTH {
            return Err(CoreError::InvalidInput("word annotation note is too long"));
        }
        if !is_timestamp_like(&draft.updated_at) {
            return Err(CoreError::InvalidInput(
                "word annotation timestamp is invalid",
            ));
        }
        Ok(Self {
            word: draft.word,
            note: draft.note,
            added_to_learning: draft.added_to_learning,
            updated_at: draft.updated_at,
        })
    }

    #[must_use]
    pub fn word(&self) -> &str {
        &self.word
    }

    #[must_use]
    pub fn note(&self) -> &str {
        &self.note
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
