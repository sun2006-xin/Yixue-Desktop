use std::sync::Arc;

use yixue_core::{
    CancellationToken, CoreError, FakeProvider, Language, LanguagePair, ProviderCapabilities,
    ProviderKind, ProviderRegistry, TranslationRequest,
};

fn fake_provider(id: &str) -> FakeProvider {
    let capabilities = ProviderCapabilities::new(
        id,
        "Offline test provider",
        ProviderKind::LocalModel,
        true,
        vec![LanguagePair::new(Language::English, Language::Chinese)],
    )
    .expect("capabilities should be valid");

    FakeProvider::from_pairs(capabilities, [("apple", "苹果")])
}

#[test]
fn registry_routes_to_a_runtime_provider_id() {
    let mut registry = ProviderRegistry::new();
    registry
        .register(Arc::new(fake_provider("user.local.m2m100")))
        .expect("provider should register");
    let request = TranslationRequest::new(
        "req-registry-1",
        Language::English,
        Language::Chinese,
        "apple",
    )
    .expect("request should be valid");

    let result = registry
        .translate("user.local.m2m100", &request, &CancellationToken::new())
        .expect("registered provider should translate");

    assert_eq!(result.text(), "苹果");
    assert_eq!(result.provider_id(), "user.local.m2m100");
}

#[test]
fn registry_rejects_duplicate_provider_ids() {
    let mut registry = ProviderRegistry::new();
    registry
        .register(Arc::new(fake_provider("duplicate")))
        .expect("first provider should register");

    let result = registry.register(Arc::new(fake_provider("duplicate")));

    assert_eq!(
        result,
        Err(CoreError::DuplicateProvider("duplicate".to_owned()))
    );
}

#[test]
fn registry_reports_missing_providers_without_fallback_network_calls() {
    let registry = ProviderRegistry::new();
    let request = TranslationRequest::new(
        "req-registry-2",
        Language::English,
        Language::Chinese,
        "private text",
    )
    .expect("request should be valid");

    let result = registry.translate("not-configured", &request, &CancellationToken::new());

    assert_eq!(
        result,
        Err(CoreError::ProviderUnavailable("not-configured".to_owned()))
    );
}

#[test]
fn capabilities_expose_offline_status_and_language_pairs() {
    let provider = fake_provider("local.offline");
    let capabilities = provider.capabilities();

    assert!(capabilities.is_offline());
    assert_eq!(capabilities.kind(), ProviderKind::LocalModel);
    assert!(capabilities.supports(Language::English, Language::Chinese));
    assert!(!capabilities.supports(Language::Chinese, Language::English));
}
