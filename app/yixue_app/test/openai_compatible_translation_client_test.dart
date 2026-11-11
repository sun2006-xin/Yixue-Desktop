import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/core/translation_request_options.dart';
import 'package:yixue_app/core/translation_terminology.dart';

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

const _profile = ProviderProfileData(
  id: 'remote.example',
  displayName: 'Example API',
  kind: ProviderProfileKind.remoteApi,
  enabled: true,
  modelId: 'translator-v1',
  endpoint: 'https://api.example.com/v1',
  secretRef: 'yixue.provider.remote.example.api-key',
);

Future<ProviderSecretStore> _savedSecrets(String value) async {
  final store = ProviderSecretStore(_MemorySecrets());
  await store.saveApiKey(_profile.id, value);
  return store;
}

void main() {
  test('sends request and returns translated text', () async {
    late http.Request captured;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object>{
            'choices': <Object>[
              <String, Object>{
                'message': <String, Object>{'content': ' 技术改变生活。 '},
              },
            ],
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      secrets: await _savedSecrets('private-key-value'),
    );

    final result = await translator.translate(
      profile: _profile,
      sourceText: 'Technology changes life.',
    );

    expect(result, '技术改变生活。');
    expect(captured.method, 'POST');
    expect(
      captured.url.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    expect(captured.headers['authorization'], 'Bearer private-key-value');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['model'], 'translator-v1');
    expect(body['messages'], isA<List<dynamic>>());
    expect(captured.body, contains('Technology changes life.'));
  });

  test('sends a learning summary request through the compatible endpoint', () async {
    late http.Request captured;
    final client = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            '{"choices":[{"message":{"content":"主旨：持续练习。"}}]}',
          ),
          200,
        );
      }),
      secrets: await _savedSecrets('private-key-value'),
    );

    final result = await client.summarize(
      profile: _profile,
      title: 'A learning habit',
      sourceText: 'A small habit can change the way we learn.',
    );

    expect(result, '主旨：持续练习。');
    expect(captured.url.toString(), 'https://api.example.com/v1/chat/completions');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['model'], 'translator-v1');
    expect(captured.body, contains('Summarize'));
    expect(captured.body, contains('A small habit'));
  });

  test('rejects an oversized learning summary before making a request', () async {
    var requests = 0;
    final client = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      secrets: await _savedSecrets('private-key-value'),
    );

    await expectLater(
      client.summarize(profile: _profile, sourceText: 'x' * 12001),
      throwsA(
        isA<TranslationClientException>().having(
          (error) => error.code,
          'code',
          'invalid_input',
        ),
      ),
    );
    expect(requests, 0);
  });

  test(
    'passes retrieved web references to the selected model as context',
    () async {
      late http.Request captured;
      final translator = OpenAiCompatibleTranslationClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
            200,
          );
        }),
        secrets: await _savedSecrets('private-key-value'),
      );

      await translator.translate(
        profile: _profile,
        sourceText: 'Technology changes life.',
        webSearchContext: TranslationWebSearchContext(
          query: 'Technology changes life.',
          referenceText: 'An official glossary uses “technology” for 技术。',
          searchedAt: DateTime.utc(2026, 9, 14),
          sources: const [
            TranslationWebSearchSource(
              title: 'Official glossary',
              uri: 'https://example.com/glossary',
            ),
          ],
        ),
      );

      expect(captured.body, contains('联网检索参考资料'));
      expect(captured.body, contains('An official glossary'));
      expect(captured.body, contains('https://example.com/glossary'));
    },
  );

  test(
    'uses the DeepSeek official base URL without duplicating a version path',
    () async {
      late http.Request captured;
      const deepSeekProfile = ProviderProfileData(
        id: 'deepseek-api',
        displayName: 'DeepSeek API',
        kind: ProviderProfileKind.remoteApi,
        enabled: true,
        modelId: 'deepseek-v4-flash',
        endpoint: 'https://api.deepseek.com',
        secretRef: 'yixue.provider.deepseek-api.api-key',
      );
      final translator = OpenAiCompatibleTranslationClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
            200,
          );
        }),
        secrets: await (() async {
          final store = ProviderSecretStore(_MemorySecrets());
          await store.saveApiKey(deepSeekProfile.id, 'deepseek-test-key');
          return store;
        })(),
      );

      expect(
        await translator.translate(
          profile: deepSeekProfile,
          sourceText: 'Technology changes life.',
        ),
        '技术改变生活。',
      );
      expect(
        captured.url.toString(),
        'https://api.deepseek.com/chat/completions',
      );
      expect(captured.headers['authorization'], 'Bearer deepseek-test-key');
      expect(captured.body, contains('deepseek-v4-flash'));
    },
  );

  test('allows a loopback compatible endpoint without an API key', () async {
    late http.Request captured;
    const localProfile = ProviderProfileData(
      id: 'local.qwen',
      displayName: '本地千问',
      kind: ProviderProfileKind.remoteApi,
      enabled: true,
      modelId: 'qwen3.5:4b',
      endpoint: 'http://127.0.0.1:11435/v1',
    );
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"科技改变生活。"}}]}'),
          200,
        );
      }),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    expect(
      await translator.translate(
        profile: localProfile,
        sourceText: 'Technology changes life.',
      ),
      '科技改变生活。',
    );
    expect(captured.headers.containsKey('authorization'), isFalse);
  });

  test('retries a transient service failure once and then succeeds', () async {
    var requests = 0;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((_) async {
        requests += 1;
        if (requests == 1) return http.Response('{}', 503);
        return http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
          200,
        );
      }),
      secrets: await _savedSecrets('private-key-value'),
      retryDelay: Duration.zero,
    );

    expect(
      await translator.translate(
        profile: _profile,
        sourceText: 'Technology changes life.',
      ),
      '技术改变生活。',
    );
    expect(requests, 2);
  });

  test(
    'does not retry an authentication or request configuration failure',
    () async {
      var requests = 0;
      final translator = OpenAiCompatibleTranslationClient(
        httpClient: MockClient((_) async {
          requests += 1;
          return http.Response('{}', 401);
        }),
        secrets: await _savedSecrets('private-key-value'),
        retryDelay: Duration.zero,
      );

      await expectLater(
        translator.translate(profile: _profile, sourceText: 'hello'),
        throwsA(
          isA<TranslationClientException>().having(
            (error) => error.code,
            'code',
            'remote_service_error',
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('does not retry after the caller requests cancellation', () async {
    var requests = 0;
    var cancelled = false;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((_) async {
        requests += 1;
        cancelled = true;
        return http.Response('{}', 503);
      }),
      secrets: await _savedSecrets('private-key-value'),
      retryDelay: Duration.zero,
      shouldAbort: () => cancelled,
    );

    await expectLater(
      translator.translate(profile: _profile, sourceText: 'hello'),
      throwsA(
        isA<TranslationClientException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(requests, 1);
  });

  test('uses the native Ollama chat endpoint without an API key', () async {
    late http.Request captured;
    const localOllama = ProviderProfileData(
      id: 'local.ollama',
      displayName: '本地 Ollama',
      kind: ProviderProfileKind.remoteApi,
      enabled: true,
      modelId: 'qwen3.5:4b',
      endpoint: 'http://127.0.0.1:11435/api',
    );
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode('{"message":{"content":"科技正在改变我们的生活方式和工作方式。"}}'),
          200,
        );
      }),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    expect(
      await translator.translate(
        profile: localOllama,
        sourceText: 'Technology is changing the way we live and work.',
      ),
      '科技正在改变我们的生活方式和工作方式。',
    );
    expect(captured.url.toString(), 'http://127.0.0.1:11435/api/chat');
    expect(captured.headers.containsKey('authorization'), isFalse);
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['stream'], isFalse);
    expect(body['think'], isFalse);
    expect(body['options'], containsPair('temperature', 0));
    expect(body['options'], containsPair('num_ctx', 2048));
    expect(body['options'], containsPair('num_batch', 64));
    expect(body['model'], 'qwen3.5:4b');
  });

  test('sends the selected tone and line-break preference', () async {
    late http.Request captured;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object>{
              'choices': <Object>[
                <String, Object>{
                  'message': <String, Object>{'content': '译文'},
                },
              ],
            }),
          ),
          200,
        );
      }),
      secrets: await _savedSecrets('private-key-value'),
    );

    await translator.translate(
      profile: _profile,
      sourceText: 'A paragraph.\\nA second paragraph.',
      tone: TranslationTone.formal,
      preserveLineBreaks: true,
    );

    expect(captured.body, contains('formal, precise, professional tone'));
    expect(
      captured.body,
      contains('Preserve line breaks and paragraph structure'),
    );
  });

  test('describes the selected Chinese to English direction', () async {
    late http.Request captured;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object>{
            'choices': <Object>[
              <String, Object>{
                'message': <String, Object>{
                  'content': 'Learning changes life.',
                },
              },
            ],
          }),
          200,
        );
      }),
      secrets: await _savedSecrets('private-key-value'),
    );

    final result = await translator.translate(
      profile: _profile,
      sourceText: '学习改变生活。',
      sourceLanguage: 'chinese',
      targetLanguage: 'english',
    );

    expect(result, 'Learning changes life.');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    final messages = body['messages'] as List<dynamic>;
    final systemMessage = messages.first as Map<String, dynamic>;
    expect(systemMessage['content'], contains('from chinese to english'));
  });

  test(
    'includes selected terminology preferences in the system prompt',
    () async {
      late http.Request captured;
      final translator = OpenAiCompatibleTranslationClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"模型包"}}]}'),
            200,
          );
        }),
        secrets: await _savedSecrets('private-key-value'),
      );

      await translator.translate(
        profile: _profile,
        sourceText: 'model package',
        terminology: const <TranslationTermRule>[
          TranslationTermRule(
            id: 'en-zh',
            source: 'model package',
            target: '模型包',
            direction: TerminologyDirection.englishToChinese,
          ),
        ],
      );

      expect(captured.body, contains('model package => 模型包'));
    },
  );

  test('server errors do not expose private values', () async {
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient(
        (_) async => http.Response('internal token=server-secret', 500),
      ),
      secrets: await _savedSecrets('private-key-value'),
    );

    Object? error;
    try {
      await translator.translate(
        profile: _profile,
        sourceText: 'confidential source sentence',
      );
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<TranslationClientException>());
    expect((error! as TranslationClientException).code, 'remote_service_error');
    expect(error.toString(), isNot(contains('private-key-value')));
    expect(error.toString(), isNot(contains('confidential source sentence')));
    expect(error.toString(), isNot(contains('server-secret')));
  });

  test('timeout returns a stable sanitized error', () async {
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return http.Response('{}', 200);
      }),
      secrets: await _savedSecrets('private-key-value'),
      timeout: const Duration(milliseconds: 5),
    );

    await expectLater(
      translator.translate(profile: _profile, sourceText: 'hello'),
      throwsA(
        isA<TranslationClientException>().having(
          (error) => error.code,
          'code',
          'request_timeout',
        ),
      ),
    );
  });

  test('blank input is rejected before network and secret access', () async {
    var requests = 0;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      secrets: ProviderSecretStore(_MemorySecrets()),
    );

    await expectLater(
      translator.translate(profile: _profile, sourceText: '  '),
      throwsA(
        isA<TranslationClientException>().having(
          (error) => error.code,
          'code',
          'invalid_input',
        ),
      ),
    );
    expect(requests, 0);
  });

  test('connection check probes models without sending user text', () async {
    late http.Request captured;
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('{"data":[]}', 200);
      }),
      secrets: await _savedSecrets('private-key-value'),
    );

    await translator.checkConnection(profile: _profile);

    expect(captured.method, 'GET');
    expect(captured.url.toString(), 'https://api.example.com/v1/models');
    expect(captured.headers['authorization'], 'Bearer private-key-value');
    expect(captured.body, isEmpty);
  });

  test(
    'native Ollama connection check probes tags without sending text',
    () async {
      late http.Request captured;
      const localOllama = ProviderProfileData(
        id: 'local.ollama',
        displayName: '本地 Ollama',
        kind: ProviderProfileKind.remoteApi,
        enabled: true,
        modelId: 'qwen3.5:4b',
        endpoint: 'http://127.0.0.1:11435/api',
      );
      final translator = OpenAiCompatibleTranslationClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response('{"models":[]}', 200);
        }),
        secrets: ProviderSecretStore(_MemorySecrets()),
      );

      await translator.checkConnection(profile: localOllama);

      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'http://127.0.0.1:11435/api/tags');
      expect(captured.headers.containsKey('authorization'), isFalse);
      expect(captured.body, isEmpty);
    },
  );

  test('connection check reports a sanitized service error', () async {
    final translator = OpenAiCompatibleTranslationClient(
      httpClient: MockClient(
        (_) async => http.Response('secret=do-not-show', 401),
      ),
      secrets: await _savedSecrets('private-key-value'),
    );

    await expectLater(
      translator.checkConnection(profile: _profile),
      throwsA(
        isA<TranslationClientException>().having(
          (error) => error.code,
          'code',
          'remote_service_error',
        ),
      ),
    );
  });
}
