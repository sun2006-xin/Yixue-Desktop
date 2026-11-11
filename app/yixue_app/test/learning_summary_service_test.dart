import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/provider_secret_store.dart';

class _MemorySecrets implements SecretBackend {
  final values = <String, String>{};

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FakeCore implements AppCore {
  _FakeCore(this.profiles);

  final List<ProviderProfileData> profiles;

  @override
  void deleteProviderProfile(String providerId) {}

  @override
  void dispose() {}

  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 1, coreVersion: 'test');

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
  List<ProviderProfileData> listProviderProfiles() => profiles;

  @override
  void recordActivity(ActivityEventData activity) {}

  @override
  void saveProviderProfile(ProviderProfileData profile) {}
}

const _publicSummary = ProviderProfileData(
  id: 'public-summary',
  displayName: '远程总结',
  kind: ProviderProfileKind.remoteApi,
  enabled: true,
  modelId: 'summary-v1',
  endpoint: 'https://summary.example.com/v1',
  assignedRoles: {ModelRole.understanding},
);

const _localSummary = ProviderProfileData(
  id: 'local-summary',
  displayName: '本地千问总结',
  kind: ProviderProfileKind.remoteApi,
  enabled: true,
  modelId: 'qwen3.5:4b',
  endpoint: 'http://127.0.0.1:11435/v1',
  assignedRoles: {ModelRole.understanding},
);

const _nativeLocalSummary = ProviderProfileData(
  id: 'native-local-summary',
  displayName: '原生本地理解模型',
  kind: ProviderProfileKind.localModel,
  enabled: true,
  modelId: 'native-qwen',
  modelPath: r'D:\models\native-qwen',
  assignedRoles: {ModelRole.understanding},
);

