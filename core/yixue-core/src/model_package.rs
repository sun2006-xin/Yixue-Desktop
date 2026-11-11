use std::{
    collections::BTreeMap,
    fmt::Write as _,
    fs::{self, File},
    io::{BufReader, Read},
    path::{Component, Path, PathBuf},
};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::Language;

const MANIFEST_NAME: &str = "yixue-model.json";
const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_PACKAGE_BYTES: u64 = 12 * 1024 * 1024 * 1024;
const REQUIRED_CTRANSLATE2_FILES: [&str; 4] =
    ["config.json", "model.bin", "source.spm", "target.spm"];

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ModelPackageError {
    #[error("model package directory is invalid")]
    InvalidDirectory,
    #[error("model package manifest is missing")]
    MissingManifest,
    #[error("model package manifest is too large")]
    ManifestTooLarge,
    #[error("model package manifest is invalid")]
    InvalidManifest,
    #[error("unsupported model package schema: {0}")]
    UnsupportedSchema(u32),
    #[error("unsupported model engine: {0}")]
    UnsupportedEngine(String),
    #[error("invalid model package metadata: {0}")]
    InvalidMetadata(&'static str),
    #[error("model package path is unsafe: {0}")]
    UnsafePath(String),
    #[error("model package file is missing: {0}")]
    MissingFile(String),
    #[error("model package entry is not a regular file: {0}")]
    NotRegularFile(String),
    #[error("model package contains an unexpected entry: {0}")]
    UnexpectedEntry(String),
    #[error("model package file is too large: {0}")]
    FileTooLarge(String),
    #[error("model package is too large")]
    PackageTooLarge,
    #[error("model package hash does not match: {0}")]
    HashMismatch(String),
    #[error("model package could not be read")]
    ReadFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedModelPackage {
    root: PathBuf,
    package_id: String,
    display_name: String,
    source_language: Language,
    target_language: Language,
    base_model: String,
    license: String,
    verified_file_count: usize,
    total_bytes: u64,
}

impl VerifiedModelPackage {
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    #[must_use]
    pub fn package_id(&self) -> &str {
        &self.package_id
    }

    #[must_use]
    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    #[must_use]
    pub const fn source_language(&self) -> Language {
        self.source_language
    }

    #[must_use]
    pub const fn target_language(&self) -> Language {
        self.target_language
    }

    #[must_use]
    pub fn base_model(&self) -> &str {
        &self.base_model
    }

    #[must_use]
    pub fn license(&self) -> &str {
        &self.license
    }

    #[must_use]
    pub const fn verified_file_count(&self) -> usize {
        self.verified_file_count
    }

    #[must_use]
    pub const fn total_bytes(&self) -> u64 {
        self.total_bytes
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelPackageManifest {
    schema_version: u32,
    package_id: String,
    display_name: String,
    engine: String,
    source_language: Language,
    target_language: Language,
    base_model: String,
    license: String,
    files: BTreeMap<String, String>,
}

/// Verifies an inert `CTranslate2` model package without loading model code.
///
/// # Errors
///
/// Returns [`ModelPackageError`] when the package structure, metadata, paths,
/// file sizes, JSON configuration, or SHA-256 digests are invalid.
pub fn validate_model_package(
    package_directory: impl AsRef<Path>,
) -> Result<VerifiedModelPackage, ModelPackageError> {
    let package_directory = package_directory.as_ref();
    let root_metadata =
        fs::symlink_metadata(package_directory).map_err(|_| ModelPackageError::InvalidDirectory)?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(ModelPackageError::InvalidDirectory);
    }
    let root = package_directory
        .canonicalize()
        .map_err(|_| ModelPackageError::InvalidDirectory)?;
    let manifest = read_manifest(&root)?;
    validate_manifest_metadata(&manifest)?;
    validate_closed_directory(&root, &manifest.files)?;

    for required in REQUIRED_CTRANSLATE2_FILES {
        if !manifest.files.contains_key(required) {
            return Err(ModelPackageError::MissingFile(required.to_owned()));
        }
    }
    validate_vocabulary_layout(&manifest.files)?;

    let mut total_bytes = 0_u64;
    for (relative_path, expected_hash) in &manifest.files {
        validate_relative_path(relative_path)?;
        validate_sha256(expected_hash)?;
        let file_path = root.join(relative_path);
        let metadata = fs::symlink_metadata(&file_path)
            .map_err(|_| ModelPackageError::MissingFile(relative_path.clone()))?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(ModelPackageError::NotRegularFile(relative_path.clone()));
        }
        if metadata.len() == 0 || metadata.len() > MAX_FILE_BYTES {
            return Err(ModelPackageError::FileTooLarge(relative_path.clone()));
        }
        total_bytes = total_bytes
            .checked_add(metadata.len())
            .ok_or(ModelPackageError::PackageTooLarge)?;
        if total_bytes > MAX_PACKAGE_BYTES {
            return Err(ModelPackageError::PackageTooLarge);
        }
        if file_sha256(&file_path)? != expected_hash.to_ascii_lowercase() {
            return Err(ModelPackageError::HashMismatch(relative_path.clone()));
        }
    }
    validate_ctranslate2_config(&root.join("config.json"))?;

    Ok(VerifiedModelPackage {
        root,
        package_id: manifest.package_id,
        display_name: manifest.display_name,
        source_language: manifest.source_language,
        target_language: manifest.target_language,
        base_model: manifest.base_model,
        license: manifest.license,
        verified_file_count: manifest.files.len(),
        total_bytes,
    })
}

fn validate_vocabulary_layout(files: &BTreeMap<String, String>) -> Result<(), ModelPackageError> {
    let has_shared = files.contains_key("shared_vocabulary.json");
    let has_source = files.contains_key("source_vocabulary.json");
    let has_target = files.contains_key("target_vocabulary.json");
    match (has_shared, has_source, has_target) {
        (true, false, false) | (false, true, true) => Ok(()),
        (false, true, false) => Err(ModelPackageError::MissingFile(
            "target_vocabulary.json".to_owned(),
        )),
        (false, false, true) => Err(ModelPackageError::MissingFile(
            "source_vocabulary.json".to_owned(),
        )),
        (false, false, false) => Err(ModelPackageError::MissingFile(
            "shared_vocabulary.json".to_owned(),
        )),
        _ => Err(ModelPackageError::InvalidMetadata("vocabulary layout")),
    }
}

fn read_manifest(root: &Path) -> Result<ModelPackageManifest, ModelPackageError> {
    let path = root.join(MANIFEST_NAME);
    let metadata = fs::symlink_metadata(&path).map_err(|_| ModelPackageError::MissingManifest)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(ModelPackageError::MissingManifest);
    }
    if metadata.len() == 0 || metadata.len() > MAX_MANIFEST_BYTES {
        return Err(ModelPackageError::ManifestTooLarge);
    }
    let bytes = fs::read(path).map_err(|_| ModelPackageError::ReadFailed)?;
    serde_json::from_slice(&bytes).map_err(|_| ModelPackageError::InvalidManifest)
}

fn validate_manifest_metadata(manifest: &ModelPackageManifest) -> Result<(), ModelPackageError> {
    if manifest.schema_version != 1 {
        return Err(ModelPackageError::UnsupportedSchema(
            manifest.schema_version,
        ));
    }
    if manifest.engine != "ctranslate2" {
        return Err(ModelPackageError::UnsupportedEngine(
            manifest.engine.clone(),
        ));
    }
    validate_text(&manifest.package_id, 96, "package id")?;
    if !manifest
        .package_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(ModelPackageError::InvalidMetadata("package id"));
    }
    validate_text(&manifest.display_name, 120, "display name")?;
    validate_text(&manifest.base_model, 256, "base model")?;
    validate_text(&manifest.license, 128, "license")?;
    if manifest.source_language == manifest.target_language {
        return Err(ModelPackageError::InvalidMetadata("language pair"));
    }
    if manifest.files.is_empty() || manifest.files.len() > 32 {
        return Err(ModelPackageError::InvalidMetadata("file list"));
    }
    Ok(())
}

