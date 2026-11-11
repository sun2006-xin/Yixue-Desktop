//! Shared domain core for Yixue Assistant.

mod activity;
mod cancellation;
mod completed_translation;
mod content_source;
mod ctranslate2_provider;
mod dictionary;
mod domain;
mod error;
mod model_catalog;
mod model_package;
mod process_ctranslate2_runtime;
mod provider;
mod provider_profile;
mod storage;
mod translation_annotation;
mod translation_benchmark;
mod translation_origin;
mod word_annotation;

pub use activity::{
    ActivityEvent, ActivityEventDraft, ActivityKind, HomeMetricData, HomeSnapshot,
    HomeWorkbenchSnapshot, HomeWorkbenchSummary,
};
pub use cancellation::CancellationToken;
pub use completed_translation::{
    CompletedTranslation, CompletedTranslationDraft, ScreenshotTranslationOcrBlock,
    ScreenshotTranslationOcrLayout,
};
pub use content_source::{ContentSource, ContentSourceDraft, ContentSourceVersion};
pub use ctranslate2_provider::{CTranslate2Provider, CTranslate2Runtime};
pub use dictionary::{DictionaryEntry, DictionaryEntryDraft};
pub use domain::{Language, TranslationRequest, TranslationResult};
pub use error::CoreError;
pub use model_catalog::{ModelCatalogEntry, ModelCatalogEntryDraft};
pub use model_package::{ModelPackageError, VerifiedModelPackage, validate_model_package};
pub use process_ctranslate2_runtime::ProcessCTranslate2Runtime;
pub use provider::{
    FakeProvider, LanguagePair, ProviderCapabilities, ProviderKind, ProviderRegistry,
    TranslationProvider,
};
pub use provider_profile::{ProviderProfile, ProviderProfileDraft, ProviderProfileKind};
pub use storage::{
    FavoriteWordPage, FavoriteWordRecord, Storage, StorageHealth, StorageUsageRecord,
    StorageUsageSnapshot,
};
pub use translation_annotation::{TranslationAnnotation, TranslationAnnotationDraft};
pub use translation_benchmark::{
    BenchmarkCategory, TranslationBenchmarkCase, TranslationBenchmarkError,
    TranslationBenchmarkSuite,
};
pub use translation_origin::TranslationOrigin;
pub use word_annotation::{WordAnnotation, WordAnnotationDraft};

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
