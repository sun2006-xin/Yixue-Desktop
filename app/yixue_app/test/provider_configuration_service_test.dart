import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/provider_configuration_service.dart';
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

class _MemoryAppCore implements AppCore {
  final profiles = <ProviderProfileData>[];
  bool failSave = false;

  @override
  void dispose() {}

  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 1, coreVersion: 'test');

  @override
  void recordActivity(ActivityEventData activity) {}

  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) =>
      const HomeSnapshotData(
        learningMinutes: 0,
        readingPages: 0,
        masteredWords: 0,
        completedExercises: 0,
        recent: [],
      );

  @override
  List<ProviderProfileData> listProviderProfiles() =>
      List.unmodifiable(profiles);

  @override
  void saveProviderProfile(ProviderProfileData profile) {
    if (failSave) {
      throw const CoreBridgeException('storage_error', 'save failed');
    }
    profiles
      ..removeWhere((existing) => existing.id == profile.id)
      ..add(profile);
  }

  @override
  void deleteProviderProfile(String providerId) {
    profiles.removeWhere((profile) => profile.id == providerId);
  }
}

void main() {
  test('local model is saved disabled until its package is verified', () {
    final core = _MemoryAppCore();
    final service = ProviderConfigurationService(
      core,
      ProviderSecretStore(_MemorySecretBackend()),
    );

    service.saveLocalProvider(
      id: 'local.opus-en-zh',
      displayName: '本地英汉基础模型',
      modelId: 'opus-mt-en-zh',
      modelPath: r'D:\models\opus-mt-en-zh',
    );

    expect(core.profiles, hasLength(1));
    expect(core.profiles.single.kind, ProviderProfileKind.localModel);
    expect(core.profiles.single.enabled, isFalse);
    expect(core.profiles.single.secretRef, isNull);
    expect(core.profiles.single.endpoint, isNull);
    expect(core.profiles.single.modelPath, r'D:\models\opus-mt-en-zh');
  });

  test(
    'remote provider stores secret separately from profile metadata',
    () async {
      final core = _MemoryAppCore();
      final backend = _MemorySecretBackend();
      final service = ProviderConfigurationService(
        core,
        ProviderSecretStore(backend),
      );

      await service.saveRemoteProvider(
        id: 'remote.example',
        displayName: 'Example API',
        endpoint: 'https://api.example.com/v1',
        modelId: 'translation-model',
        apiKey: 'private-key-value',
      );

      expect(core.profiles, hasLength(1));
      expect(
        core.profiles.single.secretRef,
        'yixue.provider.remote.example.api-key',
      );
      expect(
        core.profiles.single.toJson().toString(),
        isNot(contains('private-key-value')),
      );
      expect(backend.values.values, contains('private-key-value'));
    },
  );

  test('local compatible provider may omit an API key', () async {
    final core = _MemoryAppCore();
    final backend = _MemorySecretBackend();
    final service = ProviderConfigurationService(
      core,
      ProviderSecretStore(backend),
    );

    await service.saveRemoteProvider(
      id: 'local.qwen',
      displayName: '本地千问',
      endpoint: 'http://127.0.0.1:11435/v1',
      modelId: 'qwen3.5:4b',
    );

    expect(core.profiles.single.endpoint, 'http://127.0.0.1:11435/v1');
    expect(core.profiles.single.enabled, isFalse);
    expect(core.profiles.single.assignedRoles, isEmpty);
    expect(core.profiles.single.secretRef, isNull);
    expect(backend.values, isEmpty);
  });

  test('a discovered compatible endpoint can be saved without activating it',
      () async {
    final core = _MemoryAppCore();
    final service = ProviderConfigurationService(
      core,
      ProviderSecretStore(_MemorySecretBackend()),
    );

    await service.saveRemoteProvider(
      id: 'local.qwen',
      displayName: '本地千问',
      endpoint: 'http://127.0.0.1:11434/api',
      modelId: 'qwen3.5:4b',
      enabled: false,
      assignedRoles: const {},
    );

    expect(core.profiles.single.enabled, isFalse);
    expect(core.profiles.single.assignedRoles, isEmpty);
  });

  test(
    'remote provider still requires a key when the endpoint is not local',
    () async {
      final core = _MemoryAppCore();
      final service = ProviderConfigurationService(
        core,
        ProviderSecretStore(_MemorySecretBackend()),
      );

      await expectLater(
        service.saveRemoteProvider(
          id: 'remote.example',
          displayName: '远程服务',
          endpoint: 'https://api.example.com/v1',
          modelId: 'translator-v1',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(core.profiles, isEmpty);
    },
  );

  test('metadata failure rolls back the newly stored API key', () async {
    final core = _MemoryAppCore()..failSave = true;
    final backend = _MemorySecretBackend();
    final service = ProviderConfigurationService(
      core,
      ProviderSecretStore(backend),
    );

    await expectLater(
      service.saveRemoteProvider(
        id: 'remote.example',
        displayName: 'Example API',
        endpoint: 'https://api.example.com/v1',
        modelId: 'translation-model',
        apiKey: 'private-key-value',
      ),
      throwsA(isA<CoreBridgeException>()),
    );

    expect(backend.values, isEmpty);
  });

  test('deleting a remote provider removes metadata and its secret', () async {
    final core = _MemoryAppCore();
    final backend = _MemorySecretBackend();
    final service = ProviderConfigurationService(
      core,
      ProviderSecretStore(backend),
    );

    await service.saveRemoteProvider(
      id: 'remote.example',
      displayName: 'Example API',
      endpoint: 'https://api.example.com/v1',
      modelId: 'translation-model',
      apiKey: 'private-key-value',
    );
    await service.deleteProvider('remote.example');

    expect(core.profiles, isEmpty);
    expect(backend.values, isEmpty);
  });

  test(
    'editing a remote provider keeps its key when the field is blank',
    () async {
      final core = _MemoryAppCore();
      final backend = _MemorySecretBackend();
      final service = ProviderConfigurationService(
        core,
        ProviderSecretStore(backend),
      );

      await service.saveRemoteProvider(
        id: 'remote.example',
        displayName: 'Example API',
        endpoint: 'https://api.example.com/v1',
        modelId: 'old-model',
        apiKey: 'old-key',
      );
      await service.updateRemoteProvider(
        existing: core.profiles.single,
        displayName: 'Updated API',
        endpoint: 'https://api.example.com/v2',
        modelId: 'new-model',
      );

      expect(core.profiles.single.displayName, 'Updated API');
      expect(core.profiles.single.modelId, 'new-model');
      expect(backend.values.values, contains('old-key'));
    },
  );

  test(
    'editing a keyless local provider cannot move to a public endpoint',
    () async {
      final core = _MemoryAppCore();
      final backend = _MemorySecretBackend();
      final service = ProviderConfigurationService(
        core,
        ProviderSecretStore(backend),
      );

      await service.saveRemoteProvider(
        id: 'local.qwen',
        displayName: '本地千问',
        endpoint: 'http://127.0.0.1:11434/api',
        modelId: 'qwen3.5:4b',
      );
      final existing = core.profiles.single;

      await expectLater(
        service.updateRemoteProvider(
          existing: existing,
          displayName: '远程千问',
          endpoint: 'https://api.example.com/v1',
          modelId: 'qwen3.5:4b',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(core.profiles.single.endpoint, 'http://127.0.0.1:11434/api');
      expect(core.profiles.single.displayName, '本地千问');
      expect(backend.values, isEmpty);
    },
  );
}