fn validate_text(
    value: &str,
    maximum_chars: usize,
    field: &'static str,
) -> Result<(), ModelPackageError> {
    if value.trim().is_empty() || value.chars().count() > maximum_chars {
        return Err(ModelPackageError::InvalidMetadata(field));
    }
    Ok(())
}

fn validate_relative_path(value: &str) -> Result<(), ModelPackageError> {
    let path = Path::new(value);
    let mut components = path.components();
    if value.is_empty()
        || path.is_absolute()
        || !matches!(components.next(), Some(Component::Normal(_)))
        || components.next().is_some()
    {
        return Err(ModelPackageError::UnsafePath(value.to_owned()));
    }
    Ok(())
}

fn validate_closed_directory(
    root: &Path,
    declared_files: &BTreeMap<String, String>,
) -> Result<(), ModelPackageError> {
    let entries = fs::read_dir(root).map_err(|_| ModelPackageError::ReadFailed)?;
    for entry in entries {
        let entry = entry.map_err(|_| ModelPackageError::ReadFailed)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| ModelPackageError::UnexpectedEntry("non-UTF-8 name".to_owned()))?;
        if name == MANIFEST_NAME {
            continue;
        }
        if !declared_files.contains_key(&name) {
            return Err(ModelPackageError::UnexpectedEntry(name));
        }
    }
    Ok(())
}

fn validate_sha256(value: &str) -> Result<(), ModelPackageError> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ModelPackageError::InvalidMetadata("SHA-256"));
    }
    Ok(())
}

fn file_sha256(path: &Path) -> Result<String, ModelPackageError> {
    let file = File::open(path).map_err(|_| ModelPackageError::ReadFailed)?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024].into_boxed_slice();
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|_| ModelPackageError::ReadFailed)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let mut encoded = String::with_capacity(64);
    for byte in hasher.finalize() {
        write!(&mut encoded, "{byte:02x}").map_err(|_| ModelPackageError::ReadFailed)?;
    }
    Ok(encoded)
}

fn validate_ctranslate2_config(path: &Path) -> Result<(), ModelPackageError> {
    let metadata = fs::metadata(path).map_err(|_| ModelPackageError::ReadFailed)?;
    if metadata.len() > MAX_CONFIG_BYTES {
        return Err(ModelPackageError::FileTooLarge("config.json".to_owned()));
    }
    let bytes = fs::read(path).map_err(|_| ModelPackageError::ReadFailed)?;
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| ModelPackageError::InvalidManifest)?;
    if !value.is_object() {
        return Err(ModelPackageError::InvalidManifest);
    }
    Ok(())
}
