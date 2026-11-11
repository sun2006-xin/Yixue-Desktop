import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';

void main() {
  test('selected word cancellation correlates the operation and ACK', () async {
    Map<String, Object?>? sent;
    final cancelled = await cancelScreenshotWordTranslation(
      operationId: 'word-operation-7',
      requestId: 'word-cancel-2',
      send: (value) async {
        sent = value;
        return {
          'version': 1,
          'type': 'ack',
          'requestId': 'word-cancel-2',
          'payload': {'cancelled': true},
        };
      },
    );

    expect(cancelled, isTrue);
    expect(sent!['type'], 'cancelScreenshotWordTranslation');
    expect(sent!['requestId'], 'word-cancel-2');
    expect((sent!['payload'] as Map)['operationId'], 'word-operation-7');
    await expectLater(
      cancelScreenshotWordTranslation(
        operationId: 'word-operation-7',
        requestId: 'word-cancel-3',
        send: (_) async => {
          'version': 1,
          'type': 'ack',
          'requestId': 'mismatched',
          'payload': {'cancelled': true},
        },
      ),
      throwsFormatException,
    );
  });

  test(
    'selected word cancellation returns false when the ACK never arrives',
    () async {
      final neverAcknowledges = Completer<Object?>().future;
      final stopwatch = Stopwatch()..start();

      final cancelled = await cancelScreenshotWordTranslation(
        operationId: 'word-operation-stalled',
        requestId: 'word-cancel-stalled',
        ackTimeout: const Duration(milliseconds: 10),
        send: (_) => neverAcknowledges,
      );

      expect(cancelled, isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );

  test(
    'wordbook transport validates correlated ACK status and errors',
    () async {
      const request = ScreenshotWordRequest(
        sessionId: 's1',
        word: 'hello',
        recognizedText: 'hello world',
        translatedText: '你好世界',
        historyEntryId: 's1',
      );
      for (final status in ScreenshotWordAddStatus.values) {
        Map<String, Object?>? sent;
        final result = await requestScreenshotWordAdd(
          request: request,
          requestId: 'word-1',
          send: (value) async {
            sent = value;
            return {
              'version': 1,
              'type': 'ack',
              'requestId': 'word-1',
              'payload': {'status': status.name},
            };
          },
        );
        expect(result, status);
        expect(sent!['type'], 'addScreenshotWord');
        expect(sent!['requestId'], 'word-1');
        expect(
          (sent!['payload'] as Map).keys,
          unorderedEquals([
            'sessionId',
            'word',
            'recognizedText',
            'translatedText',
            'historyEntryId',
          ]),
        );
      }
      for (final response in [
        {
          'version': 1,
          'type': 'ack',
          'requestId': 'other',
          'payload': {'status': 'added'},
        },
        {
          'version': 1,
          'type': 'other',
          'requestId': 'word-1',
          'payload': {'status': 'added'},
        },
        {
          'version': 2,
          'type': 'ack',
          'requestId': 'word-1',
          'payload': {'status': 'added'},
        },
        {'version': 1, 'type': 'ack', 'requestId': 'word-1', 'payload': {}},
        {
          'version': 1,
          'type': 'ack',
          'requestId': 'word-1',
          'payload': {'status': 'unknown'},
        },
      ]) {
        await expectLater(
          requestScreenshotWordAdd(
            request: request,
            requestId: 'word-1',
            send: (_) async => response,
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        requestScreenshotWordAdd(
          request: request,
          requestId: 'word-1',
          send: (_) async => {
            'version': 1,
            'type': 'ack',
            'requestId': 'word-1',
            'payload': {'errorCode': 'stale_session'},
          },
        ),
        throwsA(
          isA<ScreenshotWordRequestException>().having(
            (error) => error.code,
            'code',
            'stale_session',
          ),
        ),
      );
    },
  );

  test('wordbook text payload round trips without image data', () {
    final request = ScreenshotWordRequest(
      sessionId: 's1',
      word: "don't",
      recognizedText: "don't panic",
      translatedText: '不要慌张',
      historyEntryId: 's1',
    );
    final message = ScreenshotTranslationWindowMessage(
      type: 'addScreenshotWord',
      requestId: 'word-1',
      payload: request.toPayload(),
    );
    final decoded = ScreenshotTranslationWindowMessage.fromMap(
      const StandardMessageCodec().decodeMessage(
        const StandardMessageCodec().encodeMessage(message.toMap()),
      ),
    );
    final roundTrip = ScreenshotWordRequest.fromMessage(decoded);
    expect(roundTrip.word, "don't");
    expect(roundTrip.recognizedText, "don't panic");
    expect(roundTrip.translatedText, '不要慌张');
    expect(roundTrip.historyEntryId, 's1');
    expect(
      decoded.payload.keys,
      unorderedEquals([
        'sessionId',
        'word',
        'recognizedText',
        'translatedText',
        'historyEntryId',
      ]),
    );
  });

  test('wordbook rejects malformed fields and unknown payload keys', () {
    final payload = <String, Object?>{
      'sessionId': 's1',
      'word': 'hello',
      'recognizedText': 'hello world',
      'translatedText': '你好世界',
      'historyEntryId': 's1',
    };
    for (final invalid in [
      {...payload}..remove('word'),
      {...payload, 'word': 123},
      {...payload, 'sessionId': ''},
      {...payload, 'historyEntryId': ''},
      {...payload, 'word': 'hello world'},
      {...payload, 'word': 'hello!'},
      {...payload, 'word': List.filled(33, 'a').join()},
      {...payload, 'word': "foo--bar"},
      {...payload, 'word': ''},
      {
        ...payload,
        'extra': {
          'imageBytes': [1],
        },
      },
      {...payload, 'recognizedText': List.filled(100001, 'a').join()},
    ]) {
      expect(
        () => ScreenshotWordRequest.fromMessage(
          ScreenshotTranslationWindowMessage(
            type: 'addScreenshotWord',
            requestId: 'invalid',
            payload: invalid,
          ),
        ),
        throwsFormatException,
        reason: 'invalid fields: ${invalid.keys}',
      );
    }
    expect(
      () => ScreenshotWordRequest.fromMessage(
        ScreenshotTranslationWindowMessage(
          type: 'probe',
          requestId: 'wrong-type',
          payload: payload,
        ),
      ),
      throwsFormatException,
    );
  });

  test('wordbook requests reject imageBytes before transport', () {
    expect(
      () => ScreenshotTranslationWindowMessage(
        type: 'addScreenshotWord',
        requestId: 'word-1',
        payload: {
          'sessionId': 's1',
          'word': 'hello',
          'recognizedText': 'hello world',
          'translatedText': '你好世界',
          'historyEntryId': 's1',
          'imageBytes': Uint8List.fromList([1]),
        },
      ),
      throwsFormatException,
    );
  });

  test(
    'screenshot dictionary lookup accepts Chinese terms, rejects phrases',
    () {
      ScreenshotDictionaryLookupRequest request(String word) =>
          ScreenshotDictionaryLookupRequest.fromMessage(
            ScreenshotTranslationWindowMessage(
              type: 'lookupScreenshotWord',
              requestId: 'lookup-1',
              payload: {
                'sessionId': 's1',
                'word': word,
                'recognizedText': '我正在学习语言',
              },
            ),
          );

      expect(request('学习').word, '学习');
      expect(request('hello').word, 'hello');
      expect(() => request('我正在学习语言'), throwsFormatException);
      expect(() => request('hello world'), throwsFormatException);
    },
  );

  test(
    'screenshot selected-word translation validates request and ACK',
    () async {
      const request = ScreenshotWordTranslationRequest(
        sessionId: 'capture-1',
        word: 'hello',
        recognizedText: 'Hello, world.',
      );
      Map<String, Object?>? sent;
      final translated = await requestScreenshotWordTranslation(
        request: request,
        requestId: 'translate-word-1',
        send: (value) async {
          sent = Map<String, Object?>.from(value);
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: 'translate-word-1',
            payload: const {'translation': '你好'},
          ).toMap();
        },
      );

      expect(sent?['type'], 'translateScreenshotWord');
      expect((sent?['payload'] as Map)['word'], 'hello');
      expect(translated, '你好');
      expect(
        () => ScreenshotWordTranslationRequest.fromMessage(
          ScreenshotTranslationWindowMessage(
            type: 'translateScreenshotWord',
            requestId: 'invalid-word',
            payload: const {
              'sessionId': 'capture-1',
              'word': 'hello world',
              'recognizedText': 'Hello world.',
            },
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test('selected-word translation returns a retryable timeout when the ACK never arrives', () async {
    final neverAcknowledges = Completer<Object?>().future;
    final stopwatch = Stopwatch()..start();

    await expectLater(
      requestScreenshotWordTranslation(
        request: const ScreenshotWordTranslationRequest(
          sessionId: 'capture-1',
          word: 'hello',
          recognizedText: 'Hello, world.',
        ),
        requestId: 'translate-word-stalled',
        ackTimeout: const Duration(milliseconds: 10),
        send: (_) => neverAcknowledges,
      ),
      throwsA(
        isA<ScreenshotWordRequestException>().having(
          (error) => error.code,
          'code',
          'translation_timeout',
        ),
      ),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test(
    'screenshot dictionary lookup acknowledgement preserves rich fields',
    () async {
      const request = ScreenshotDictionaryLookupRequest(
        sessionId: 'capture-1',
        word: 'study',
        recognizedText: 'We study language.',
      );

      final entry = await requestScreenshotDictionaryLookup(
        request: request,
        requestId: 'lookup-1',
        send: (_) async => ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: 'lookup-1',
          payload: {
            'entry': {
              'word': 'study',
              'ipa': '/ˈstʌdi/',
              'partOfSpeech': '动词',
              'meanings': ['学习'],
              'example': 'We study language.',
              'exampleTranslation': '我们学习语言。',
              'qualityStatus': 'verified',
              'examples': const [],
              'variants': ['studies', 'studied'],
              'collocations': ['study hard'],
              'relations': {
                '名词': ['student'],
              },
            },
          },
        ).toMap(),
      );

      expect(entry?.variants, ['studies', 'studied']);
      expect(entry?.collocations, ['study hard']);
      expect(entry?.relations, {
        '名词': ['student'],
      });
    },
  );

  test(
    'screenshot dictionary lookup accepts legacy acknowledgements',
    () async {
      const request = ScreenshotDictionaryLookupRequest(
        sessionId: 'capture-legacy',
        word: 'study',
        recognizedText: 'We study language.',
      );

      final result = await requestScreenshotDictionaryLookup(
        request: request,
        requestId: 'lookup-legacy',
        send: (_) async => ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: 'lookup-legacy',
          payload: {
            'entry': {
              'word': 'study',
              'ipa': '',
              'partOfSpeech': '',
              'meanings': ['学习'],
              'example': '',
              'exampleTranslation': '',
              'qualityStatus': 'verified',
              'examples': const [],
            },
          },
        ).toMap(),
      );

      expect(result?.word, 'study');
      expect(result?.variants, isEmpty);
      expect(result?.collocations, isEmpty);
      expect(result?.relations, isEmpty);
    },
  );

  test(
    'screenshot dictionary lookup acknowledgement rejects oversized lists',
    () async {
      const request = ScreenshotDictionaryLookupRequest(
        sessionId: 'capture-1',
        word: 'study',
        recognizedText: 'We study language.',
      );
      Future<Object?> sendWith(Map<String, Object?> entry) async =>
          ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: 'lookup-1',
            payload: {'entry': entry},
          ).toMap();
      final base = <String, Object?>{
        'word': 'study',
        'ipa': '',
        'partOfSpeech': '',
        'meanings': ['学习'],
        'example': '',
        'exampleTranslation': '',
        'qualityStatus': 'verified',
        'examples': const [],
      };

      for (final entry in <Map<String, Object?>>[
        {
          ...base,
          'relations': {'相关词': List<String>.filled(101, 'term')},
        },
        {...base, 'meanings': List<String>.filled(101, 'meaning')},
        {...base, 'examples': List<Object?>.filled(101, const {})},
      ]) {
        await expectLater(
          requestScreenshotDictionaryLookup(
            request: request,
            requestId: 'lookup-1',
            send: (_) => sendWith(entry),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('message_round_trips_typed_image_payload', () {
    final image = Uint8List.fromList([0, 1, 127, 255]);
    final message = ScreenshotTranslationWindowMessage(
      type: 'capture',
      requestId: 'session-42',
      payload: {'sessionId': 'session-42', 'imageBytes': image},
    );

    final wireValue = const StandardMessageCodec().decodeMessage(
      const StandardMessageCodec().encodeMessage(message.toMap()),
    );
    final decoded = ScreenshotTranslationWindowMessage.fromMap(wireValue);

    expect(decoded.version, 1);
    expect(decoded.type, 'capture');
    expect(decoded.requestId, 'session-42');
    expect(decoded.payload['sessionId'], 'session-42');
    expect(decoded.payload['imageBytes'], isA<Uint8List>());
    expect(decoded.payload['imageBytes'], orderedEquals(image));
  });

  test('unsupported_protocol_version_is_rejected', () {
    expect(
      () => ScreenshotTranslationWindowMessage.fromMap({
        'version': 2,
        'type': 'capture',
        'requestId': 'session-42',
        'payload': <String, Object?>{},
      }),
      throwsFormatException,
    );
  });

  test('message_requires_request_id', () {
    expect(
      () => ScreenshotTranslationWindowMessage.fromMap({
        'version': 1,
        'type': 'capture',
        'requestId': '',
        'payload': <String, Object?>{},
      }),
      throwsFormatException,
    );
  });

  test('startup_arguments_route_both_roles', () {
    for (final role in ScreenshotTranslationWindowRole.values) {
      final arguments = ScreenshotTranslationWindowArguments(
        role: role,
        parentWindowId: 'main-1',
      );
      final decoded = ScreenshotTranslationWindowArguments.decode(
        arguments.encode(),
      );
      expect(decoded.role, role);
      expect(decoded.parentWindowId, 'main-1');
    }
  });

  test('result update stamps order handles before per-handle sequences', () {
    const oldHandleLatest = ScreenshotTranslationWindowUpdateStamp(
      connectionGeneration: 4,
      updateSequence: 18,
    );
    const newHandleFirst = ScreenshotTranslationWindowUpdateStamp(
      connectionGeneration: 5,
      updateSequence: 1,
    );
    const oldHandleLate = ScreenshotTranslationWindowUpdateStamp(
      connectionGeneration: 4,
      updateSequence: 19,
    );
    const sameHandleLater = ScreenshotTranslationWindowUpdateStamp(
      connectionGeneration: 5,
      updateSequence: 2,
    );

    expect(newHandleFirst.isAfter(oldHandleLatest), isTrue);
    expect(oldHandleLate.isAfter(newHandleFirst), isFalse);
    expect(sameHandleLater.isAfter(newHandleFirst), isTrue);
    expect(newHandleFirst.isAfter(newHandleFirst), isFalse);
  });

  test(
    'result window host epochs reject delayed probes from retired hosts',
    () {
      final epochs = ScreenshotTranslationWindowHostEpoch();

      expect(
        epochs.claim('100-host-a'),
        ScreenshotTranslationHostEpochClaim.activated,
      );
      expect(
        epochs.claim('100-host-a'),
        ScreenshotTranslationHostEpochClaim.unchanged,
      );
      expect(
        epochs.claim('200-host-b'),
        ScreenshotTranslationHostEpochClaim.activated,
      );
      expect(epochs.accepts('200-host-b'), isTrue);
      expect(
        epochs.claim('100-host-a'),
        ScreenshotTranslationHostEpochClaim.retired,
      );
      expect(epochs.active, '200-host-b');
      expect(epochs.accepts(123), isFalse);
    },
  );

  test('a delayed unknown older host cannot reclaim the result child', () {
    final epochs = ScreenshotTranslationWindowHostEpoch();

    expect(
      epochs.claim('200-host-b'),
      ScreenshotTranslationHostEpochClaim.activated,
    );
    expect(
      epochs.claim('100-host-a'),
      ScreenshotTranslationHostEpochClaim.retired,
    );
    expect(epochs.active, '200-host-b');
    expect(epochs.accepts('200-host-b'), isTrue);
  });

  test('host epochs with the same counter cannot reorder each other', () {
    final epochs = ScreenshotTranslationWindowHostEpoch();

    expect(
      epochs.claim('200-host-b'),
      ScreenshotTranslationHostEpochClaim.activated,
    );
    expect(
      epochs.claim('200-host-c'),
      ScreenshotTranslationHostEpochClaim.retired,
    );
    expect(epochs.active, '200-host-b');
  });

  test(
    'QPC epochs supersede legacy wall epochs without comparing clock units',
    () {
      final epochs = ScreenshotTranslationWindowHostEpoch();
      const legacyWallEpoch = '1791500000000000-legacy';

      expect(
        epochs.claim(legacyWallEpoch),
        ScreenshotTranslationHostEpochClaim.activated,
      );
      expect(
        epochs.claim('qpc-100-new-host'),
        ScreenshotTranslationHostEpochClaim.activated,
      );
      expect(
        epochs.claim('1791500000000001-delayed-legacy-host'),
        ScreenshotTranslationHostEpochClaim.retired,
      );
      expect(epochs.active, 'qpc-100-new-host');
    },
  );

  test('wall clock fallback cannot supersede a QPC host', () {
    final epochs = ScreenshotTranslationWindowHostEpoch();

    expect(
      epochs.claim('qpc-100-current-host'),
      ScreenshotTranslationHostEpochClaim.activated,
    );
    expect(
      epochs.claim('wall-9999999999999999-fallback-host'),
      ScreenshotTranslationHostEpochClaim.retired,
    );
    expect(epochs.active, 'qpc-100-current-host');
  });

  test('malformed host epochs cannot claim a result child', () {
    final epochs = ScreenshotTranslationWindowHostEpoch();

    expect(
      epochs.claim('host-without-counter'),
      ScreenshotTranslationHostEpochClaim.retired,
    );
    expect(epochs.active, isNull);
  });

  test('unknown_startup_role_is_rejected', () {
    expect(
      () => ScreenshotTranslationWindowArguments.decode(
        '{"version":1,"role":"other","parentWindowId":"main-1"}',
      ),
      throwsFormatException,
    );
  });

  test('unsupported_startup_version_is_rejected', () {
    expect(
      () => ScreenshotTranslationWindowArguments.decode(
        '{"version":2,"role":"orb","parentWindowId":"main-1"}',
      ),
      throwsFormatException,
    );
  });
}
