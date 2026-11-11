import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'streaming_asr_text.dart';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../features/simultaneous_interpretation/audio_capture_contract.dart';
import '../features/simultaneous_interpretation/asr_language_registry.dart';
import '../features/simultaneous_interpretation/multilingual_asr_model_store.dart';
import '../features/simultaneous_interpretation/streaming_asr.dart';
import '../features/simultaneous_interpretation/subtitle_session_contract.dart';

/// Local sherpa-onnx ASR runtime. English and Chinese use the official
/// bilingual streaming Zipformer model; all other registered languages and
/// Auto use a Whisper/VAD segmented offline path. Heavy decode work runs in a
/// dedicated isolate so recognition never blocks Flutter's UI isolate.
///
/// The model is an explicit local asset. This runtime never downloads it and
/// never sends audio to a service.
final class SherpaStreamingAsrRuntime implements StreamingAsrRuntime {
  SherpaStreamingAsrRuntime({
    required this.modelDirectory,
    this.multilingualModelDirectory,
    this.numThreads = 2,
    this.maxQueuedFrames = 64,
    this.workerTimeout = const Duration(seconds: 60),
  }) {
    if (numThreads <= 0) {
      throw ArgumentError.value(numThreads, 'numThreads', 'Must be positive.');
    }
    if (maxQueuedFrames <= 0) {
      throw ArgumentError.value(
        maxQueuedFrames,
        'maxQueuedFrames',
        'Must be positive.',
      );
    }
  }

  static const String modelId =
      'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20';

  final Directory modelDirectory;
  final Directory? multilingualModelDirectory;
  final int numThreads;
  final int maxQueuedFrames;
  final Duration workerTimeout;

  @override
  Future<StreamingAsrSession> openSession({
    required String sessionId,
    required String sourceId,
    required SubtitleAudioSourceKind sourceKind,
    required String sourceLanguageCode,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.runtimeUnavailable,
      );
    }
    if (sessionId.trim().isEmpty || sourceId.trim().isEmpty) {
      throw ArgumentError('sessionId and sourceId are required.');
    }
    final language = _primaryLanguageCode(sourceLanguageCode);
    final useMultilingualModel = AsrLanguageRegistry.usesMultilingualModel(
      language,
    );
    if (language != 'en' && language != 'zh' && !useMultilingualModel) {
      throw ArgumentError.value(
        sourceLanguageCode,
        'sourceLanguageCode',
        'Expected a registered language code or auto.',
      );
    }

    if (useMultilingualModel && multilingualModelDirectory == null) {
      throw const StreamingAsrException(StreamingAsrErrorCode.modelUnavailable);
    }
    final multilingualAssets = useMultilingualModel
        ? MultilingualAsrModelAssets(
            modelDirectory: multilingualModelDirectory!,
          )
        : null;
    final files = useMultilingualModel
        ? _multilingualModelFiles(multilingualAssets!)
        : _modelFiles(modelDirectory);
    for (final file in files.values) {
      if (!await file.exists() || await file.length() == 0) {
        throw const StreamingAsrException(
          StreamingAsrErrorCode.modelUnavailable,
        );
      }
    }

    final session = _SherpaStreamingAsrSession(
      sessionId: sessionId,
      sourceId: sourceId,
      sourceKind: sourceKind,
      sourceLanguageCode: language,
      useMultilingualModel: useMultilingualModel,
      modelFiles: files,
      numThreads: numThreads,
      maxQueuedFrames: maxQueuedFrames,
      workerTimeout: workerTimeout,
    );
    await session.initialize();
    return session;
  }
}

final class _SherpaStreamingAsrSession implements StreamingAsrSession {
  _SherpaStreamingAsrSession({
    required this.sessionId,
    required this.sourceId,
    required this.sourceKind,
    required this.sourceLanguageCode,
    required this.useMultilingualModel,
    required this.modelFiles,
    required this.numThreads,
    required this.maxQueuedFrames,
    required this.workerTimeout,
  });

  final String sessionId;
  final String sourceId;
  final SubtitleAudioSourceKind sourceKind;
  final String sourceLanguageCode;
  final bool useMultilingualModel;
  final Map<String, File> modelFiles;
  final int numThreads;
  final int maxQueuedFrames;
  final Duration workerTimeout;

  final Queue<_QueuedAudioFrame> _pendingFrames = Queue<_QueuedAudioFrame>();
  final Map<String, int> _lastSequenceByAttempt = <String, int>{};
  final StreamController<TranscriptRevision> _revisionController =
      StreamController<TranscriptRevision>.broadcast();
  final StreamController<StreamingAsrState> _stateController =
      StreamController<StreamingAsrState>.broadcast();
  final ReceivePort _workerMessages = ReceivePort();
  final ReceivePort _workerExit = ReceivePort();
  final Completer<void> _workerReady = Completer<void>();
  final Map<String, Completer<void>> _attemptFinishAcks =
      <String, Completer<void>>{};
  final Completer<void> _workerCloseAck = Completer<void>();
  final Completer<void> _workerCleanupAck = Completer<void>();

