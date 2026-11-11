import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/provider_secret_store.dart';

class _MemorySecretBackend implements SecretBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test(
    'API key is stored behind a deterministic non-secret reference',
    () async {
      final backend = _MemorySecretBackend();
      final store = ProviderSecretStore(backend);

      final reference = await store.saveApiKey(
        'remote.openai-compatible',
        '  key-value  ',
      );

      expect(reference, 'yixue.provider.remote.openai-compatible.api-key');
      expect(
        await store.resolveApiKey('remote.openai-compatible'),
        'key-value',
      );
      expect(backend.values, <String, String>{reference: 'key-value'});
      expect(await store.hasApiKey('remote.openai-compatible'), isTrue);
    },
  );

  test('missing API key reports a generic credential error', () async {
    final store = ProviderSecretStore(_MemorySecretBackend());

    await expectLater(
      store.resolveApiKey('remote.missing'),
      throwsA(
        isA<ProviderCredentialException>().having(
          (error) => error.code,
          'code',
          'missing_credential',
        ),
      ),
    );
  });

  test(
    'invalid provider id and blank API key never reach the backend',
    () async {
      final backend = _MemorySecretBackend();
      final store = ProviderSecretStore(backend);

      await expectLater(
        store.saveApiKey('../other-app', 'key-value'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        store.saveApiKey('remote.valid', '   '),
        throwsA(isA<FormatException>()),
      );

      expect(backend.values, isEmpty);
    },
  );

  test('deleting an API key removes only its provider reference', () async {
    final backend = _MemorySecretBackend();
    final store = ProviderSecretStore(backend);
    await store.saveApiKey('remote.first', 'first-key');
    await store.saveApiKey('remote.second', 'second-key');

    await store.deleteApiKey('remote.first');

    expect(await store.hasApiKey('remote.first'), isFalse);
    expect(await store.hasApiKey('remote.second'), isTrue);
  });
}
