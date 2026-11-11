use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use crate::{CoreError, Language, TranslationOrigin};

const SCREENSHOT_OCR_LAYOUT_VERSION: u32 = 1;
const SCREENSHOT_OCR_COORDINATE_SPACE: &str = "image_pixels";
const MAX_SCREENSHOT_OCR_IMAGE_DIMENSION: u32 = 100_000;
const MAX_SCREENSHOT_OCR_LAYOUT_BLOCKS: usize = 500;
const MAX_SCREENSHOT_OCR_LAYOUT_TEXT_CHARACTERS: usize = 20_000;
const MAX_SCREENSHOT_OCR_BLOCK_TEXT_CHARACTERS: usize = 5_000;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CompletedTranslationDraft {
    #[serde(default)]
    pub origin: TranslationOrigin,
    pub id: String,
    /// Stable screenshot/session identifier shared by retranslation versions.
    /// Older clients omit this field; screenshot history then uses `id` as
    /// its legacy capture identifier.
    #[serde(default)]
    pub screenshot_capture_id: Option<String>,
    /// Versioned OCR geometry in screenshot-local pixel coordinates.
    ///
    /// Older clients omit this field; non-screenshot translations must omit it.
    #[serde(default)]
    pub screenshot_ocr_layout: Option<ScreenshotTranslationOcrLayout>,
    /// One source OCR block index for each translated paragraph.
    ///
    /// This mapping is optional because many translation routes return plain
    /// text without preserving block boundaries.
    #[serde(default)]
    pub translated_source_block_indices: Option<Vec<u32>>,
    pub source_language: Language,
    pub target_language: Language,
    pub source_text: String,
    pub translated_text: String,
    pub provider_id: String,
    pub created_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CompletedTranslation {
    origin: TranslationOrigin,
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    screenshot_capture_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    screenshot_ocr_layout: Option<ScreenshotTranslationOcrLayout>,
    #[serde(skip_serializing_if = "Option::is_none")]
    translated_source_block_indices: Option<Vec<u32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    summary_text: Option<String>,
    source_language: Language,
    target_language: Language,
    source_text: String,
    translated_text: String,
    provider_id: String,
    created_at: String,
}

/// OCR boxes relative to the exact screenshot image saved for a history row.
///
/// Field names inside this object use the Dart screenshot-session map's
/// camelCase contract. The outer history field stays snake_case like the rest
/// of the FFI JSON payload.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ScreenshotTranslationOcrLayout {
    pub version: u32,
    pub coordinate_space: String,
    pub image_width: u32,
    pub image_height: u32,
    pub source_text: String,
    pub blocks: Vec<ScreenshotTranslationOcrBlock>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ScreenshotTranslationOcrBlock {
    pub text: String,
    pub left: u32,
    pub top: u32,
    pub width: u32,
    pub height: u32,
}

impl CompletedTranslation {
    /// Validates one successful translation before it enters local history.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for blank, oversized, malformed,
    /// or same-language records.
    pub fn from_draft(mut draft: CompletedTranslationDraft) -> Result<Self, CoreError> {
        draft.id = draft.id.trim().to_owned();
        draft.source_text = draft.source_text.trim().to_owned();
        draft.translated_text = draft.translated_text.trim().to_owned();
        draft.provider_id = draft.provider_id.trim().to_owned();
        draft.created_at = draft.created_at.trim().to_owned();
        if draft.id.is_empty() || draft.id.len() > 80 {
            return Err(CoreError::InvalidInput("translation id is invalid"));
        }
        if let Some(capture_id) = draft.screenshot_capture_id.as_mut() {
            *capture_id = capture_id.trim().to_owned();
            if draft.origin != TranslationOrigin::ScreenshotTranslation
                || capture_id.is_empty()
                || capture_id.len() > 80
                || !capture_id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
            {
                return Err(CoreError::InvalidInput("screenshot capture id is invalid"));
            }
        }
        if draft.source_language == draft.target_language {
            return Err(CoreError::InvalidInput(
                "translation languages are identical",
            ));
        }
        if draft.source_text.is_empty() || draft.source_text.chars().count() > 5_000 {
            return Err(CoreError::InvalidInput("translation source is invalid"));
        }
        if draft.translated_text.is_empty() || draft.translated_text.chars().count() > 20_000 {
            return Err(CoreError::InvalidInput("translation result is invalid"));
        }
        validate_screenshot_alignment(
            draft.origin,
            &draft.source_text,
            &draft.translated_text,
            draft.screenshot_ocr_layout.as_ref(),
            draft.translated_source_block_indices.as_deref(),
        )?;
        if draft.provider_id.is_empty() || draft.provider_id.len() > 96 {
            return Err(CoreError::InvalidInput("translation provider is invalid"));
        }
        if !is_timestamp_like(&draft.created_at) {
            return Err(CoreError::InvalidInput("translation timestamp is invalid"));
        }
        Ok(Self {
            origin: draft.origin,
            id: draft.id,
            screenshot_capture_id: draft.screenshot_capture_id,
            screenshot_ocr_layout: draft.screenshot_ocr_layout,
            translated_source_block_indices: draft.translated_source_block_indices,
            summary_text: None,
            source_language: draft.source_language,
            target_language: draft.target_language,
            source_text: draft.source_text,
            translated_text: draft.translated_text,
            provider_id: draft.provider_id,
            created_at: draft.created_at,
        })
    }

    /// Builds a history row loaded from the database, dropping corrupt
    /// optional alignment metadata while preserving its authoritative text.
    pub(crate) fn from_stored_draft(
        mut draft: CompletedTranslationDraft,
    ) -> Result<Self, CoreError> {
        if validate_screenshot_alignment(
            draft.origin,
            &draft.source_text,
            &draft.translated_text,
            draft.screenshot_ocr_layout.as_ref(),
            draft.translated_source_block_indices.as_deref(),
        )
        .is_err()
        {
            draft.screenshot_ocr_layout = None;
            draft.translated_source_block_indices = None;
        }
        Self::from_draft(draft)
    }

    #[must_use]
    pub const fn origin(&self) -> TranslationOrigin {
        self.origin
    }
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
    #[must_use]
    pub fn screenshot_capture_id(&self) -> Option<&str> {
        self.screenshot_capture_id.as_deref()
    }
    #[must_use]
    pub const fn screenshot_ocr_layout(&self) -> Option<&ScreenshotTranslationOcrLayout> {
        self.screenshot_ocr_layout.as_ref()
    }
    #[must_use]
    pub fn translated_source_block_indices(&self) -> Option<&[u32]> {
        self.translated_source_block_indices.as_deref()
    }
    #[must_use]
    pub(crate) fn with_summary_text(mut self, summary_text: Option<String>) -> Self {
        self.summary_text = summary_text;
        self
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
    pub fn source_text(&self) -> &str {
        &self.source_text
    }
    #[must_use]
    pub fn translated_text(&self) -> &str {
        &self.translated_text
    }
    #[must_use]
    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }
    #[must_use]
    pub fn created_at(&self) -> &str {
        &self.created_at
    }
}

fn validate_screenshot_alignment(
    origin: TranslationOrigin,
    source_text: &str,
    translated_text: &str,
    layout: Option<&ScreenshotTranslationOcrLayout>,
    translated_source_block_indices: Option<&[u32]>,
) -> Result<(), CoreError> {
    if layout.is_some() || translated_source_block_indices.is_some() {
        if origin != TranslationOrigin::ScreenshotTranslation {
            return Err(CoreError::InvalidInput(
                "screenshot alignment is only valid for screenshot translations",
            ));
        }
    }
    let Some(layout) = layout else {
        return if translated_source_block_indices.is_some() {
            Err(CoreError::InvalidInput(
                "screenshot block indices require an OCR layout",
            ))
        } else {
            Ok(())
        };
    };

    if layout.version != SCREENSHOT_OCR_LAYOUT_VERSION
        || layout.coordinate_space != SCREENSHOT_OCR_COORDINATE_SPACE
        || layout.image_width == 0
        || layout.image_height == 0
        || layout.image_width > MAX_SCREENSHOT_OCR_IMAGE_DIMENSION
        || layout.image_height > MAX_SCREENSHOT_OCR_IMAGE_DIMENSION
        || layout.source_text.is_empty()
        || layout.source_text.chars().count() > MAX_SCREENSHOT_OCR_LAYOUT_TEXT_CHARACTERS
        || layout.source_text != source_text
        || layout.blocks.is_empty()
        || layout.blocks.len() > MAX_SCREENSHOT_OCR_LAYOUT_BLOCKS
    {
        return Err(CoreError::InvalidInput("screenshot OCR layout is invalid"));
    }

    for block in &layout.blocks {
        if block.text.trim().is_empty()
            || block.text.chars().count() > MAX_SCREENSHOT_OCR_BLOCK_TEXT_CHARACTERS
            || block.width == 0
            || block.height == 0
            || block
                .left
                .checked_add(block.width)
                .is_none_or(|right| right > layout.image_width)
            || block
                .top
                .checked_add(block.height)
                .is_none_or(|bottom| bottom > layout.image_height)
        {
            return Err(CoreError::InvalidInput("screenshot OCR block is invalid"));
        }
    }
    if layout
        .blocks
        .iter()
        .map(|block| block.text.as_str())
        .collect::<Vec<_>>()
        .join("\n\n")
        != layout.source_text
    {
        return Err(CoreError::InvalidInput(
            "screenshot OCR text does not match its blocks",
        ));
    }

    if let Some(indices) = translated_source_block_indices {
        if indices.len() != layout.blocks.len()
            || indices
                .iter()
                .any(|index| *index as usize >= layout.blocks.len())
            || indices.iter().copied().collect::<HashSet<_>>().len() != layout.blocks.len()
            || translated_paragraph_count(translated_text) != indices.len()
        {
            return Err(CoreError::InvalidInput(
                "screenshot translation block mapping is invalid",
            ));
        }
    }
    Ok(())
}

fn translated_paragraph_count(text: &str) -> usize {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut count = 0;
    let mut paragraph_has_text = false;
    for line in normalized.split('\n') {
        if line.trim().is_empty() {
            if paragraph_has_text {
                count += 1;
                paragraph_has_text = false;
            }
        } else {
            paragraph_has_text = true;
        }
    }
    if paragraph_has_text {
        count += 1;
    }
    count
}

fn is_timestamp_like(value: &str) -> bool {
    value.len() >= 10
        && value.as_bytes().get(4) == Some(&b'-')
        && value.as_bytes().get(7) == Some(&b'-')
}