  Future<void>? _closeFuture;
  Future<void>? _workerDisposeFuture;
  Isolate? _isolate;
  StreamSubscription<Object?>? _workerSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  SendPort? _commands;
  Completer<void>? _inFlightAck;
  String? _expectedAttemptId;
  int _nextFrameId = 0;
  int? _inFlightFrameId;
  bool _pumping = false;
  bool _closing = false;
  bool _closed = false;
  StreamingAsrState _state = const StreamingAsrState(
    status: StreamingAsrStatus.loading,
  );

  @override
  Stream<TranscriptRevision> get revisions => _revisionController.stream;

  @override
  Stream<StreamingAsrState> get stateChanges => _stateController.stream;

  @override
  StreamingAsrState get currentState => _state;

  Future<void> initialize() async {
    _workerSubscription = _workerMessages.listen(_onWorkerMessage);
    _exitSubscription = _workerExit.listen((_) {
      if (!_closing && !_closed) {
        _fail(StreamingAsrErrorCode.workerExited, workerAlreadyCleaned: true);
      }
    });
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _sherpaWorkerEntry,
        <Object?>[
          _workerMessages.sendPort,
          modelFiles['encoder']!.path,
          modelFiles['decoder']!.path,
          modelFiles['joiner']?.path ?? '',
          modelFiles['tokens']!.path,
          numThreads,
          useMultilingualModel ? 'whisper' : 'zipformer',
          sourceLanguageCode,
          modelFiles['vad']?.path ?? '',
        ],
        onError: _workerMessages.sendPort,
        onExit: _workerExit.sendPort,
        errorsAreFatal: true,
      );
      await _workerReady.future.timeout(workerTimeout);
    } on TimeoutException {
      _fail(StreamingAsrErrorCode.workerTimedOut);
      _isolate?.kill(priority: Isolate.immediate);
      await _releasePorts();
      await _releaseControllers();
      rethrow;
    } on StreamingAsrException {
      _isolate?.kill(priority: Isolate.immediate);
      await _releasePorts();
      await _releaseControllers();
      rethrow;
    } catch (_) {
      _fail(StreamingAsrErrorCode.runtimeInitializationFailed);
      _isolate?.kill(priority: Isolate.immediate);
      await _releasePorts();
      await _releaseControllers();
      rethrow;
    }
  }

  @override
  void beginCaptureAttempt(String captureAttemptId) {
    if (_closed || _closing || _state.status == StreamingAsrStatus.failed) {
      throw StateError('The streaming ASR session is not available.');
    }
    final attemptId = captureAttemptId.trim();
    if (attemptId.isEmpty) {
      throw ArgumentError.value(
        captureAttemptId,
        'captureAttemptId',
        'Must not be empty.',
      );
    }
    if (_expectedAttemptId != null) {
      throw StateError('The prior capture attempt has not been flushed.');
    }
    _expectedAttemptId = attemptId;
    _commands!.send(<Object?>['beginAttempt', attemptId]);
    _setState(
      StreamingAsrState(
        status: StreamingAsrStatus.ready,
        hasRecognizedSpeech: _state.hasRecognizedSpeech,
        captureAttemptId: attemptId,
      ),
    );
  }

  @override
  void addAudio(AudioFrame frame) {
    if (_closed || _closing) {
      throw StateError('The streaming ASR session is closing.');
    }
    if (_state.status == StreamingAsrStatus.failed) {
      throw StreamingAsrException(
        _state.errorCode ?? StreamingAsrErrorCode.recognitionFailed,
      );
    }
    if (frame.sessionId != sessionId || frame.sourceId != sourceId) {
      return;
    }
    final expectedAttempt = _expectedAttemptId;
    if (expectedAttempt == null || frame.captureAttemptId != expectedAttempt) {
      // Native stream callbacks from a previous pause/resume attempt are stale.
      return;
    }
    final previousSequence = _lastSequenceByAttempt[expectedAttempt];
    if (previousSequence != null && frame.sequence <= previousSequence) {
      _fail(StreamingAsrErrorCode.workerProtocolError);
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }
    _lastSequenceByAttempt[expectedAttempt] = frame.sequence;
    final hasSequenceGap =
        previousSequence != null && frame.sequence != previousSequence + 1;
    final discontinuity = frame.hasDiscontinuityBefore || hasSequenceGap;
    if (_pendingFrames.length >= maxQueuedFrames) {
      _pendingFrames.clear();
      _fail(StreamingAsrErrorCode.audioBackpressure);
      throw const StreamingAsrException(
        StreamingAsrErrorCode.audioBackpressure,
      );
    }

    final frameId = ++_nextFrameId;
    _pendingFrames.add(
      _QueuedAudioFrame(
        id: frameId,
        frame: frame,
        hasDiscontinuityBefore: discontinuity,
      ),
    );
    _setState(
      StreamingAsrState(
        status: StreamingAsrStatus.recognizing,
        hasRecognizedSpeech: _state.hasRecognizedSpeech,
        captureAttemptId: expectedAttempt,
      ),
    );
    _pump();
  }

  @override
  Future<void> finishCaptureAttempt(String captureAttemptId) async {
    final attemptId = captureAttemptId.trim();
    if (_closed || _state.status == StreamingAsrStatus.failed) return;
    if (_expectedAttemptId != attemptId) return;
    await _drainAudioFrames();
    if (_state.status == StreamingAsrStatus.failed) return;

    final ack = Completer<void>();
    _attemptFinishAcks[attemptId] = ack;
    _setState(
      StreamingAsrState(
        status: StreamingAsrStatus.flushing,
        hasRecognizedSpeech: _state.hasRecognizedSpeech,
        captureAttemptId: attemptId,
      ),
    );
    _commands!.send(<Object?>['finishAttempt', attemptId]);
    try {
      await ack.future.timeout(workerTimeout);
      if (_state.status == StreamingAsrStatus.failed) {
        throw StreamingAsrException(
          _state.errorCode ?? StreamingAsrErrorCode.recognitionFailed,
        );
      }
      _expectedAttemptId = null;
      _attemptFinishAcks.remove(attemptId);
      _setState(
        StreamingAsrState(
          status: StreamingAsrStatus.ready,
          hasRecognizedSpeech: _state.hasRecognizedSpeech,
        ),
      );
    } on TimeoutException {
      _fail(StreamingAsrErrorCode.workerTimedOut);
      rethrow;
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) {
      if (_state.status == StreamingAsrStatus.failed) {
        throw StreamingAsrException(
          _state.errorCode ?? StreamingAsrErrorCode.recognitionFailed,
        );
      }
      return;
    }
    try {
      if (_state.status == StreamingAsrStatus.failed) {
        throw StreamingAsrException(
          _state.errorCode ?? StreamingAsrErrorCode.recognitionFailed,
        );
      }
      _closing = true;
      await _drainAudioFrames();
      if (_state.status == StreamingAsrStatus.failed) {
        throw StreamingAsrException(
          _state.errorCode ?? StreamingAsrErrorCode.recognitionFailed,
        );
      }
      _setState(
        StreamingAsrState(
          status: StreamingAsrStatus.flushing,
          hasRecognizedSpeech: _state.hasRecognizedSpeech,
          captureAttemptId: _expectedAttemptId,
        ),
      );
      _commands!.send(const <Object?>['close']);
      try {
        await _workerCloseAck.future.timeout(workerTimeout);
      } on TimeoutException {
        _fail(StreamingAsrErrorCode.workerTimedOut);
        rethrow;
      }
      if (_state.status == StreamingAsrStatus.failed) {
        throw StreamingAsrException(
          _state.errorCode ?? StreamingAsrErrorCode.recognitionFailed,
        );
      }
    } finally {
      if (_state.status == StreamingAsrStatus.failed) {
        await _requestWorkerDisposal();
      }
      _closed = true;
      _closing = true;
      if (_state.status != StreamingAsrStatus.failed) {
        _setState(
          StreamingAsrState(
            status: StreamingAsrStatus.closed,
            hasRecognizedSpeech: _state.hasRecognizedSpeech,
          ),
        );
      }
      await _releasePorts();
      await _releaseControllers();
    }
  }

  Future<void> _releasePorts() async {
    await _workerSubscription?.cancel();
    await _exitSubscription?.cancel();
    _workerMessages.close();
    _workerExit.close();
  }

  Future<void> _releaseControllers() async {
    if (!_revisionController.isClosed) await _revisionController.close();
    if (!_stateController.isClosed) await _stateController.close();
  }

  Future<void> _requestWorkerDisposal() =>
      _workerDisposeFuture ??= _disposeWorkerAfterFailure();

  Future<void> _disposeWorkerAfterFailure() async {
    final isolate = _isolate;
    if (isolate == null) return;
    final commands = _commands;
    if (commands == null) {
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    try {
      commands.send(const <Object?>['abort']);
      await _workerCleanupAck.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // The worker did not acknowledge resource cleanup promptly.
    } catch (_) {
      // A closed command port is equivalent to a failed cleanup handshake.
    }
    isolate.kill(priority: Isolate.immediate);
  }

  Future<void> _drainAudioFrames() async {
    while ((_pendingFrames.isNotEmpty || _pumping) &&
        _state.status != StreamingAsrStatus.failed) {
      final inFlight = _inFlightAck;
      if (inFlight != null) {
        await inFlight.future;
      } else if (_pumping) {
        await Future<void>.delayed(Duration.zero);
      } else {
        _pump();
      }
    }
  }

  void _pump() {
    if (_pumping ||
        _closed ||
        _state.status == StreamingAsrStatus.failed ||
        _pendingFrames.isEmpty) {
      return;
    }
    unawaited(_pumpNext());
  }

  Future<void> _pumpNext() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pendingFrames.isNotEmpty &&
          _state.status != StreamingAsrStatus.failed) {
        final queued = _pendingFrames.removeFirst();
        final frame = queued.frame;
        final ack = Completer<void>();
        _inFlightAck = ack;
        _inFlightFrameId = queued.id;
        _commands!.send(<Object?>[
          'audioFrame',
          queued.id,
          frame.captureAttemptId,
          frame.startTimeUs,
          frame.sampleRateHz,
          frame.channelCount,
          frame.sampleCount,
          frame.sampleFormat.name,
          queued.hasDiscontinuityBefore,
          TransferableTypedData.fromList(<Uint8List>[frame.pcmBytes]),
        ]);
        try {
          await ack.future.timeout(workerTimeout);
        } on TimeoutException {
          _fail(StreamingAsrErrorCode.workerTimedOut);
          return;
        } finally {
          if (identical(_inFlightAck, ack)) {
            _inFlightAck = null;
            _inFlightFrameId = null;
          }
        }
      }
    } catch (_) {
      _fail(StreamingAsrErrorCode.workerProtocolError);
    } finally {
      _pumping = false;
      if (_pendingFrames.isNotEmpty) _pump();
    }
  }

  void _onWorkerMessage(Object? message) {
    if (message is! List<Object?> || message.isEmpty) {
      _fail(StreamingAsrErrorCode.workerProtocolError);
      return;
    }
    switch (message.first) {
      case 'commandPort':
        if (message.length == 2 && message[1] is SendPort) {
          _commands = message[1] as SendPort;
        } else {
          _fail(StreamingAsrErrorCode.workerProtocolError);
        }
        break;
      case 'ready':
        if (message.length != 1 || _commands == null) {
          _fail(StreamingAsrErrorCode.workerProtocolError);
          break;
        }
        if (!_workerReady.isCompleted) {
          _workerReady.complete();
          _setState(
            StreamingAsrState(
              status: StreamingAsrStatus.ready,
              hasRecognizedSpeech: false,
            ),
          );
        }
        break;
      case 'transcript':
        _applyWorkerTranscript(message);
        break;
      case 'frameDone':
        if (message.length == 2 && message[1] == _inFlightFrameId) {
          final ack = _inFlightAck;
          if (ack != null && !ack.isCompleted) ack.complete();
        } else {
          _fail(StreamingAsrErrorCode.workerProtocolError);
        }
        break;
      case 'attemptFinished':
        if (message.length == 2 && message[1] is String) {
          final ack = _attemptFinishAcks[message[1]! as String];
          if (ack != null && !ack.isCompleted) ack.complete();
        } else {
          _fail(StreamingAsrErrorCode.workerProtocolError);
        }
        break;
      case 'closed':
        if (message.length == 1) {
          if (!_workerCloseAck.isCompleted) _workerCloseAck.complete();
          if (!_workerCleanupAck.isCompleted) _workerCleanupAck.complete();
        } else {
          _fail(StreamingAsrErrorCode.workerProtocolError);
        }
        break;
      case 'aborted':
        if (message.length == 1) {
          if (!_workerCleanupAck.isCompleted) _workerCleanupAck.complete();
        } else {
          _fail(StreamingAsrErrorCode.workerProtocolError);
        }
        break;
      case 'fatal':
        if (message.length == 2 && message[1] is String) {
          _fail(_errorFromName(message[1]), workerAlreadyCleaned: true);
        } else {
          _fail(StreamingAsrErrorCode.workerProtocolError);
        }
        break;
      default:
        _fail(StreamingAsrErrorCode.workerProtocolError);
    }
  }

  void _applyWorkerTranscript(List<Object?> message) {
    if (_state.status == StreamingAsrStatus.failed || _closed) return;
    if (message.length != 9) {
      _fail(StreamingAsrErrorCode.workerProtocolError);
      return;
    }
    try {
      final revision = TranscriptRevision(
        sessionId: sessionId,
        captureAttemptId: message[1]! as String,
        segmentId: message[2]! as String,
        sourceId: sourceId,
        sourceKind: sourceKind,
        startMs: message[3]! as int,
        endMs: message[4]! as int,
        text: message[5]! as String,
        languageCode: message[6]! as String,
        revision: message[7]! as int,
        isFinal: message[8]! as bool,
      );
      if (_expectedAttemptId != null &&
          revision.captureAttemptId != _expectedAttemptId &&
          !_attemptFinishAcks.containsKey(revision.captureAttemptId)) {
        return;
      }
      if (!_revisionController.isClosed) _revisionController.add(revision);
      _setState(
        StreamingAsrState(
          status: _state.status == StreamingAsrStatus.flushing
              ? StreamingAsrStatus.flushing
              : StreamingAsrStatus.recognizing,
          hasRecognizedSpeech: true,
          captureAttemptId: revision.captureAttemptId,
        ),
      );
    } catch (_) {
      _fail(StreamingAsrErrorCode.workerProtocolError);
    }
  }

  void _fail(StreamingAsrErrorCode code, {bool workerAlreadyCleaned = false}) {
    if (_state.status == StreamingAsrStatus.failed || _closed) return;
    _pendingFrames.clear();
    _setState(
      StreamingAsrState(
        status: StreamingAsrStatus.failed,
        errorCode: code,
        hasRecognizedSpeech: _state.hasRecognizedSpeech,
        captureAttemptId: _expectedAttemptId,
      ),
    );
    final ack = _inFlightAck;
    if (ack != null && !ack.isCompleted) ack.complete();
    for (final completer in _attemptFinishAcks.values) {
      if (!completer.isCompleted) completer.complete();
    }
    if (!_workerReady.isCompleted) {
      _workerReady.completeError(StreamingAsrException(code));
    }
    if (!_workerCloseAck.isCompleted) _workerCloseAck.complete();
    if (workerAlreadyCleaned) {
      if (!_workerCleanupAck.isCompleted) _workerCleanupAck.complete();
    } else {
      unawaited(_requestWorkerDisposal());
    }
  }

  void _setState(StreamingAsrState state) {
    _state = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }
}

