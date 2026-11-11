import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef LearningSpeechResultCallback = void Function(
  String recognizedText,
  bool isFinal,
);

/// Small seam around the platform speech recognizer so the learning page can
/// be tested without opening a microphone.
abstract interface class LearningSpeechRecognizer {
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String message) onError,
  });

  Future<void> listen({
    required String localeId,
    required LearningSpeechResultCallback onResult,
  });

  Future<void> stop();

  bool get isListening;

  Future<void> dispose();
}

/// Windows-capable system recognizer used by the preview app.
///
/// Recognition is short and on-device is requested. The app only persists
/// the resulting score and recognized text is kept in widget state, not in a
/// recording file.
final class SystemLearningSpeechRecognizer
    implements LearningSpeechRecognizer {
  SystemLearningSpeechRecognizer({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  Future<bool>? _initializing;
  var _initialized = false;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String message) onError,
  }) async {
    if (_initialized) return true;
    final pending = _initializing;
    if (pending != null) return pending;
    final future = _initialize(onStatus: onStatus, onError: onError);
    _initializing = future;
    try {
      return await future;
    } finally {
      _initializing = null;
    }
  }

  Future<bool> _initialize({
    required void Function(String status) onStatus,
    required void Function(String message) onError,
  }) async {
    try {
      final available = await _speech.initialize(
        onStatus: onStatus,
        onError: (error) => onError(error.errorMsg),
        debugLogging: false,
      );
      _initialized = available;
      return available;
    } catch (error) {
      onError('$error');
      return false;
    }
  }

  @override
  Future<void> listen({
    required String localeId,
    required LearningSpeechResultCallback onResult,
  }) async {
    if (!_initialized) return;
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        onResult(result.recognizedWords, result.finalResult);
      },
      listenOptions: SpeechListenOptions(
        cancelOnError: true,
        partialResults: true,
        onDevice: true,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 3),
        localeId: localeId,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<void> dispose() async {
    if (_speech.isListening) await _speech.stop();
  }
}
