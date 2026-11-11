use thiserror::Error;

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum CoreError {
    #[error("invalid input: {0}")]
    InvalidInput(&'static str),
    #[error("operation cancelled")]
    Cancelled,
    #[error("provider unavailable: {0}")]
    ProviderUnavailable(String),
    #[error("provider already registered: {0}")]
    DuplicateProvider(String),
    #[error("unsupported language pair")]
    UnsupportedLanguagePair,
    #[error("provider returned invalid output")]
    InvalidProviderOutput,
    #[error("storage error: {0}")]
    Storage(String),
}