final class _QueuedAudioFrame {
  const _QueuedAudioFrame({
    required this.id,
    required this.frame,
    required this.hasDiscontinuityBefore,
  });

  final int id;
  final AudioFrame frame;
  final bool hasDiscontinuityBefore;
}

Map<String, File> _modelFiles(Directory directory) => <String, File>{
  'encoder': File(
    '${directory.path}${Platform.pathSeparator}encoder-epoch-99-avg-1.int8.onnx',
  ),
  'decoder': File(
    '${directory.path}${Platform.pathSeparator}decoder-epoch-99-avg-1.onnx',
  ),
  'joiner': File(
    '${directory.path}${Platform.pathSeparator}joiner-epoch-99-avg-1.onnx',
  ),
  'tokens': File('${directory.path}${Platform.pathSeparator}tokens.txt'),
};

Map<String, File> _multilingualModelFiles(MultilingualAsrModelAssets assets) =>
    <String, File>{
      'encoder': assets.encoder,
      'decoder': assets.decoder,
      'tokens': assets.tokens,
      'vad': assets.vad,
    };

String _primaryLanguageCode(String languageCode) {
  final normalized = languageCode.trim().toLowerCase().replaceAll('_', '-');
  if (normalized == 'auto' || normalized == 'automatic') return 'auto';
  final registered = AsrLanguageRegistry.normalizeCode(normalized);
  if (registered != null) return registered;
  final primary = normalized.split('-').first;
  return switch (primary) {
    'eng' || 'english' => 'en',
    'cmn' || 'zho' || 'chinese' || 'mandarin' => 'zh',
    _ => primary,
  };
}

