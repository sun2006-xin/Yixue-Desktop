use std::{
    collections::BTreeMap,
    fmt::Write as _,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::json;
use sha2::{Digest, Sha256};
use yixue_core::{
    CTranslate2Provider, CTranslate2Runtime, CancellationToken, CoreError, Language,
    TranslationProvider, TranslationRequest, validate_model_package,
};

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn create() -> Self {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be valid")
            .as_nanos();
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-ctranslate2-providers")
            .join(format!("package-{suffix}"));
        fs::create_dir_all(&path).expect("test directory should be created");
        Self(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("test directory should be removed");
    }
}

fn write_package(root: &Path) {
    let files = [
        ("config.json", b"{}".as_slice()),
        ("model.bin", b"model".as_slice()),
        ("source_vocabulary.json", b"[]".as_slice()),
        ("target_vocabulary.json", b"[]".as_slice()),
        ("source.spm", b"source tokenizer".as_slice()),
        ("target.spm", b"target tokenizer".as_slice()),
    ];
    let mut hashes = BTreeMap::new();
    for (name, content) in files {
        fs::write(root.join(name), content).expect("fixture should be written");
        let mut hash = String::with_capacity(64);
        for byte in Sha256::digest(content) {
            write!(&mut hash, "{byte:02x}").expect("hash should format");
        }
        hashes.insert(name, hash);
    }
    fs::write(
        root.join("yixue-model.json"),
        serde_json::to_vec(&json!({
            "schema_version": 1,
            "package_id": "yixue.opus-en-zh.int8",
            "display_name": "译学英中轻量模型",
            "engine": "ctranslate2",
            "source_language": "english",
            "target_language": "chinese",
            "base_model": "Helsinki-NLP/opus-mt-en-zh",
            "license": "Apache-2.0",
            "files": hashes,
        }))
        .expect("manifest should serialize"),
    )
    .expect("manifest should be written");
}

struct RecordingRuntime {
    calls: Mutex<Vec<String>>,
    output: &'static str,
}

impl CTranslate2Runtime for RecordingRuntime {
    fn translate(
        &self,
        _package: &yixue_core::VerifiedModelPackage,
        source_text: &str,
        _cancellation: &CancellationToken,
    ) -> Result<String, CoreError> {
        self.calls
            .lock()
            .expect("calls lock should be available")
            .push(source_text.to_owned());
        Ok(self.output.to_owned())
    }
}

fn provider(output: &'static str) -> (TestDirectory, CTranslate2Provider, Arc<RecordingRuntime>) {
    let directory = TestDirectory::create();
    write_package(&directory.0);
    let package = validate_model_package(&directory.0).expect("package should validate");
    let runtime = Arc::new(RecordingRuntime {
        calls: Mutex::new(Vec::new()),
        output,
    });
    let provider = CTranslate2Provider::new(package, runtime.clone())
        .expect("provider metadata should be valid");
    (directory, provider, runtime)
}

#[test]
fn local_provider_routes_verified_text_to_the_runtime() {
    let (_directory, provider, runtime) = provider("你好，世界！");
    let request = TranslationRequest::new(
        "local-1",
        Language::English,
        Language::Chinese,
        "Hello, world!",
    )
    .expect("request should validate");

    let result = provider
        .translate(&request, &CancellationToken::new())
        .expect("translation should succeed");

    assert_eq!(result.text(), "你好，世界！");
    assert_eq!(result.provider_id(), "yixue.opus-en-zh.int8");
    assert_eq!(
        *runtime.calls.lock().expect("calls should be readable"),
        ["Hello, world!"]
    );
}

#[test]
fn local_provider_rejects_an_unsupported_language_direction() {
    let (_directory, provider, runtime) = provider("unused");
    let request = TranslationRequest::new("local-2", Language::Chinese, Language::English, "你好")
        .expect("request should validate");

    let error = provider
        .translate(&request, &CancellationToken::new())
        .expect_err("wrong direction should fail");

    assert_eq!(error, CoreError::UnsupportedLanguagePair);
    assert!(
        runtime
            .calls
            .lock()
            .expect("calls should be readable")
            .is_empty()
    );
}

#[test]
fn local_provider_does_not_enter_the_runtime_after_cancellation() {
    let (_directory, provider, runtime) = provider("unused");
    let request = TranslationRequest::new("local-3", Language::English, Language::Chinese, "Hello")
        .expect("request should validate");
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    let error = provider
        .translate(&request, &cancellation)
        .expect_err("cancelled translation should fail");

    assert_eq!(error, CoreError::Cancelled);
    assert!(
        runtime
            .calls
            .lock()
            .expect("calls should be readable")
            .is_empty()
    );
}

#[test]
fn local_provider_rejects_a_blank_runtime_result() {
    let (_directory, provider, _) = provider("   ");
    let request = TranslationRequest::new("local-4", Language::English, Language::Chinese, "Hello")
        .expect("request should validate");

    let error = provider
        .translate(&request, &CancellationToken::new())
        .expect_err("blank output should fail");

    assert_eq!(error, CoreError::InvalidProviderOutput);
}
