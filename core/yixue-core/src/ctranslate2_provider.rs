use std::sync::Arc;

use crate::{
    CancellationToken, CoreError, LanguagePair, ProviderCapabilities, ProviderKind,
    TranslationProvider, TranslationRequest, TranslationResult, VerifiedModelPackage,
};

/// Safe core-side boundary implemented by the platform `CTranslate2` runtime.
pub trait CTranslate2Runtime: Send + Sync {
    /// Runs tokenization, `CTranslate2` inference, and detokenization.
    ///
    /// # Errors
    ///
    /// Returns a stable [`CoreError`] category without exposing model text or
    /// low-level runtime details to the user interface.
    fn translate(
        &self,
        package: &VerifiedModelPackage,
        source_text: &str,
        cancellation: &CancellationToken,
    ) -> Result<String, CoreError>;
}

/// A local-only translation provider backed by a previously verified package.
pub struct CTranslate2Provider {
    package: VerifiedModelPackage,
    capabilities: ProviderCapabilities,
    runtime: Arc<dyn CTranslate2Runtime>,
}

impl CTranslate2Provider {
    /// Creates a provider from a verified model package.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::InvalidInput`] only if verified package metadata
    /// cannot form provider capabilities.
    pub fn new(
        package: VerifiedModelPackage,
        runtime: Arc<dyn CTranslate2Runtime>,
    ) -> Result<Self, CoreError> {
        let capabilities = ProviderCapabilities::new(
            package.package_id(),
            package.display_name(),
            ProviderKind::LocalModel,
            true,
            vec![LanguagePair::new(
                package.source_language(),
                package.target_language(),
            )],
        )?;
        Ok(Self {
            package,
            capabilities,
            runtime,
        })
    }

    #[must_use]
    pub const fn package(&self) -> &VerifiedModelPackage {
        &self.package
    }
}

impl TranslationProvider for CTranslate2Provider {
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
        let translated = self
            .runtime
            .translate(&self.package, request.text(), cancellation)?;
        cancellation.check()?;
        if translated.trim().is_empty() {
            return Err(CoreError::InvalidProviderOutput);
        }
        Ok(TranslationResult::new(
            request.id(),
            self.capabilities.id(),
            translated,
        ))
    }
}
