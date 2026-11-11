use serde::{Deserialize, Serialize};

use crate::CoreError;

/// The text workflow that produced a translation, independent of its provider.
/// Screenshot provenance does not imply image storage or upload.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TranslationOrigin {
    #[default]
    QuickTranslation,
    ScreenshotTranslation,
}

impl TranslationOrigin {
    pub(crate) const fn as_storage_value(self) -> &'static str {
        match self {
            Self::QuickTranslation => "quick_translation",
            Self::ScreenshotTranslation => "screenshot_translation",
        }
    }

    pub(crate) fn from_storage_value(value: &str) -> Result<Self, CoreError> {
        match value {
            "quick_translation" => Ok(Self::QuickTranslation),
            "screenshot_translation" => Ok(Self::ScreenshotTranslation),
            _ => Err(CoreError::Storage(
                "translation contains an unknown origin".to_owned(),
            )),
        }
    }
}