StreamingAsrErrorCode _errorFromName(Object? name) {
  if (name is! String) return StreamingAsrErrorCode.runtimeInitializationFailed;
  return StreamingAsrErrorCode.values.firstWhere(
    (value) => value.name == name,
    orElse: () => StreamingAsrErrorCode.runtimeInitializationFailed,
  );
}

void _sherpaWorkerEntry(List<Object?> args) {
  unawaited(_runSherpaWorker(args));
}

Future<void> _runSherpaWorker(List<Object?> args) async {
  if (args.length == 9 && args[6] == 'whisper') {
    await _runSherpaWhisperWorker(args);
    return;
  }

  final SendPort events = args[0]! as SendPort;
  final encoderPath = args[1]! as String;
  final decoderPath = args[2]! as String;
  final joinerPath = args[3]! as String;
  final tokensPath = args[4]! as String;
  final numThreads = args[5]! as int;
  final commands = ReceivePort();
  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  String? activeAttemptId;
  int segmentOrdinal = 0;
  int segmentRevision = 0;
  int? segmentStartUs;
  int? lastFrameEndUs;
  String lastText = '';
  var closed = false;
  var resourcesReleased = false;

  void disposeWorkerResources() {
    if (resourcesReleased) return;
    resourcesReleased = true;
    final currentStream = stream;
    stream = null;
    try {
      currentStream?.free();
    } catch (_) {
      // Keep releasing the recognizer even if stream disposal fails.
    }
    final currentRecognizer = recognizer;
    recognizer = null;
    try {
      currentRecognizer?.free();
    } catch (_) {
      // Native handles are released on a best-effort basis during failure.
    }
    activeAttemptId = null;
  }

  void failWorker(StreamingAsrErrorCode code) {
    if (closed) return;
    closed = true;
    disposeWorkerResources();
    commands.close();
    events.send(<Object?>['fatal', code.name]);
  }

  void resetSegment({required bool nextSegment}) {
    if (nextSegment) segmentOrdinal += 1;
    segmentRevision = 0;
    segmentStartUs = null;
    lastFrameEndUs = null;
    lastText = '';
  }

  void emitText(String text, {required bool isFinal}) {
    final normalized = resolveStreamingAsrText(
      decodedText: text,
      previousText: lastText,
      isFinal: isFinal,
    );
    if (normalized == null) return;
    if (!isFinal && normalized == lastText) return;
    final startUs = segmentStartUs ?? lastFrameEndUs ?? 0;
    final endUs = lastFrameEndUs ?? startUs + 1000;
    segmentRevision += 1;
    lastText = normalized;
    events.send(<Object?>[
      'transcript',
      activeAttemptId,
      '$activeAttemptId:$segmentOrdinal',
      startUs ~/ 1000,
      (endUs > startUs ? endUs : startUs + 1000) ~/ 1000,
      normalized,
      args[7]! as String,
      segmentRevision,
      isFinal,
    ]);
  }

  void decodeAvailable() {
    final currentRecognizer = recognizer;
    final currentStream = stream;
    if (currentRecognizer == null || currentStream == null) return;
    while (currentRecognizer.isReady(currentStream)) {
      currentRecognizer.decode(currentStream);
    }
  }

  void createStream(String attemptId) {
    stream = recognizer!.createStream();
    activeAttemptId = attemptId;
    resetSegment(nextSegment: false);
  }

  void finishStream({required bool appendTail, required bool keepAttempt}) {
    final currentRecognizer = recognizer;
    final currentStream = stream;
    if (currentRecognizer == null || currentStream == null) {
      if (!keepAttempt) activeAttemptId = null;
      return;
    }

    if (appendTail) {
      currentStream.acceptWaveform(
        samples: Float32List(12800),
        sampleRate: 16000,
      );
    }
    currentStream.inputFinished();
    decodeAvailable();
    final result = currentRecognizer.getResult(currentStream);
    emitText(result.text, isFinal: true);
    currentStream.free();
    stream = null;
    resetSegment(nextSegment: true);

    if (keepAttempt && activeAttemptId != null) {
      createStream(activeAttemptId!);
    } else {
      activeAttemptId = null;
    }
  }

  void processAudioFrame(List<Object?> message) {
    if (message.length != 10) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }
    final frameId = message[1]! as int;
    final attemptId = message[2]! as String;
    final startTimeUs = message[3]! as int;
    final sampleRateHz = message[4]! as int;
    final channelCount = message[5]! as int;
    final sampleCount = message[6]! as int;
    final sampleFormat = message[7]! as String;
    final discontinuity = message[8]! as bool;
    final transfer = message[9]! as TransferableTypedData;

    if (activeAttemptId != attemptId) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }
    if (discontinuity && segmentStartUs != null) {
      finishStream(appendTail: true, keepAttempt: true);
    }
    final currentStream = stream;
    final currentRecognizer = recognizer;
    if (currentStream == null || currentRecognizer == null) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }

    final bytes = transfer.materialize().asUint8List();
    final samples = _toMonoFloat32(
      bytes,
      sampleCount: sampleCount,
      channelCount: channelCount,
      sampleFormat: sampleFormat,
    );
    segmentStartUs ??= startTimeUs;
    lastFrameEndUs =
        startTimeUs +
        (sampleCount * Duration.microsecondsPerSecond / sampleRateHz).round();
    currentStream.acceptWaveform(samples: samples, sampleRate: sampleRateHz);
    decodeAvailable();

    final result = currentRecognizer.getResult(currentStream);
    emitText(result.text, isFinal: false);
    if (currentRecognizer.isEndpoint(currentStream)) {
      emitText(result.text, isFinal: true);
      currentRecognizer.reset(currentStream);
      resetSegment(nextSegment: true);
    }
    events.send(<Object?>['frameDone', frameId]);
  }

  try {
    await sherpa.initBindingsAsync();
    final model = sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: encoderPath,
        decoder: decoderPath,
        joiner: joinerPath,
      ),
      tokens: tokensPath,
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
      modelType: 'zipformer',
    );
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: model,
        enableEndpoint: true,
        ruleFsts: '',
      ),
    );
    events.send(<Object?>['commandPort', commands.sendPort]);
    events.send(const <Object?>['ready']);
    commands.listen((dynamic rawMessage) {
      if (closed) return;
      try {
        if (rawMessage is! List<Object?> || rawMessage.isEmpty) {
          throw const StreamingAsrException(
            StreamingAsrErrorCode.workerProtocolError,
          );
        }
        switch (rawMessage.first) {
          case 'beginAttempt':
            if (rawMessage.length != 2 ||
                rawMessage[1] is! String ||
                stream != null) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            createStream(rawMessage[1]! as String);
            break;
          case 'audioFrame':
            if (rawMessage.length != 10 ||
                rawMessage[1] is! int ||
                rawMessage[2] is! String ||
                rawMessage[3] is! int ||
                rawMessage[4] is! int ||
                rawMessage[5] is! int ||
                rawMessage[6] is! int ||
                rawMessage[7] is! String ||
                rawMessage[8] is! bool ||
                rawMessage[9] is! TransferableTypedData) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            processAudioFrame(rawMessage);
            break;
          case 'finishAttempt':
            if (rawMessage.length != 2 || rawMessage[1] is! String) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            final attemptId = rawMessage[1]! as String;
            if (activeAttemptId != attemptId) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            finishStream(appendTail: true, keepAttempt: false);
            events.send(<Object?>['attemptFinished', attemptId]);
            break;
          case 'close':
            if (rawMessage.length != 1) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            finishStream(appendTail: true, keepAttempt: false);
            closed = true;
            disposeWorkerResources();
            commands.close();
            events.send(const <Object?>['closed']);
            break;
          case 'abort':
            if (rawMessage.length != 1) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            closed = true;
            disposeWorkerResources();
            commands.close();
            events.send(const <Object?>['aborted']);
            break;
          default:
            throw const StreamingAsrException(
              StreamingAsrErrorCode.workerProtocolError,
            );
        }
      } on StreamingAsrException catch (error) {
        failWorker(error.code);
      } catch (_) {
        failWorker(StreamingAsrErrorCode.recognitionFailed);
      }
    });
  } catch (_) {
    failWorker(StreamingAsrErrorCode.runtimeInitializationFailed);
  }
}

