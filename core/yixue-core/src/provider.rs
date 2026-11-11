use std::{collections::HashMap, sync::Arc};

use serde::{Deserialize, Serialize};

use crate::{CancellationToken, CoreError, Language, TranslationRequest, TranslationResult};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    LocalModel,
    RemoteApi,
    Test,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LanguagePair {
    source: Language,
    target: Language,
}

impl LanguagePair {
    #[must_use]
    pub const fn new(source: Language, target: Language) -> Self {
        Self { source, target }
    }

    #[must_use]
    pub fn matches(self, source: Language, target: Language) -> bool {
        self.source == source && self.target == target
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProviderCapabilities {
    id: String,
    display_name: String,
    kind: ProviderKind,
    offline: bool,
    language_pairs: Vec<LanguagePair>,
}

impl ProviderCapabilities {
    /// Creates validated provider metadata.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] for blank identifiers, blank names, or no pairs.
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
        kind: ProviderKind,
        offline: bool,
        language_pairs: Vec<LanguagePair>,
    ) -> Result<Self, CoreError> {
        let id = id.into();
        let display_name = display_name.into();
        if id.trim().is_empty() {
            return Err(CoreError::InvalidInput("provider id is blank"));
        }
        if display_name.trim().is_empty() {
            return Err(CoreError::InvalidInput("provider name is blank"));
        }
        if language_pairs.is_empty() {
            return Err(CoreError::InvalidInput("provider has no language pairs"));
        }

        Ok(Self {
            id,
            display_name,
            kind,
            offline,
            language_pairs,
        })
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub const fn kind(&self) -> ProviderKind {
        self.kind
    }

    #[must_use]
    pub const fn is_offline(&self) -> bool {
        self.offline
    }

    #[must_use]
    pub fn supports(&self, source: Language, target: Language) -> bool {
        self.language_pairs
            .iter()
            .any(|pair| pair.matches(source, target))
    }
}

pub trait TranslationProvider: Send + Sync {
    fn capabilities(&self) -> &ProviderCapabilities;

    fn id(&self) -> &str {
        self.capabilities().id()
    }

    /// Translates one validated request.
    ///
    /// # Errors
    ///
    /// Returns a provider-specific [`CoreError`] or [`CoreError::Cancelled`].
    fn translate(
        &self,
        request: &TranslationRequest,
        cancellation: &CancellationToken,
    ) -> Result<TranslationResult, CoreError>;
}

#[derive(Default)]
pub struct ProviderRegistry {
    providers: HashMap<String, Arc<dyn TranslationProvider>>,
}

impl ProviderRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a provider under its runtime identifier.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::DuplicateProvider`] when the identifier already exists.
    pub fn register(&mut self, provider: Arc<dyn TranslationProvider>) -> Result<(), CoreError> {
        let id = provider.id().to_owned();
        if self.providers.contains_key(&id) {
            return Err(CoreError::DuplicateProvider(id));
        }
        self.providers.insert(id, provider);
        Ok(())
    }

    /// Routes a request to one explicitly selected provider.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::ProviderUnavailable`] if the provider is absent, or forwards its error.
    pub fn translate(
        &self,
        provider_id: &str,
        request: &TranslationRequest,
        cancellation: &CancellationToken,
    ) -> Result<TranslationResult, CoreError> {
        let provider = self
            .providers
            .get(provider_id)
            .ok_or_else(|| CoreError::ProviderUnavailable(provider_id.to_owned()))?;
        provider.translate(request, cancellation)
    }
}

pub struct FakeProvider {
    capabilities: ProviderCapabilities,
    translations: HashMap<String, String>,
}

impl FakeProvider {
    #[must_use]
    pub fn from_pairs<const N: usize>(
        capabilities: ProviderCapabilities,
        translations: [(&str, &str); N],
    ) -> Self {
        Self {
            capabilities,
            translations: translations
                .into_iter()
                .map(|(source, target)| (source.to_owned(), target.to_owned()))
                .collect(),
        }
    }

    #[must_use]
    pub const fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }
}

impl TranslationProvider for FakeProvider {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }

    fn translate(
        &self,
        request: &TranslationRequest,
        cancellation: &CancellationToken,
    ) -> Result<TranslationResult, CoreError> {
        cancellation.check()?;
        if !self
            .capabilities
            .supports(request.source_language(), request.target_language())
        {
            return Err(CoreError::UnsupportedLanguagePair);
        }
        let text = self
            .translations
            .get(request.text())
            .ok_or(CoreError::InvalidInput(
                "fake translation is not configured",
            ))?;
        Ok(TranslationResult::new(
            request.id(),
            self.id(),
            text.to_owned(),
        ))
    }
}
