use std::net::IpAddr;

use serde::{Deserialize, Serialize};
use url::{Host, Url};

use crate::CoreError;

const MAX_ID_LENGTH: usize = 96;
const MAX_NAME_LENGTH: usize = 120;
const MAX_MODEL_ID_LENGTH: usize = 256;
const MAX_ENDPOINT_LENGTH: usize = 2_048;
const MAX_PATH_LENGTH: usize = 2_048;
const MAX_SECRET_REF_LENGTH: usize = 160;
const ALLOWED_ROLES: [&str; 4] = [
    "translation",
    "understanding",
    "speech_recognition",
    "speech_synthesis",
];

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderProfileKind {
    LocalModel,
    RemoteApi,
}

impl ProviderProfileKind {
    pub(crate) const fn as_storage_value(self) -> &'static str {
        match self {
            Self::LocalModel => "local_model",
            Self::RemoteApi => "remote_api",
        }
    }

    pub(crate) fn from_storage_value(value: &str) -> Result<Self, CoreError> {
        match value {
            "local_model" => Ok(Self::LocalModel),
            "remote_api" => Ok(Self::RemoteApi),
            _ => Err(CoreError::Storage(
                "provider profile contains an unknown kind".to_owned(),
            )),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderProfileDraft {
    pub id: String,
    pub display_name: String,
    pub kind: ProviderProfileKind,
    pub enabled: bool,
    pub model_id: String,
    pub endpoint: Option<String>,
    pub model_path: Option<String>,
    pub secret_ref: Option<String>,
    #[serde(default)]
    pub assigned_roles: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProviderProfile {
    id: String,
    display_name: String,
    kind: ProviderProfileKind,
    enabled: bool,
    model_id: String,
    endpoint: Option<String>,
    model_path: Option<String>,
    secret_ref: Option<String>,
    assigned_roles: Vec<String>,
}

impl ProviderProfile {
    /// Validates and creates non-secret provider metadata.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] when fields are blank, oversized, unsafe,
    /// or incompatible with the selected provider kind.
    pub fn new(mut draft: ProviderProfileDraft) -> Result<Self, CoreError> {
        trim_optional(&mut draft.endpoint);
        trim_optional(&mut draft.model_path);
        trim_optional(&mut draft.secret_ref);
        draft.id = draft.id.trim().to_owned();
        draft.display_name = draft.display_name.trim().to_owned();
        draft.model_id = draft.model_id.trim().to_owned();
        normalize_roles(&mut draft.assigned_roles)?;

        validate_identifier(&draft.id, "provider id")?;
        validate_required_text(
            &draft.display_name,
            MAX_NAME_LENGTH,
            "provider name is blank",
            "provider name is too long",
        )?;
        validate_required_text(
            &draft.model_id,
            MAX_MODEL_ID_LENGTH,
            "model id is blank",
            "model id is too long",
        )?;
        validate_optional_length(
            draft.model_path.as_deref(),
            MAX_PATH_LENGTH,
            "local model path is too long",
        )?;
        validate_optional_length(
            draft.secret_ref.as_deref(),
            MAX_SECRET_REF_LENGTH,
            "secret reference is too long",
        )?;

        match draft.kind {
            ProviderProfileKind::LocalModel => validate_local_model(&draft)?,
            ProviderProfileKind::RemoteApi => validate_remote_api(&draft)?,
        }

        Ok(Self {
            id: draft.id,
            display_name: draft.display_name,
            kind: draft.kind,
            enabled: draft.enabled,
            model_id: draft.model_id,
            endpoint: draft.endpoint,
            model_path: draft.model_path,
            secret_ref: draft.secret_ref,
            assigned_roles: draft.assigned_roles,
        })
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    #[must_use]
    pub const fn kind(&self) -> ProviderProfileKind {
        self.kind
    }

    #[must_use]
    pub const fn enabled(&self) -> bool {
        self.enabled
    }

    #[must_use]
    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    #[must_use]
    pub fn endpoint(&self) -> Option<&str> {
        self.endpoint.as_deref()
    }

    #[must_use]
    pub fn model_path(&self) -> Option<&str> {
        self.model_path.as_deref()
    }

    #[must_use]
    pub fn secret_ref(&self) -> Option<&str> {
        self.secret_ref.as_deref()
    }

    #[must_use]
    pub fn assigned_roles(&self) -> &[String] {
        &self.assigned_roles
    }
}

fn normalize_roles(roles: &mut Vec<String>) -> Result<(), CoreError> {
    let mut normalized = Vec::with_capacity(roles.len());
    for role in roles.drain(..) {
        let role = role.trim().to_lowercase();
        if !ALLOWED_ROLES.contains(&role.as_str()) {
            return Err(CoreError::InvalidInput("provider role is unsupported"));
        }
        if !normalized.contains(&role) {
            normalized.push(role);
        }
    }
    *roles = normalized;
    Ok(())
}

fn validate_identifier(value: &str, field: &'static str) -> Result<(), CoreError> {
    if value.is_empty() {
        return Err(CoreError::InvalidInput("provider id is blank"));
    }
    if value.len() > MAX_ID_LENGTH {
        return Err(CoreError::InvalidInput("provider id is too long"));
    }
    if !value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(CoreError::InvalidInput(match field {
            "provider id" => "provider id contains unsupported characters",
            _ => "identifier contains unsupported characters",
        }));
    }
    Ok(())
}

fn validate_required_text(
    value: &str,
    max_length: usize,
    blank_message: &'static str,
    long_message: &'static str,
) -> Result<(), CoreError> {
    if value.is_empty() {
        return Err(CoreError::InvalidInput(blank_message));
    }
    if value.len() > max_length {
        return Err(CoreError::InvalidInput(long_message));
    }
    Ok(())
}

fn validate_optional_length(
    value: Option<&str>,
    max_length: usize,
    message: &'static str,
) -> Result<(), CoreError> {
    if value.is_some_and(|value| value.len() > max_length) {
        return Err(CoreError::InvalidInput(message));
    }
    Ok(())
}

fn validate_local_model(draft: &ProviderProfileDraft) -> Result<(), CoreError> {
    if draft.model_path.is_none() {
        return Err(CoreError::InvalidInput("local model path is required"));
    }
    if draft.endpoint.is_some() {
        return Err(CoreError::InvalidInput(
            "local model must not define a remote endpoint",
        ));
    }
    if draft.secret_ref.is_some() {
        return Err(CoreError::InvalidInput(
            "local model must not reference an API secret",
        ));
    }
    Ok(())
}

fn validate_remote_api(draft: &ProviderProfileDraft) -> Result<(), CoreError> {
    if draft.model_path.is_some() {
        return Err(CoreError::InvalidInput(
            "remote provider must not define a local model path",
        ));
    }
    let endpoint = draft
        .endpoint
        .as_deref()
        .ok_or(CoreError::InvalidInput("remote endpoint is required"))?;
    if endpoint.len() > MAX_ENDPOINT_LENGTH {
        return Err(CoreError::InvalidInput("remote endpoint is too long"));
    }
    validate_remote_endpoint(endpoint)
}

fn validate_remote_endpoint(endpoint: &str) -> Result<(), CoreError> {
    let url = Url::parse(endpoint)
        .map_err(|_| CoreError::InvalidInput("remote endpoint is not a valid URL"))?;
    if url.host().is_none() || url.cannot_be_a_base() {
        return Err(CoreError::InvalidInput(
            "remote endpoint must contain a host",
        ));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(CoreError::InvalidInput(
            "remote endpoint must not contain credentials",
        ));
    }
    if url.fragment().is_some() {
        return Err(CoreError::InvalidInput(
            "remote endpoint must not contain a fragment",
        ));
    }

    match url.scheme() {
        "https" => Ok(()),
        "http" if is_loopback_host(url.host().as_ref()) => Ok(()),
        "http" => Err(CoreError::InvalidInput("remote endpoint must use HTTPS")),
        _ => Err(CoreError::InvalidInput(
            "remote endpoint must use HTTP or HTTPS",
        )),
    }
}

fn is_loopback_host(host: Option<&Host<&str>>) -> bool {
    match host {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => IpAddr::V4(*address).is_loopback(),
        Some(Host::Ipv6(address)) => IpAddr::V6(*address).is_loopback(),
        None => false,
    }
}

fn trim_optional(value: &mut Option<String>) {
    if let Some(inner) = value {
        *inner = inner.trim().to_owned();
        if inner.is_empty() {
            *value = None;
        }
    }
}
