use std::{path::PathBuf, sync::Arc};

use yixue_core::{
    CTranslate2Provider, CancellationToken, Language, ProcessCTranslate2Runtime,
    TranslationProvider, TranslationRequest, validate_model_package,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let worker = PathBuf::from(arguments.next().ok_or("worker path is required")?);
    let model = PathBuf::from(arguments.next().ok_or("model path is required")?);
    let text = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("UTF-8 source text is required")?;

    let package = validate_model_package(model)?;
    let runtime = Arc::new(ProcessCTranslate2Runtime::new(worker)?);
    let provider = CTranslate2Provider::new(package, runtime)?;
    let request = TranslationRequest::new(
        "local-worker-smoke",
        Language::English,
        Language::Chinese,
        text,
    )?;
    let result = provider.translate(&request, &CancellationToken::new())?;
    println!("TRANSLATION={}", result.text());
    Ok(())
}