/// Offline Whisper worker for registered non-English/non-Chinese languages
/// and Auto recognition.
///
/// Silero VAD turns the incoming 16 kHz mono stream into bounded utterances;
/// each utterance is decoded once and emitted as a final subtitle revision.
/// This path intentionally makes no frame-level interim-caption claim.
Future<void> _runSherpaWhisperWorker(List<Object?> args) async {
  final SendPort events = args[0]! as SendPort;
  final encoderPath = args[1]! as String;
  final decoderPath = args[2]! as String;
  final tokensPath = args[4]! as String;
  final numThreads = args[5]! as int;
  final selectedLanguage = args[7]! as String;
  final vadPath = args[8]! as String;
  final isAuto = selectedLanguage == 'auto';

  final commands = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  String? activeAttemptId;
  int segmentOrdinal = 0;
  int? attemptBaseTimeUs;
  int? lastFrameEndUs;
  bool closed = false;
  bool resourcesReleased = false;

  void disposeWorkerResources() {
    if (resourcesReleased) return;
    resourcesReleased = true;
    final currentVad = vad;
    vad = null;
    try {
      currentVad?.free();
    } catch (_) {
      // Keep freeing the recognizer when VAD disposal fails.
    }
    final currentRecognizer = recognizer;
    recognizer = null;
    try {
      currentRecognizer?.free();
    } catch (_) {
      // Native handles are released on a best-effort basis during failure.
    }
    activeAttemptId = null;
  }

  void failWorker(StreamingAsrErrorCode code) {
    if (closed) return;
    closed = true;
    disposeWorkerResources();
    commands.close();
    events.send(<Object?>['fatal', code.name]);
  }

  void emitSpeechSegment(sherpa.SpeechSegment segment) {
    final currentRecognizer = recognizer;
    final attemptId = activeAttemptId;
    if (currentRecognizer == null || attemptId == null) return;
    final samples = segment.samples;
    if (samples.isEmpty) return;

    sherpa.OfflineStream? stream;
    try {
      stream = currentRecognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      currentRecognizer.decode(stream);
      final result = currentRecognizer.getResult(stream);
      final text = result.text.trim();
      final detectedCode = AsrLanguageRegistry.normalizeCode(result.lang);
      final languageCode = isAuto ? (detectedCode ?? 'und') : selectedLanguage;
      final segmentStartUs =
          (attemptBaseTimeUs ?? lastFrameEndUs ?? 0) +
          (segment.start * Duration.microsecondsPerSecond / 16000).round();
      final segmentEndUs =
          segmentStartUs +
          (samples.length * Duration.microsecondsPerSecond / 16000).round();
      if (text.isNotEmpty) {
        segmentOrdinal += 1;
        events.send(<Object?>[
          'transcript',
          attemptId,
          '$attemptId:$segmentOrdinal',
          segmentStartUs ~/ 1000,
          (segmentEndUs > segmentStartUs
                  ? segmentEndUs
                  : segmentStartUs + 1000) ~/
              1000,
          text,
          languageCode,
          1,
          true,
        ]);
      }
    } finally {
      stream?.free();
    }
  }

  void drainVad() {
    final currentVad = vad;
    if (currentVad == null) return;
    while (!currentVad.isEmpty()) {
      final segment = currentVad.front();
      currentVad.pop();
      emitSpeechSegment(segment);
    }
  }

  void flushAttempt() {
    final currentVad = vad;
    if (currentVad == null) return;
    currentVad.flush();
    drainVad();
    currentVad.reset();
    attemptBaseTimeUs = null;
    lastFrameEndUs = null;
  }

  void processAudioFrame(List<Object?> message) {
    if (message.length != 10) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }
    final frameId = message[1]! as int;
    final attemptId = message[2]! as String;
    final startTimeUs = message[3]! as int;
    final sampleRateHz = message[4]! as int;
    final channelCount = message[5]! as int;
    final sampleCount = message[6]! as int;
    final sampleFormat = message[7]! as String;
    final discontinuity = message[8]! as bool;
    final transfer = message[9]! as TransferableTypedData;

    if (activeAttemptId != attemptId || sampleRateHz <= 0) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }
    if (discontinuity) {
      flushAttempt();
    }
    final bytes = transfer.materialize().asUint8List();
    final samples = _toMonoFloat32(
      bytes,
      sampleCount: sampleCount,
      channelCount: channelCount,
      sampleFormat: sampleFormat,
    );
    final samples16k = _resampleMonoTo16k(samples, sampleRateHz);
    attemptBaseTimeUs ??= startTimeUs;
    lastFrameEndUs =
        startTimeUs +
        (sampleCount * Duration.microsecondsPerSecond / sampleRateHz).round();
    if (samples16k.isNotEmpty) {
      vad!.acceptWaveform(samples16k);
      drainVad();
    }
    events.send(<Object?>['frameDone', frameId]);
  }

  try {
    if (args.length != 9 ||
        !isAuto &&
            (!AsrLanguageRegistry.isSupportedCode(selectedLanguage) ||
                selectedLanguage == 'en' ||
                selectedLanguage == 'zh')) {
      throw const StreamingAsrException(
        StreamingAsrErrorCode.workerProtocolError,
      );
    }
    await sherpa.initBindingsAsync();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: encoderPath,
            decoder: decoderPath,
            language: isAuto ? '' : selectedLanguage,
            task: 'transcribe',
          ),
          tokens: tokensPath,
          numThreads: numThreads,
          provider: 'cpu',
          modelType: 'whisper',
          debug: false,
        ),
      ),
    );
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          minSilenceDuration: 0.6,
          maxSpeechDuration: 15,
          windowSize: 512,
        ),
        sampleRate: 16000,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    events.send(<Object?>['commandPort', commands.sendPort]);
    events.send(const <Object?>['ready']);
    commands.listen((dynamic rawMessage) {
      if (closed) return;
      try {
        if (rawMessage is! List<Object?> || rawMessage.isEmpty) {
          throw const StreamingAsrException(
            StreamingAsrErrorCode.workerProtocolError,
          );
        }
        switch (rawMessage.first) {
          case 'beginAttempt':
            if (rawMessage.length != 2 ||
                rawMessage[1] is! String ||
                activeAttemptId != null) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            activeAttemptId = rawMessage[1]! as String;
            segmentOrdinal = 0;
            attemptBaseTimeUs = null;
            lastFrameEndUs = null;
            vad!.reset();
            break;
          case 'audioFrame':
            if (rawMessage.length != 10 ||
                rawMessage[1] is! int ||
                rawMessage[2] is! String ||
                rawMessage[3] is! int ||
                rawMessage[4] is! int ||
                rawMessage[5] is! int ||
                rawMessage[6] is! int ||
                rawMessage[7] is! String ||
                rawMessage[8] is! bool ||
                rawMessage[9] is! TransferableTypedData) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            processAudioFrame(rawMessage);
            break;
          case 'finishAttempt':
            if (rawMessage.length != 2 ||
                rawMessage[1] is! String ||
                activeAttemptId != rawMessage[1]) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            final attemptId = activeAttemptId!;
            flushAttempt();
            activeAttemptId = null;
            events.send(<Object?>['attemptFinished', attemptId]);
            break;
          case 'close':
            if (rawMessage.length != 1) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            flushAttempt();
            activeAttemptId = null;
            closed = true;
            disposeWorkerResources();
            commands.close();
            events.send(const <Object?>['closed']);
            break;
          case 'abort':
            if (rawMessage.length != 1) {
              throw const StreamingAsrException(
                StreamingAsrErrorCode.workerProtocolError,
              );
            }
            closed = true;
            disposeWorkerResources();
            commands.close();
            events.send(const <Object?>['aborted']);
            break;
          default:
            throw const StreamingAsrException(
              StreamingAsrErrorCode.workerProtocolError,
            );
        }
      } on StreamingAsrException catch (error) {
        failWorker(error.code);
      } catch (_) {
        failWorker(StreamingAsrErrorCode.recognitionFailed);
      }
    });
  } on StreamingAsrException catch (error) {
    failWorker(error.code);
  } catch (_) {
    failWorker(StreamingAsrErrorCode.runtimeInitializationFailed);
  }
}