void main() {
  test('prefers an enabled loopback understanding provider', () {
    final selected = LearningSummaryService.selectProvider([
      _publicSummary,
      const ProviderProfileData(
        id: 'translation-only',
        displayName: '仅翻译',
        kind: ProviderProfileKind.remoteApi,
        enabled: true,
        modelId: 'translator',
        endpoint: 'http://127.0.0.1:11435/v1',
        assignedRoles: {ModelRole.translation},
      ),
      _localSummary,
    ]);

    expect(selected?.id, 'local-summary');
  });

  test('requires explicit understanding assignment', () async {
    final service = LearningSummaryService(
      coreFactory: () => _FakeCore(const []),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    await expectLater(
      service.summarize('A small habit can change the way we learn.'),
      throwsA(
        isA<LearningSummaryException>().having(
          (error) => error.code,
          'code',
          'no_summary_model',
        ),
      ),
    );
  });

  test('uses a loopback compatible API understanding provider', () async {
    late http.Request captured;
    final service = LearningSummaryService(
      coreFactory: () => _FakeCore([_localSummary, _publicSummary]),
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"主旨：持续学习。"}}]}'),
          200,
        );
      }),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    expect(
      await service.summarize('A small habit can change the way we learn.'),
      '主旨：持续学习。',
    );
    expect(
      captured.url.toString(),
      'http://127.0.0.1:11435/v1/chat/completions',
    );
    expect(captured.body, contains('qwen3.5:4b'));
  });

  test(
    'generates the requested bilingual sentence count on explicit call',
    () async {
      late http.Request captured;
      const responseContent = '''
{"sentences":[
  {"title":"课堂提问","chinese":"我可以再问一个问题吗？","english":"May I ask one more question?"},
  {"title":"学习计划","chinese":"我今晚会复习这节课的笔记。","english":"I will review the notes from this lesson tonight."},
  {"title":"小组讨论","chinese":"我们可以先比较这两种方法。","english":"We can compare these two methods first."}
]}
''';
      final service = LearningSummaryService(
        coreFactory: () =>
            _FakeCore([_nativeLocalSummary, _localSummary, _publicSummary]),
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': responseContent},
                  },
                ],
              }),
            ),
            200,
          );
        }),
        secrets: ProviderSecretStore(_MemorySecrets()),
      );

      final exercises = await service.generateSentenceExercises(
        scenario: '学习与课堂',
        difficulty: 2,
        count: 3,
      );

      expect(exercises, hasLength(3));
      expect(exercises.first.title, '课堂提问');
      expect(exercises.first.chineseText, '我可以再问一个问题吗？');
      expect(exercises.first.englishText, 'May I ask one more question?');
      expect(
        captured.url.toString(),
        'http://127.0.0.1:11435/v1/chat/completions',
      );
      final request = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(request['model'], 'qwen3.5:4b');
      final messages = request['messages'] as List<dynamic>;
      final userMessage = messages.last as Map<String, dynamic>;
      expect(userMessage['content'], contains('学习与课堂'));
      expect(userMessage['content'], contains('3'));
      expect(userMessage['content'], contains('2'));
    },
  );

  test('does not route generation to a native local model profile', () async {
    var requestCount = 0;
    final service = LearningSummaryService(
      coreFactory: () => _FakeCore([_nativeLocalSummary]),
      httpClient: MockClient((_) async {
        requestCount++;
        return http.Response('{}', 200);
      }),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    await expectLater(
      service.generateSentenceExercises(
        scenario: '日常交流',
        difficulty: 1,
        count: 1,
      ),
      throwsA(
        isA<LearningSummaryException>().having(
          (error) => error.code,
          'code',
          'no_summary_model',
        ),
      ),
    );
    expect(requestCount, 0);
  });

  test('rejects malformed or incomplete AI sentence sets', () async {
    final service = LearningSummaryService(
      coreFactory: () => _FakeCore([_localSummary]),
      httpClient: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': '{"sentences":[{"title":"只有一题","chinese":"你好","english":"Hello"}]}',
                  },
                },
              ],
            }),
          ),
          200,
        ),
      ),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    await expectLater(
      service.generateSentenceExercises(
        scenario: '日常交流',
        difficulty: 1,
        count: 3,
      ),
      throwsA(
        isA<LearningSummaryException>().having(
          (error) => error.code,
          'code',
          'invalid_sentence_response',
        ),
      ),
    );
  });

  test('rejects fenced, empty-field, and extra-field sentence JSON', () async {
    for (final content in [
      '```json\n{"sentences":[]}\n```',
      '{"sentences":[{"title":"","chinese":"你好","english":"Hello"}]}',
      '{"sentences":[{"title":"问候","chinese":"你好","english":"Hello","note":"extra"}]}',
    ]) {
      final service = LearningSummaryService(
        coreFactory: () => _FakeCore([_localSummary]),
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': content},
                  },
                ],
              }),
            ),
            200,
          ),
        ),
        secrets: ProviderSecretStore(_MemorySecrets()),
      );

      await expectLater(
        service.generateSentenceExercises(
          scenario: '日常交流',
          difficulty: 1,
          count: 1,
        ),
        throwsA(
          isA<LearningSummaryException>().having(
            (error) => error.code,
            'code',
            'invalid_sentence_response',
          ),
        ),
      );
      service.close();
    }
  });

  test(
    'does not use a translation-only provider to generate sentences',
    () async {
      final service = LearningSummaryService(
        coreFactory: () => _FakeCore([
          const ProviderProfileData(
            id: 'translation-only',
            displayName: '仅翻译',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'translator',
            endpoint: 'http://127.0.0.1:11435/v1',
            assignedRoles: {ModelRole.translation},
          ),
        ]),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        secrets: ProviderSecretStore(_MemorySecrets()),
      );

      await expectLater(
        service.generateSentenceExercises(
          scenario: '日常交流',
          difficulty: 1,
          count: 1,
        ),
        throwsA(
          isA<LearningSummaryException>().having(
            (error) => error.code,
            'code',
            'no_summary_model',
          ),
        ),
      );
    },
  );
}
