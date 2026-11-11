import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecretBackend {
  Future<void> write(String key, String value);

  Future<String?> read(String key);

  Future<bool> containsKey(String key);

  Future<void> delete(String key);
}

class FlutterSecureSecretBackend implements SecretBackend {
  const FlutterSecureSecretBackend([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class ProviderSecretStore {
  ProviderSecretStore(this._backend);

  factory ProviderSecretStore.platform() =>
      ProviderSecretStore(const FlutterSecureSecretBackend());

  static final _validProviderId = RegExp(r'^[A-Za-z0-9._-]{1,96}$');
  static const _maxApiKeyLength = 8192;

  final SecretBackend _backend;

  Future<String> saveApiKey(String providerId, String apiKey) async {
    final reference = _referenceFor(providerId);
    final normalizedKey = apiKey.trim();
    if (normalizedKey.isEmpty) {
      throw const FormatException('API key is blank');
    }
    if (normalizedKey.length > _maxApiKeyLength) {
      throw const FormatException('API key is too long');
    }

    await _backend.write(reference, normalizedKey);
    return reference;
  }

  Future<bool> hasApiKey(String providerId) =>
      _backend.containsKey(_referenceFor(providerId));

  Future<String> resolveApiKey(String providerId) async {
    final apiKey = await _backend.read(_referenceFor(providerId));
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw const ProviderCredentialException('missing_credential');
    }
    return apiKey;
  }

  Future<void> deleteApiKey(String providerId) =>
      _backend.delete(_referenceFor(providerId));

  static String _referenceFor(String providerId) {
    if (!_validProviderId.hasMatch(providerId)) {
      throw const FormatException('provider id is invalid');
    }
    return 'yixue.provider.$providerId.api-key';
  }
}

final class ProviderCredentialException implements Exception {
  const ProviderCredentialException(this.code);

  final String code;

  @override
  String toString() => 'ProviderCredentialException($code)';
}
