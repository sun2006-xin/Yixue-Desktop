use serde::{Deserialize, Serialize};

use crate::CoreError;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DictionaryEntryDraft {
    pub id: String,
    pub word: String,
    pub ipa: String,
    pub part_of_speech: String,
    pub meanings: Vec<String>,
    pub example: String,
    pub example_translation: String,
    pub source: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DictionaryEntry {
    id: String,
    word: String,
    ipa: String,
    part_of_speech: String,
    meanings: Vec<String>,
    example: String,
    example_translation: String,
    source: String,
}

impl DictionaryEntry {
    /// Builds a normalized dictionary entry after validating field limits.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when a required field, meaning, or
    /// field length is invalid.
    pub fn new(mut draft: DictionaryEntryDraft) -> Result<Self, CoreError> {
        draft.id = draft.id.trim().to_owned();
        draft.word = draft.word.trim().to_lowercase();
        draft.ipa = draft.ipa.trim().to_owned();
        draft.part_of_speech = draft.part_of_speech.trim().to_owned();
        draft.example = draft.example.trim().to_owned();
        draft.example_translation = draft.example_translation.trim().to_owned();
        draft.source = draft.source.trim().to_owned();
        for (value, max) in [
            (&draft.id, 96),
            (&draft.word, 160),
            (&draft.ipa, 160),
            (&draft.part_of_speech, 120),
            (&draft.example, 2_000),
            (&draft.example_translation, 2_000),
            (&draft.source, 120),
        ] {
            if value.is_empty() || value.len() > max {
                return Err(CoreError::InvalidInput("dictionary field is invalid"));
            }
        }
        if draft.meanings.is_empty() || draft.meanings.len() > 32 {
            return Err(CoreError::InvalidInput("dictionary meanings are invalid"));
        }
        for meaning in &mut draft.meanings {
            *meaning = meaning.trim().to_owned();
            if meaning.is_empty() || meaning.len() > 500 {
                return Err(CoreError::InvalidInput("dictionary meaning is invalid"));
            }
        }
        Ok(Self {
            id: draft.id,
            word: draft.word,
            ipa: draft.ipa,
            part_of_speech: draft.part_of_speech,
            meanings: draft.meanings,
            example: draft.example,
            example_translation: draft.example_translation,
            source: draft.source,
        })
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
    #[must_use]
    pub fn word(&self) -> &str {
        &self.word
    }
    #[must_use]
    pub fn ipa(&self) -> &str {
        &self.ipa
    }
    #[must_use]
    pub fn part_of_speech(&self) -> &str {
        &self.part_of_speech
    }
    #[must_use]
    pub fn meanings(&self) -> &[String] {
        &self.meanings
    }
    #[must_use]
    pub fn example(&self) -> &str {
        &self.example
    }
    #[must_use]
    pub fn example_translation(&self) -> &str {
        &self.example_translation
    }
    #[must_use]
    pub fn source(&self) -> &str {
        &self.source
    }
}
