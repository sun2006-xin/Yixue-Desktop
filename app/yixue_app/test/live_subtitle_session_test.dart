import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_audio_capture.dart';
import 'package:yixue_app/features/simultaneous_interpretation/live_subtitle_session.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_translation_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LiveSessionHarness harness;

  setUp(() async {
    harness = await _LiveSessionHarness.create();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test(
    'pause, resume, and stop operate only on the session owned sources',
    () async {
      const expectedSources = <String>['system-output', 'microphone'];
      await harness.session.start(harness.request);
      expect(harness.session.captureStopConfirmed, isFalse);
      expect(
        harness.sourceIdsFor('startSource'),
        unorderedEquals(expectedSources),
      );
      expect(
        harness.sessionIdsFor('startSource'),
        everyElement('test-session'),
      );
      expect(harness.captureAttemptTransitions, ['test-attempt']);

      harness.captureCalls.clear();
      await harness.session.pause();
      expect(harness.captureAttemptTransitions.last, isNull);
      expect(
        harness.sourceIdsFor('pauseSource'),
        unorderedEquals(expectedSources),
      );
      expect(
        harness.sessionIdsFor('pauseSource'),
        everyElement('test-session'),
      );
      expect(
        harness.captureCalls.any((call) => call.method == 'pause'),
        isFalse,
      );

      harness.captureCalls.clear();
      await harness.session.resume();
      expect(harness.captureAttemptTransitions.last, isNotNull);
      expect(harness.captureAttemptTransitions.last, isNot('test-attempt'));
      expect(
        harness.sourceIdsFor('resumeSource'),
        unorderedEquals(expectedSources),
      );
      expect(
        harness.sessionIdsFor('resumeSource'),
        everyElement('test-session'),
      );
      expect(
        harness.captureCalls.any((call) => call.method == 'resume'),
        isFalse,
      );

      harness.captureCalls.clear();
      await harness.session.stop();
      expect(harness.captureAttemptTransitions.last, isNull);
      expect(harness.session.captureStopConfirmed, isTrue);
      expect(
        harness.sourceIdsFor('stopSource'),
        unorderedEquals(expectedSources),
      );
      expect(harness.sessionIdsFor('stopSource'), everyElement('test-session'));
      expect(
        harness.captureCalls.any((call) => call.method == 'stop'),
        isFalse,
      );
    },
  );

  test('a failed native stop is exposed as an unconfirmed capture', () async {
    await harness.session.start(harness.request);
    harness.failedStopSourceIds.add('system-output');

    await expectLater(
      harness.session.stop(),
      throwsA(isA<LiveSubtitleSessionException>()),
    );

    expect(harness.session.captureStopConfirmed, isFalse);
    expect(
      harness.session.currentState.errorCodes,
      contains('audio_capture_stop_failed'),
    );
  });

  test('rejects duplicate source ids even when kinds differ', () {
    expect(
      () => _request(
        sourceLanguageCode: 'en',
        additionalSourceId: 'system-output',
      ),
      throwsArgumentError,
    );
  });

  test(
    'pause rejects late frames while ASR finishes the current attempt',
    () async {
      await harness.session.start(harness.request);
      final systemAsr = harness.asrRuntime.sessions['system-output']!;
      final microphoneAsr = harness.asrRuntime.sessions['microphone']!;
      final gatedSessions = <_FakeStreamingAsrSession>[
        systemAsr,
        microphoneAsr,
      ];
      for (final asr in gatedSessions) {
        asr.finishStarted = Completer<void>();
        asr.finishGate = Completer<void>();
      }

      final pause = harness.session.pause();
      int? acceptedFrameCount;
      try {
        await Future.wait<void>(
          gatedSessions.map((asr) => asr.finishStarted!.future),
        ).timeout(const Duration(seconds: 2));
        harness.emitCaptureEvent(<String, Object?>{
          'type': 'audioFrame',
          'sessionId': 'test-session',
          'captureAttemptId': 'test-attempt',
          'sourceId': 'system-output',
          'sourceKind': 'systemOutput',
          'sequence': 1,
          'startTimeUs': 10000,
          'sampleRateHz': 16000,
          'channelCount': 1,
          'sampleCount': 160,
          'sampleFormat': 'signedInt16LittleEndian',
          'pcmBytes': Uint8List(320),
          'hasDiscontinuityBefore': false,
        });
        await Future<void>.delayed(Duration.zero);
        acceptedFrameCount = systemAsr.audioFrameCount;
      } finally {
        for (final asr in gatedSessions) {
          if (!asr.finishGate!.isCompleted) {
            asr.finishGate!.complete();
          }
        }
        await pause.timeout(const Duration(seconds: 2));
      }

      expect(acceptedFrameCount, 0);
      expect(
        harness.session.currentState.coordinator?.status,
        SubtitleSessionStatus.paused,
      );
    },
  );

  test(
    'partial start cleanup stops owned sources but preserves another owner',
    () async {
      // The first source starts successfully for this session. The second is
      // already owned by another session and rejects this session's start.
      harness.captureOwners['microphone'] = 'other-session';

      await expectLater(
        harness.session.start(harness.request),
        throwsA(isA<LiveSubtitleSessionException>()),
      );

      expect(harness.captureOwners['microphone'], 'other-session');
      expect(harness.captureOwners.containsKey('system-output'), isFalse);
      expect(
        harness.sourceIdsFor('startSource'),
        unorderedEquals(<String>['system-output', 'microphone']),
      );
      expect(
        harness.sourceIdsFor('stopSource'),
        unorderedEquals(<String>['system-output', 'microphone']),
      );
      expect(harness.sessionIdsFor('stopSource'), everyElement('test-session'));
      expect(
        harness.captureCalls.any((call) => call.method == 'stop'),
        isFalse,
        reason:
            'A failed start must not stop captures owned by other sessions.',
      );
      expect(
        harness.session.currentState.errorCodes,
        isNot(contains('audio_capture_stop_failed')),
      );
    },
  );

  test(
    'ASR readiness timeout stops startup and closes the recognizer',
    () async {
      await harness.dispose();
      harness = await _LiveSessionHarness.create(
        asrReadyTimeout: const Duration(milliseconds: 20),
      );
      harness.asrRuntime.initialState = const StreamingAsrState(
        status: StreamingAsrStatus.loading,
      );

      await expectLater(
        harness.session.start(harness.request),
        throwsA(
          isA<LiveSubtitleSessionException>().having(
            (error) => error.code,
            'code',
            'asr_ready_timeout',
          ),
        ),
      ).timeout(const Duration(seconds: 2));

      expect(
        harness.session.currentState.errorCodes,
        contains('asr_ready_timeout'),
      );
      expect(harness.session.captureStopConfirmed, isTrue);
      expect(harness.sourceIdsFor('startSource'), isEmpty);
      expect(harness.asrRuntime.sessions.values, hasLength(1));
      expect(harness.asrRuntime.sessions.values.single.isClosed, isTrue);
    },
  );

  test('ASR open timeout closes a session that arrives late', () async {
    await harness.dispose();
    harness = await _LiveSessionHarness.create(
      asrOpenTimeout: const Duration(milliseconds: 20),
    );
    final lateSession = _FakeStreamingAsrSession();
    final openGate = Completer<StreamingAsrSession>();
    harness.asrRuntime.openGate = openGate;

    await expectLater(
      harness.session.start(harness.request),
      throwsA(
        isA<LiveSubtitleSessionException>().having(
          (error) => error.code,
          'code',
          'asr_open_timeout',
        ),
      ),
    ).timeout(const Duration(seconds: 2));
    expect(harness.sourceIdsFor('startSource'), isEmpty);

    openGate.complete(lateSession);
    await lateSession.closedSignal.future.timeout(const Duration(seconds: 2));
    expect(lateSession.isClosed, isTrue);
  });

  test(
    'session start request stores auto separately from transcript language',
    () {
      final autoRequest = _request(sourceLanguageCode: 'auto');
      final manualRequest = _request(sourceLanguageCode: 'ja');

      expect(autoRequest.recognitionMode, SubtitleRecognitionMode.auto);
      expect(manualRequest.recognitionMode, SubtitleRecognitionMode.manual);
      expect(autoRequest.sourceLanguageCode, 'auto');
      expect(manualRequest.sourceLanguageCode, 'ja');
    },
  );
}

LiveSubtitleSessionStartRequest _request({
  required String sourceLanguageCode,
  String additionalSourceId = 'microphone',
}) => LiveSubtitleSessionStartRequest(
  sessionId: 'test-session',
  initialCaptureAttemptId: 'test-attempt',
  source: const DesktopAudioCaptureSource(
    sourceId: 'system-output',
    sourceKind: SubtitleAudioSourceKind.systemOutput,
    displayName: '电脑播放声音',
    description: '测试音源',
  ),
  additionalSources: <DesktopAudioCaptureSource>[
    DesktopAudioCaptureSource(
      sourceId: additionalSourceId,
      sourceKind: SubtitleAudioSourceKind.microphone,
      displayName: '麦克风',
      description: '测试麦克风',
    ),
  ],
  kind: SubtitleSessionKind.meeting,
  sourceLanguageCode: sourceLanguageCode,
  targetLanguageCode: 'zh',
  translationEnabled: false,
);

final class _LiveSessionHarness {
  _LiveSessionHarness({
    required this.root,
    required this.messenger,
    required this.captureCalls,
    required this.captureOwners,
    required this.failedStopSourceIds,
    required this.captureEventSinks,
    required this.captureAttemptTransitions,
    required this.asrRuntime,
    required this.session,
  });

  static const MethodChannel _methodChannel = MethodChannel(
    'test/yixue/live-subtitle-capture',
  );
  static const EventChannel _eventChannel = EventChannel(
    'test/yixue/live-subtitle-capture-events',
  );

  final Directory root;
  final TestDefaultBinaryMessenger messenger;
  final List<MethodCall> captureCalls;
  final Map<String, String> captureOwners;
  final Set<String> failedStopSourceIds;
  final List<MockStreamHandlerEventSink> captureEventSinks;
  final List<String?> captureAttemptTransitions;
  final _FakeStreamingAsrRuntime asrRuntime;
  final LiveSubtitleSession session;

  LiveSubtitleSessionStartRequest get request =>
      _request(sourceLanguageCode: 'en');

  List<String> sourceIdsFor(String method) => captureCalls
      .where((call) => call.method == method)
      .map(
        (call) =>
            (call.arguments as Map<Object?, Object?>)['sourceId']! as String,
      )
      .toList(growable: false);

  List<String> sessionIdsFor(String method) => captureCalls
      .where((call) => call.method == method)
      .map(
        (call) =>
            (call.arguments as Map<Object?, Object?>)['sessionId']! as String,
      )
      .toList(growable: false);

  void emitCaptureEvent(Map<String, Object?> event) {
    captureEventSinks.last.success(event);
  }

  static Future<_LiveSessionHarness> create({
    Duration asrOpenTimeout = const Duration(seconds: 75),
    Duration asrReadyTimeout = const Duration(seconds: 15),
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final root = await Directory.systemTemp.createTemp(
      'yixue-live-session-source-scope-',
    );
    final captureCalls = <MethodCall>[];
    final captureOwners = <String, String>{};
    final failedStopSourceIds = <String>{};
    final captureEventSinks = <MockStreamHandlerEventSink>[];
    final captureAttemptTransitions = <String?>[];
    messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      captureCalls.add(call);
      if (call.method == 'stop') {
        captureOwners.clear();
        return null;
      }
      final arguments = call.arguments;
      if (arguments is Map<Object?, Object?> &&
          arguments['sourceId'] is String &&
          arguments['sessionId'] is String) {
        final sourceId = arguments['sourceId']! as String;
        final sessionId = arguments['sessionId']! as String;
        final owner = captureOwners[sourceId];
        if (call.method == 'startSource' || call.method == 'resumeSource') {
          if (owner != null && owner != sessionId) {
            throw PlatformException(code: 'captureSourceOwnedByAnotherSession');
          }
          captureOwners[sourceId] = sessionId;
        } else if (call.method == 'pauseSource' ||
            call.method == 'stopSource') {
          if (owner != null && owner != sessionId) {
            throw PlatformException(
              code: 'capture_source_owned_by_another_session',
            );
          }
          if (call.method == 'stopSource') {
            if (failedStopSourceIds.remove(sourceId)) {
              throw PlatformException(code: 'capture_stop_failed');
            }
            captureOwners.remove(sourceId);
          }
        }
      }
      return null;
    });
    messenger.setMockStreamHandler(
      _eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) => captureEventSinks.add(events),
      ),
    );

    final asr = _FakeStreamingAsrRuntime();
    final session = LiveSubtitleSession(
      capture: DesktopAudioCaptureAdapter(
        methodChannel: _methodChannel,
        eventChannel: _eventChannel,
      ),
      asrRuntime: asr,
      store: FileSubtitleSessionStore(root),
      translationExecutor: const _UnusedTranslationExecutor(),
      onCaptureAttemptChanged: captureAttemptTransitions.add,
      asrOpenTimeout: asrOpenTimeout,
      asrReadyTimeout: asrReadyTimeout,
    );
    return _LiveSessionHarness(
      root: root,
      messenger: messenger,
      captureCalls: captureCalls,
      captureOwners: captureOwners,
      failedStopSourceIds: failedStopSourceIds,
      captureEventSinks: captureEventSinks,
      captureAttemptTransitions: captureAttemptTransitions,
      asrRuntime: asr,
      session: session,
    );
  }

  Future<void> dispose() async {
    await session.dispose();
    messenger.setMockMethodCallHandler(_methodChannel, null);
    messenger.setMockStreamHandler(_eventChannel, null);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _FakeStreamingAsrRuntime implements StreamingAsrRuntime {
  final Map<String, _FakeStreamingAsrSession> sessions =
      <String, _FakeStreamingAsrSession>{};
  StreamingAsrState initialState = const StreamingAsrState(
    status: StreamingAsrStatus.ready,
  );
  Completer<StreamingAsrSession>? openGate;

  @override
  Future<StreamingAsrSession> openSession({
    required String sessionId,
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required String sourceLanguageCode,
  }) async {
    final gate = openGate;
    if (gate != null) return gate.future;
    final session = _FakeStreamingAsrSession(initialState: initialState);
    sessions[sourceId] = session;
    return session;
  }
}

final class _FakeStreamingAsrSession implements StreamingAsrSession {
  _FakeStreamingAsrSession({
    this.initialState = const StreamingAsrState(
      status: StreamingAsrStatus.ready,
    ),
  }) : _state = initialState;

  final StreamingAsrState initialState;
  final StreamController<TranscriptRevision> _revisions =
      StreamController<TranscriptRevision>.broadcast();
  final StreamController<StreamingAsrState> _states =
      StreamController<StreamingAsrState>.broadcast();
  StreamingAsrState _state;
  Completer<void>? finishStarted;
  Completer<void>? finishGate;
  int audioFrameCount = 0;
  bool _closed = false;

  final Completer<void> closedSignal = Completer<void>();

  bool get isClosed => _closed;

  @override
  Stream<TranscriptRevision> get revisions => _revisions.stream;

  @override
  Stream<StreamingAsrState> get stateChanges => _states.stream;

  @override
  StreamingAsrState get currentState => _state;

  @override
  void beginCaptureAttempt(String captureAttemptId) {}

  @override
  void addAudio(AudioFrame frame) {
    audioFrameCount++;
  }

  @override
  Future<void> finishCaptureAttempt(String captureAttemptId) async {
    final started = finishStarted;
    if (started != null && !started.isCompleted) started.complete();
    await finishGate?.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _state = const StreamingAsrState(status: StreamingAsrStatus.closed);
    _states.add(_state);
    await _revisions.close();
    await _states.close();
    if (!closedSignal.isCompleted) closedSignal.complete();
  }
}

final class _UnusedTranslationExecutor implements SubtitleTranslationExecutor {
  const _UnusedTranslationExecutor();

  @override
  Future<String> translate(SubtitleTranslationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String requestId) async {}
}
