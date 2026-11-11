use serde::{Deserialize, Serialize};

use crate::CoreError;

pub const HOME_WORKBENCH_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityKind {
    Translation,
    Reading,
    Vocabulary,
    Exercise,
    Speaking,
    Focus,
}

impl ActivityKind {
    pub(crate) const fn as_storage_value(self) -> &'static str {
        match self {
            Self::Translation => "translation",
            Self::Reading => "reading",
            Self::Vocabulary => "vocabulary",
            Self::Exercise => "exercise",
            Self::Speaking => "speaking",
            Self::Focus => "focus",
        }
    }

    pub(crate) fn from_storage_value(value: &str) -> Result<Self, CoreError> {
        match value {
            "translation" => Ok(Self::Translation),
            "reading" => Ok(Self::Reading),
            "vocabulary" => Ok(Self::Vocabulary),
            "exercise" => Ok(Self::Exercise),
            "speaking" => Ok(Self::Speaking),
            "focus" => Ok(Self::Focus),
            _ => Err(CoreError::Storage(
                "activity contains an unknown kind".to_owned(),
            )),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct HomeMetricData {
    available: bool,
    value: u32,
}

impl HomeMetricData {
    pub(crate) const fn available(value: u32) -> Self {
        Self {
            available: true,
            value,
        }
    }

    #[must_use]
    pub const fn available_value(&self) -> bool {
        self.available
    }

    #[must_use]
    pub const fn value(&self) -> u32 {
        self.value
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct HomeWorkbenchSummary {
    schema_version: u32,
    translation_count: HomeMetricData,
    translation_units: HomeMetricData,
    learned_words: HomeMetricData,
    reading_articles: HomeMetricData,
    reading_units: HomeMetricData,
    favorite_sentences: HomeMetricData,
    favorite_words: HomeMetricData,
    speaking_seconds: HomeMetricData,
    focus_seconds: HomeMetricData,
    focus_sessions: HomeMetricData,
}

impl HomeWorkbenchSummary {
    #[allow(clippy::too_many_arguments)]
    pub(crate) const fn new(
        translation_count: HomeMetricData,
        translation_units: HomeMetricData,
        learned_words: HomeMetricData,
        reading_articles: HomeMetricData,
        reading_units: HomeMetricData,
        favorite_sentences: HomeMetricData,
        favorite_words: HomeMetricData,
        speaking_seconds: HomeMetricData,
        focus_seconds: HomeMetricData,
        focus_sessions: HomeMetricData,
    ) -> Self {
        Self {
            schema_version: HOME_WORKBENCH_SCHEMA_VERSION,
            translation_count,
            translation_units,
            learned_words,
            reading_articles,
            reading_units,
            favorite_sentences,
            favorite_words,
            speaking_seconds,
            focus_seconds,
            focus_sessions,
        }
    }

    #[must_use]
    pub const fn schema_version(&self) -> u32 {
        self.schema_version
    }

    #[must_use]
    pub const fn translation_count(&self) -> HomeMetricData {
        self.translation_count
    }

    #[must_use]
    pub const fn translation_units(&self) -> HomeMetricData {
        self.translation_units
    }

    #[must_use]
    pub const fn learned_words(&self) -> HomeMetricData {
        self.learned_words
    }

    #[must_use]
    pub const fn reading_articles(&self) -> HomeMetricData {
        self.reading_articles
    }

    #[must_use]
    pub const fn reading_units(&self) -> HomeMetricData {
        self.reading_units
    }

    #[must_use]
    pub const fn favorite_sentences(&self) -> HomeMetricData {
        self.favorite_sentences
    }

    #[must_use]
    pub const fn favorite_words(&self) -> HomeMetricData {
        self.favorite_words
    }

    #[must_use]
    pub const fn speaking_seconds(&self) -> HomeMetricData {
        self.speaking_seconds
    }

    #[must_use]
    pub const fn focus_seconds(&self) -> HomeMetricData {
        self.focus_seconds
    }

    #[must_use]
    pub const fn focus_sessions(&self) -> HomeMetricData {
        self.focus_sessions
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct HomeWorkbenchSnapshot {
    local_date: String,
    summary: HomeWorkbenchSummary,
    recent: Vec<ActivityEvent>,
    details: Vec<ActivityEvent>,
}

impl HomeWorkbenchSnapshot {
    pub(crate) fn new(
        local_date: impl Into<String>,
        summary: HomeWorkbenchSummary,
        recent: Vec<ActivityEvent>,
        details: Vec<ActivityEvent>,
    ) -> Self {
        Self {
            local_date: local_date.into(),
            summary,
            recent,
            details,
        }
    }

    #[must_use]
    pub fn local_date(&self) -> &str {
        &self.local_date
    }

    #[must_use]
    pub const fn summary(&self) -> &HomeWorkbenchSummary {
        &self.summary
    }

    #[must_use]
    pub fn recent(&self) -> &[ActivityEvent] {
        &self.recent
    }

    #[must_use]
    pub fn details(&self) -> &[ActivityEvent] {
        &self.details
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActivityEventDraft {
    pub id: String,
    pub kind: ActivityKind,
    pub title: String,
    pub detail: Option<String>,
    #[serde(default)]
    pub source_id: Option<String>,
    pub duration_seconds: u32,
    pub item_count: u32,
    pub occurred_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ActivityEvent {
    id: String,
    kind: ActivityKind,
    title: String,
    detail: Option<String>,
    source_id: Option<String>,
    duration_seconds: u32,
    item_count: u32,
    occurred_at: String,
}

impl ActivityEvent {
    /// Creates one local, privacy-safe activity event.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for blank or oversized identity,
    /// title, detail, or timestamp fields.
    pub fn from_draft(mut draft: ActivityEventDraft) -> Result<Self, CoreError> {
        draft.id = draft.id.trim().to_owned();
        draft.title = draft.title.trim().to_owned();
        draft.occurred_at = draft.occurred_at.trim().to_owned();
        draft.detail = draft
            .detail
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        draft.source_id = draft
            .source_id
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        if draft.id.is_empty() || draft.id.len() > 96 {
            return Err(CoreError::InvalidInput("activity id is invalid"));
        }
        if draft.title.is_empty() || draft.title.len() > 240 {
            return Err(CoreError::InvalidInput("activity title is invalid"));
        }
        if draft
            .detail
            .as_ref()
            .is_some_and(|value| value.len() > 1_024)
        {
            return Err(CoreError::InvalidInput("activity detail is too long"));
        }
        if draft
            .source_id
            .as_ref()
            .is_some_and(|value| value.len() > 96)
        {
            return Err(CoreError::InvalidInput("activity source id is invalid"));
        }
        if !is_timestamp_like(&draft.occurred_at) {
            return Err(CoreError::InvalidInput("activity timestamp is invalid"));
        }
        Ok(Self {
            id: draft.id,
            kind: draft.kind,
            title: draft.title,
            detail: draft.detail,
            source_id: draft.source_id,
            duration_seconds: draft.duration_seconds,
            item_count: draft.item_count,
            occurred_at: draft.occurred_at,
        })
    }

    /// Creates an event from individual fields.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when any field violates the same
    /// contract enforced by [`Self::from_draft`].
    pub fn new(
        id: impl Into<String>,
        kind: ActivityKind,
        title: impl Into<String>,
        detail: Option<String>,
        duration_seconds: u32,
        item_count: u32,
        occurred_at: impl Into<String>,
    ) -> Result<Self, CoreError> {
        Self::from_draft(ActivityEventDraft {
            id: id.into(),
            kind,
            title: title.into(),
            detail,
            source_id: None,
            duration_seconds,
            item_count,
            occurred_at: occurred_at.into(),
        })
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub const fn kind(&self) -> ActivityKind {
        self.kind
    }

    #[must_use]
    pub fn title(&self) -> &str {
        &self.title
    }

    #[must_use]
    pub fn detail(&self) -> Option<&str> {
        self.detail.as_deref()
    }

    #[must_use]
    pub fn source_id(&self) -> Option<&str> {
        self.source_id.as_deref()
    }

    #[must_use]
    pub const fn duration_seconds(&self) -> u32 {
        self.duration_seconds
    }

    #[must_use]
    pub const fn item_count(&self) -> u32 {
        self.item_count
    }

    #[must_use]
    pub fn occurred_at(&self) -> &str {
        &self.occurred_at
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct HomeSnapshot {
    learning_minutes: u32,
    reading_pages: u32,
    mastered_words: u32,
    completed_exercises: u32,
    recent: Vec<ActivityEvent>,
}

impl HomeSnapshot {
    pub(crate) const fn new(
        learning_minutes: u32,
        reading_pages: u32,
        mastered_words: u32,
        completed_exercises: u32,
        recent: Vec<ActivityEvent>,
    ) -> Self {
        Self {
            learning_minutes,
            reading_pages,
            mastered_words,
            completed_exercises,
            recent,
        }
    }

    #[must_use]
    pub const fn learning_minutes(&self) -> u32 {
        self.learning_minutes
    }

    #[must_use]
    pub const fn reading_pages(&self) -> u32 {
        self.reading_pages
    }

    #[must_use]
    pub const fn mastered_words(&self) -> u32 {
        self.mastered_words
    }

    #[must_use]
    pub const fn completed_exercises(&self) -> u32 {
        self.completed_exercises
    }

    #[must_use]
    pub fn recent(&self) -> &[ActivityEvent] {
        &self.recent
    }
}

fn is_timestamp_like(value: &str) -> bool {
    value.len() >= 10
        && value.as_bytes().get(4) == Some(&b'-')
        && value.as_bytes().get(7) == Some(&b'-')
}
