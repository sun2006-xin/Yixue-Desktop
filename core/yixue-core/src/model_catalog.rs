use serde::{Deserialize, Serialize};

use crate::CoreError;

const ALLOWED_FAMILIES: [&str; 6] = [
    "yixue_translation",
    "qwen",
    "transformers",
    "gguf",
    "onnx",
    "ollama",
];
const ALLOWED_READINESS: [&str; 3] = ["ready_to_validate", "runtime_required", "incomplete"];
const ALLOWED_CAPABILITIES: [&str; 7] = [
    "translation",
    "general_text",
    "summarization",
    "speech_recognition",
    "speech_synthesis",
    "embedding",
    "classification",
];
const ALLOWED_ROLES: [&str; 4] = [
    "translation",
    "understanding",
    "speech_recognition",
    "speech_synthesis",
];

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ModelCatalogEntryDraft {
    pub id: String,
    pub path: String,
    pub display_name: String,
    pub family: String,
    pub readiness: String,
    pub capabilities: Vec<String>,
    pub assigned_roles: Vec<String>,
    #[serde(default)]
    pub source_language: Option<String>,
    #[serde(default)]
    pub target_language: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ModelCatalogEntry {
    id: String,
    path: String,
    display_name: String,
    family: String,
    readiness: String,
    capabilities: Vec<String>,
    assigned_roles: Vec<String>,
    source_language: Option<String>,
    target_language: Option<String>,
}

impl ModelCatalogEntry {
    /// Validates model discovery metadata before it is persisted.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for blank, oversized, or unknown values.
    pub fn new(mut draft: ModelCatalogEntryDraft) -> Result<Self, CoreError> {
        draft.id = draft.id.trim().to_owned();
        draft.path = draft.path.trim().to_owned();
        draft.display_name = draft.display_name.trim().to_owned();
        draft.family = draft.family.trim().to_owned();
        draft.readiness = draft.readiness.trim().to_owned();
        validate_text(&draft.id, 96, "model catalog id")?;
        validate_text(&draft.path, 2_048, "model path")?;
        validate_text(&draft.display_name, 120, "model name")?;
        validate_allowed(&draft.family, &ALLOWED_FAMILIES, "model family")?;
        validate_allowed(&draft.readiness, &ALLOWED_READINESS, "model readiness")?;
        normalize_values(
            &mut draft.capabilities,
            &ALLOWED_CAPABILITIES,
            "model capability",
        )?;
        normalize_values(&mut draft.assigned_roles, &ALLOWED_ROLES, "model role")?;
        normalize_language_pair(&mut draft.source_language, &mut draft.target_language)?;
        Ok(Self {
            id: draft.id,
            path: draft.path,
            display_name: draft.display_name,
            family: draft.family,
            readiness: draft.readiness,
            capabilities: draft.capabilities,
            assigned_roles: draft.assigned_roles,
            source_language: draft.source_language,
            target_language: draft.target_language,
        })
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }
    #[must_use]
    pub fn display_name(&self) -> &str {
        &self.display_name
    }
    #[must_use]
    pub fn family(&self) -> &str {
        &self.family
    }
    #[must_use]
    pub fn readiness(&self) -> &str {
        &self.readiness
    }
    #[must_use]
    pub fn capabilities(&self) -> &[String] {
        &self.capabilities
    }
    #[must_use]
    pub fn assigned_roles(&self) -> &[String] {
        &self.assigned_roles
    }
    #[must_use]
    pub fn source_language(&self) -> Option<&str> {
        self.source_language.as_deref()
    }
    #[must_use]
    pub fn target_language(&self) -> Option<&str> {
        self.target_language.as_deref()
    }
}

fn normalize_language_pair(
    source: &mut Option<String>,
    target: &mut Option<String>,
) -> Result<(), CoreError> {
    match (source.as_mut(), target.as_mut()) {
        (None, None) => Ok(()),
        (Some(source), Some(target)) => {
            *source = source.trim().to_lowercase();
            *target = target.trim().to_lowercase();
            validate_text(source, 64, "model language")?;
            validate_text(target, 64, "model language")?;
            Ok(())
        }
        _ => Err(CoreError::InvalidInput(
            "model catalog languages must be paired",
        )),
    }
}

fn validate_text(value: &str, max: usize, label: &'static str) -> Result<(), CoreError> {
    if value.is_empty() {
        return Err(CoreError::InvalidInput(match label {
            "model catalog id" => "model catalog id is blank",
            "model path" => "model path is blank",
            "model language" => "model language is blank",
            _ => "model name is blank",
        }));
    }
    if value.len() > max {
        return Err(CoreError::InvalidInput("model catalog field is too long"));
    }
    Ok(())
}

fn validate_allowed(value: &str, allowed: &[&str], label: &'static str) -> Result<(), CoreError> {
    if allowed.contains(&value) {
        return Ok(());
    }
    Err(CoreError::InvalidInput(match label {
        "model family" => "model family is unsupported",
        "model readiness" => "model readiness is unsupported",
        "model capability" => "model capability is unsupported",
        _ => "model role is unsupported",
    }))
}

fn normalize_values(
    values: &mut Vec<String>,
    allowed: &[&str],
    label: &'static str,
) -> Result<(), CoreError> {
    for value in values.iter_mut() {
        *value = value.trim().to_owned();
        validate_allowed(value, allowed, label)?;
    }
    values.sort();
    values.dedup();
    Ok(())
}