Float32List _resampleMonoTo16k(Float32List samples, int sourceSampleRate) {
  if (sourceSampleRate <= 0) {
    throw const StreamingAsrException(
      StreamingAsrErrorCode.audioFormatUnsupported,
    );
  }
  if (sourceSampleRate == 16000) return samples;
  if (samples.isEmpty) return Float32List(0);

  final outputLength = (samples.length * 16000 / sourceSampleRate).round();
  if (outputLength <= 0) return Float32List(0);
  final output = Float32List(outputLength);
  final scale = sourceSampleRate / 16000;
  for (var index = 0; index < outputLength; index += 1) {
    final sourcePosition = index * scale;
    final left = sourcePosition.floor().clamp(0, samples.length - 1);
    final right = (left + 1).clamp(0, samples.length - 1);
    final fraction = sourcePosition - left;
    output[index] = samples[left] * (1 - fraction) + samples[right] * fraction;
  }
  return output;
}

Float32List _toMonoFloat32(
  Uint8List bytes, {
  required int sampleCount,
  required int channelCount,
  required String sampleFormat,
}) {
  AudioPcmSampleFormat? format;
  for (final candidate in AudioPcmSampleFormat.values) {
    if (candidate.name == sampleFormat) {
      format = candidate;
      break;
    }
  }
  if (format == null) {
    throw const StreamingAsrException(
      StreamingAsrErrorCode.audioFormatUnsupported,
    );
  }
  final expectedLength = sampleCount * channelCount * format.bytesPerSample;
  if (sampleCount <= 0 || channelCount <= 0 || bytes.length != expectedLength) {
    throw const StreamingAsrException(
      StreamingAsrErrorCode.audioFormatUnsupported,
    );
  }

  final data = ByteData.sublistView(bytes);
  final mono = Float32List(sampleCount);
  for (var frame = 0; frame < sampleCount; frame++) {
    var sum = 0.0;
    final firstSample = frame * channelCount;
    for (var channel = 0; channel < channelCount; channel++) {
      final sampleIndex = firstSample + channel;
      final sample = switch (format) {
        AudioPcmSampleFormat.signedInt16LittleEndian =>
          data.getInt16(sampleIndex * 2, Endian.little) / 32768.0,
        AudioPcmSampleFormat.float32LittleEndian => data.getFloat32(
          sampleIndex * 4,
          Endian.little,
        ),
      };
      sum += sample.isFinite ? sample.clamp(-1.0, 1.0).toDouble() : 0.0;
    }
    mono[frame] = (sum / channelCount).clamp(-1.0, 1.0).toDouble();
  }
  return mono;
}
