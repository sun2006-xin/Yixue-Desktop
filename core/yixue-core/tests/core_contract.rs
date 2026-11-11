use yixue_core::{
    CancellationToken, CoreError, Language, LanguagePair, ProviderCapabilities, ProviderKind,
    TranslationProvider, TranslationRequest, TranslationResult,
};

struct EchoProvider {
    capabilities: ProviderCapabilities,
}

impl EchoProvider {
    fn new() -> Self {
        Self {
            capabilities: ProviderCapabilities::new(
                "test.echo",
                "Echo provider",
                ProviderKind::Test,
                true,
                vec![LanguagePair::new(Language::English, Language::Chinese)],
            )
            .expect("capabilities should be valid"),
        }
    }
}

impl TranslationProvider for EchoProvider {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }

    fn translate(
        &self,
        request: &TranslationRequest,
        cancellation: &CancellationToken,
    ) -> Result<TranslationResult, CoreError> {
        cancellation.check()?;
        Ok(TranslationResult::new(
            request.id().to_owned(),
            self.id(),
            request.text().to_owned(),
        ))
    }
}

#[test]
fn translation_request_rejects_blank_text() {
    let result = TranslationRequest::new("req-1", Language::English, Language::Chinese, "  ");

    assert_eq!(
        result.unwrap_err(),
        CoreError::InvalidInput("text is blank")
    );
}

#[test]
fn cancellation_is_shared_across_clones() {
    let token = CancellationToken::new();
    let worker_token = token.clone();

    token.cancel();

    assert!(worker_token.is_cancelled());
    assert_eq!(worker_token.check(), Err(CoreError::Cancelled));
}

#[test]
fn provider_translates_a_valid_request() {
    let request = TranslationRequest::new(
        "req-2",
        Language::English,
        Language::Chinese,
        "An apple a day.",
    )
    .expect("request should be valid");

    let result = EchoProvider::new()
        .translate(&request, &CancellationToken::new())
        .expect("provider should translate");

    assert_eq!(result.request_id(), "req-2");
    assert_eq!(result.provider_id(), "test.echo");
    assert_eq!(result.text(), "An apple a day.");
}

#[test]
fn provider_stops_before_work_when_cancelled() {
    let request = TranslationRequest::new(
        "req-3",
        Language::English,
        Language::Chinese,
        "Cancelled work",
    )
    .expect("request should be valid");
    let token = CancellationToken::new();
    token.cancel();

    let result = EchoProvider::new().translate(&request, &token);

    assert_eq!(result, Err(CoreError::Cancelled));
}
