use std::{
    collections::BTreeMap,
    fmt::Write as _,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::json;
use sha2::{Digest, Sha256};
use yixue_core::{Language, ModelPackageError, validate_model_package};

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn create() -> Self {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be valid")
            .as_nanos();
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-model-packages")
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

fn sha256(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(64);
    for byte in Sha256::digest(bytes) {
        write!(&mut encoded, "{byte:02x}").expect("writing to a string should succeed");
    }
    encoded
}

fn write_valid_package(root: &Path) {
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
        fs::write(root.join(name), content).expect("fixture file should be written");
        hashes.insert(name, sha256(content));
    }
    let manifest = json!({
        "schema_version": 1,
        "package_id": "yixue.opus-en-zh.int8",
        "display_name": "译学英中轻量模型",
        "engine": "ctranslate2",
        "source_language": "english",
        "target_language": "chinese",
        "base_model": "Helsinki-NLP/opus-mt-en-zh",
        "license": "Apache-2.0",
        "files": hashes,
    });
    fs::write(
        root.join("yixue-model.json"),
        serde_json::to_vec_pretty(&manifest).expect("manifest should serialize"),
    )
    .expect("manifest should be written");
}

fn write_shared_vocabulary_package(root: &Path) {
    let files = [
        ("config.json", b"{}".as_slice()),
        ("model.bin", b"model".as_slice()),
        ("shared_vocabulary.json", b"[]".as_slice()),
        ("source.spm", b"source tokenizer".as_slice()),
        ("target.spm", b"target tokenizer".as_slice()),
    ];
    let mut hashes = BTreeMap::new();
    for (name, content) in files {
        fs::write(root.join(name), content).expect("fixture file should be written");
        hashes.insert(name, sha256(content));
    }
    let manifest = json!({
        "schema_version": 1,
        "package_id": "yixue.opus-en-zh.int8",
        "display_name": "译学英中轻量模型",
        "engine": "ctranslate2",
        "source_language": "english",
        "target_language": "chinese",
        "base_model": "Helsinki-NLP/opus-mt-en-zh",
        "license": "Apache-2.0",
        "files": hashes,
    });
    fs::write(
        root.join("yixue-model.json"),
        serde_json::to_vec_pretty(&manifest).expect("manifest should serialize"),
    )
    .expect("manifest should be written");
}

#[test]
fn valid_ctranslate2_package_reports_verified_metadata() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);

    let package = validate_model_package(&directory.0).expect("package should validate");

    assert_eq!(package.package_id(), "yixue.opus-en-zh.int8");
    assert_eq!(package.source_language(), Language::English);
    assert_eq!(package.target_language(), Language::Chinese);
    assert_eq!(package.license(), "Apache-2.0");
    assert_eq!(package.verified_file_count(), 6);
}

#[test]
fn converted_model_with_shared_vocabulary_is_accepted() {
    let directory = TestDirectory::create();
    write_shared_vocabulary_package(&directory.0);

    let package = validate_model_package(&directory.0)
        .expect("a converted shared-vocabulary model should validate");

    assert_eq!(package.package_id(), "yixue.opus-en-zh.int8");
    assert_eq!(package.verified_file_count(), 5);
}

#[test]
fn package_cannot_mix_shared_and_split_vocabularies() {
    let directory = TestDirectory::create();
    write_shared_vocabulary_package(&directory.0);
    let extra = b"[]";
    fs::write(directory.0.join("source_vocabulary.json"), extra)
        .expect("extra vocabulary should be written");
    let manifest_path = directory.0.join("yixue-model.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).expect("manifest should be readable"))
            .expect("manifest should parse");
    manifest["files"]["source_vocabulary.json"] = json!(sha256(extra));
    fs::write(
        manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("manifest should serialize"),
    )
    .expect("manifest should be rewritten");

    let error =
        validate_model_package(&directory.0).expect_err("ambiguous vocabulary layouts should fail");

    assert!(matches!(
        error,
        ModelPackageError::InvalidMetadata("vocabulary layout")
    ));
}

#[test]
fn package_with_a_changed_model_file_is_rejected() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);
    fs::write(directory.0.join("model.bin"), b"tampered").expect("model fixture should be changed");

    let error = validate_model_package(&directory.0).expect_err("hash mismatch should fail");

    assert!(matches!(error, ModelPackageError::HashMismatch(path) if path == "model.bin"));
}

#[test]
fn manifest_cannot_escape_the_model_directory() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);
    let manifest_path = directory.0.join("yixue-model.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).expect("manifest should be readable"))
            .expect("manifest should parse");
    manifest["files"]["../outside.bin"] = json!(sha256(b"outside"));
    fs::write(
        manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("manifest should serialize"),
    )
    .expect("manifest should be rewritten");

    let error = validate_model_package(&directory.0).expect_err("unsafe path should fail");

    assert!(matches!(error, ModelPackageError::UnsafePath(path) if path == "../outside.bin"));
}

#[test]
fn package_requires_all_ctranslate2_core_files() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);
    fs::remove_file(directory.0.join("target_vocabulary.json"))
        .expect("fixture file should be removed");

    let error = validate_model_package(&directory.0).expect_err("missing file should fail");

    assert!(
        matches!(error, ModelPackageError::MissingFile(path) if path == "target_vocabulary.json")
    );
}

#[test]
fn package_requires_source_and_target_sentencepiece_models() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);
    fs::remove_file(directory.0.join("source.spm"))
        .expect("source tokenizer fixture should be removed");
    let manifest_path = directory.0.join("yixue-model.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).expect("manifest should be readable"))
            .expect("manifest should parse");
    manifest["files"]
        .as_object_mut()
        .expect("files should be an object")
        .remove("source.spm");
    fs::write(
        manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("manifest should serialize"),
    )
    .expect("manifest should be rewritten");

    let error = validate_model_package(&directory.0).expect_err("missing tokenizer should fail");

    assert!(matches!(error, ModelPackageError::MissingFile(path) if path == "source.spm"));
}

#[test]
fn package_rejects_unlisted_executable_files() {
    let directory = TestDirectory::create();
    write_valid_package(&directory.0);
    fs::write(
        directory.0.join("helper.exe"),
        b"not executable in this test",
    )
    .expect("unexpected fixture should be written");

    let error = validate_model_package(&directory.0).expect_err("extra file should fail");

    assert!(matches!(error, ModelPackageError::UnexpectedEntry(path) if path == "helper.exe"));
}
