import 'dart:async';
import 'dart:convert';

import 'package:yixue_app/core/dictionary_service.dart';

/// Roles carried in a child engine's startup arguments.
enum ScreenshotTranslationWindowRole { orb, result }

/// Orders session updates that may arrive through different host handles.
/// A newer connection generation always supersedes an older handle; sequence
/// numbers order messages sent through the same handle.
final class ScreenshotTranslationWindowUpdateStamp {
  const ScreenshotTranslationWindowUpdateStamp({
    required this.connectionGeneration,
    required this.updateSequence,
  });

  final int connectionGeneration;
  final int updateSequence;

  bool isAfter(ScreenshotTranslationWindowUpdateStamp other) =>
      connectionGeneration > other.connectionGeneration ||
      (connectionGeneration == other.connectionGeneration &&
          updateSequence > other.updateSequence);
}

enum ScreenshotTranslationHostEpochClaim { activated, unchanged, retired }

/// Tracks host-isolate handovers for a result child that outlives its host.
/// Epoch clocks order claims even when an older host's first probe arrives
/// after the newer host has already taken ownership. Legacy wall-clock tokens
/// rank below explicit wall-clock tokens, which rank below Windows QPC tokens.
final class ScreenshotTranslationWindowHostEpoch {
  String? _active;
  final Set<String> _retired = {};

  String? get active => _active;

  static int? _counter(String epoch) {
    final firstSeparator = epoch.indexOf('-');
    if (firstSeparator <= 0) return null;
    final prefix = epoch.substring(0, firstSeparator);
    if (prefix == 'qpc' || prefix == 'wall') {
      final secondSeparator = epoch.indexOf('-', firstSeparator + 1);
      if (secondSeparator <= firstSeparator + 1) return null;
      return int.tryParse(epoch.substring(firstSeparator + 1, secondSeparator));
    }
    // Before clock domains were explicit, epochs were <unix micros>-<random>.
    return int.tryParse(prefix);
  }

  static int _clockDomain(String epoch) {
    final firstSeparator = epoch.indexOf('-');
    final prefix = epoch.substring(0, firstSeparator);
    return switch (prefix) {
      'qpc' => 2,
      'wall' => 1,
      _ => 0,
    };
  }

  ScreenshotTranslationHostEpochClaim claim(String requested) {
    final requestedCounter = _counter(requested);
    if (requestedCounter == null || _retired.contains(requested)) {
      return ScreenshotTranslationHostEpochClaim.retired;
    }
    if (requested == _active) {
      return ScreenshotTranslationHostEpochClaim.unchanged;
    }
    final previous = _active;
    if (previous != null) {
      final activeCounter = _counter(previous);
      final sameClockDomain = _clockDomain(requested) == _clockDomain(previous);
      if (activeCounter == null ||
          _clockDomain(requested) < _clockDomain(previous) ||
          (sameClockDomain && requestedCounter <= activeCounter)) {
        return ScreenshotTranslationHostEpochClaim.retired;
      }
      _retired.add(previous);
    }
    _active = requested;
    return ScreenshotTranslationHostEpochClaim.activated;
  }

  bool accepts(Object? epoch) => epoch is String && epoch == _active;
}

final class ScreenshotTranslationWindowMessage {
  ScreenshotTranslationWindowMessage({
    this.version = protocolVersion,
    required this.type,
    required this.requestId,
    required this.payload,
  }) {
    if (version != protocolVersion) {
      throw FormatException('Unsupported screenshot window protocol: $version');
    }
    if (type.trim().isEmpty) {
      throw const FormatException('Message type is required');
    }
    if (requestId.trim().isEmpty) {
      throw const FormatException('Message requestId is required');
    }
    if (type == 'addScreenshotWord') {
      ScreenshotWordRequest.fromMessage(this);
    }
  }

  static const protocolVersion = 1;

  final int version;
  final String type;
  final String requestId;
  final Map<String, Object?> payload;

  /// Keep this as a codec map. JSON encoding would lose Uint8List image bytes.
  Map<String, Object?> toMap() => {
    'version': version,
    'type': type,
    'requestId': requestId,
    'payload': payload,
  };

  factory ScreenshotTranslationWindowMessage.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Screenshot window message must be a map');
    }
    final version = value['version'];
    final type = value['type'];
    final requestId = value['requestId'];
    final rawPayload = value['payload'];
    if (version != protocolVersion) {
      throw FormatException('Unsupported screenshot window protocol: $version');
    }
    if (type is! String || requestId is! String || rawPayload is! Map) {
      throw const FormatException('Malformed screenshot window message');
    }
    final payload = <String, Object?>{};
    for (final entry in rawPayload.entries) {
      if (entry.key is! String) {
        throw const FormatException('Message payload keys must be strings');
      }
      payload[entry.key as String] = entry.value;
    }
    return ScreenshotTranslationWindowMessage(
      version: version as int,
      type: type,
      requestId: requestId,
      payload: payload,
    );
  }
}

enum ScreenshotWordAddStatus { added, alreadyExists, meaningPending }

final class ScreenshotWordRequestException implements Exception {
  const ScreenshotWordRequestException(this.code);
  final String code;
}

Future<ScreenshotWordAddStatus> requestScreenshotWordAdd({
  required ScreenshotWordRequest request,
  required String requestId,
  required Future<Object?> Function(Map<String, Object?>) send,
}) async {
  final message = ScreenshotTranslationWindowMessage(
    type: 'addScreenshotWord',
    requestId: requestId,
    payload: request.toPayload(),
  );
  final ack = ScreenshotTranslationWindowMessage.fromMap(
    await send(message.toMap()),
  );
  if (ack.type != 'ack' || ack.requestId != requestId) {
    throw const FormatException('Missing screenshot word acknowledgement');
  }
  if (ack.payload['errorCode'] case final String code) {
    throw ScreenshotWordRequestException(code);
  }
  for (final status in ScreenshotWordAddStatus.values) {
    if (ack.payload['status'] == status.name) return status;
  }
  throw const FormatException('Invalid screenshot word status');
}

final class ScreenshotDictionaryExample {
  const ScreenshotDictionaryExample({
    required this.englishText,
    required this.chineseText,
    required this.reviewStatus,
  });

  final String englishText;
  final String chineseText;
  final String reviewStatus;
}

final class ScreenshotDictionaryLookupResult {
  const ScreenshotDictionaryLookupResult({
    required this.word,
    required this.ipa,
    required this.partOfSpeech,
    required this.meanings,
    required this.example,
    required this.exampleTranslation,
    required this.qualityStatus,
    required this.examples,
    this.variants = const [],
    this.collocations = const [],
    this.relations = const {},
  });

  final String word;
  final String ipa;
  final String partOfSpeech;
  final List<String> meanings;
  final String example;
  final String exampleTranslation;
  final String qualityStatus;
  final List<ScreenshotDictionaryExample> examples;
  final List<String> variants;
  final List<String> collocations;
  final Map<String, List<String>> relations;
}

final class ScreenshotDictionaryLookupRequest {
  const ScreenshotDictionaryLookupRequest({
    required this.sessionId,
    required this.word,
    required this.recognizedText,
  });

  final String sessionId;
  final String word;
  final String recognizedText;

  Map<String, Object?> toPayload() => {
    'sessionId': sessionId,
    'word': word,
    'recognizedText': recognizedText,
  };

  factory ScreenshotDictionaryLookupRequest.fromMessage(
    ScreenshotTranslationWindowMessage message,
  ) {
    const fields = {'sessionId', 'word', 'recognizedText'};
    final payload = message.payload;
    if (message.type != 'lookupScreenshotWord' ||
        payload.length != fields.length ||
        payload.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Invalid screenshot dictionary request');
    }
    String text(String key, int limit) {
      final value = payload[key];
      if (value is! String || value.trim().isEmpty || value.length > limit) {
        throw FormatException('Invalid screenshot dictionary field: $key');
      }
      return value;
    }

    final word = text('word', 32).trim();
    if (dictionaryTermAtInput(word) != word) {
      throw const FormatException('Select one valid dictionary term');
    }
    return ScreenshotDictionaryLookupRequest(
      sessionId: text('sessionId', 240),
      word: word,
      recognizedText: text('recognizedText', 100000),
    );
  }
}

Future<ScreenshotDictionaryLookupResult?> requestScreenshotDictionaryLookup({
  required ScreenshotDictionaryLookupRequest request,
  required String requestId,
  required Future<Object?> Function(Map<String, Object?>) send,
}) async {
  final message = ScreenshotTranslationWindowMessage(
    type: 'lookupScreenshotWord',
    requestId: requestId,
    payload: request.toPayload(),
  );
  final ack = ScreenshotTranslationWindowMessage.fromMap(
    await send(message.toMap()),
  );
  if (ack.type != 'ack' || ack.requestId != requestId) {
    throw const FormatException(
      'Missing screenshot dictionary acknowledgement',
    );
  }
  if (ack.payload['errorCode'] case final String code) {
    if (code == 'not_found') return null;
    throw ScreenshotWordRequestException(code);
  }
  final rawEntry = ack.payload['entry'];
  if (rawEntry is! Map || rawEntry.keys.any((key) => key is! String)) {
    throw const FormatException('Missing screenshot dictionary entry');
  }
  final entry = Map<String, Object?>.from(rawEntry);
  String text(String key, {required int maxLength}) {
    final value = entry[key];
    if (value is! String || value.length > maxLength) {
      throw FormatException('Invalid screenshot dictionary entry field: $key');
    }
    return value;
  }

  final rawMeanings = entry['meanings'];
  final rawExamples = entry['examples'];
  final rawVariants = entry['variants'] ?? const <Object?>[];
  final rawCollocations = entry['collocations'] ?? const <Object?>[];
  final rawRelations = entry['relations'] ?? const <String, Object?>{};
  if (rawMeanings is! List ||
      rawExamples is! List ||
      rawMeanings.length > 100 ||
      rawExamples.length > 100 ||
      rawVariants is! List ||
      rawCollocations is! List ||
      rawRelations is! Map ||
      rawVariants.length > 100 ||
      rawCollocations.length > 100 ||
      rawRelations.length > 100) {
    throw const FormatException('Invalid screenshot dictionary lists');
  }
  List<String> readTerms(List<dynamic> raw, String field) {
    if (raw.length > 100 ||
        raw.any((value) => value is! String || value.length > 512)) {
      throw FormatException('Invalid screenshot dictionary $field');
    }
    return List<String>.unmodifiable(raw.cast<String>());
  }

  final meanings = <String>[];
  for (final rawMeaning in rawMeanings) {
    if (rawMeaning is! String || rawMeaning.length > 4000) {
      throw const FormatException('Invalid screenshot dictionary meanings');
    }
    meanings.add(rawMeaning);
  }
  final relations = <String, List<String>>{};
  var relationTermCount = 0;
  for (final item in rawRelations.entries) {
    if (item.key is! String ||
        (item.key as String).length > 128 ||
        item.value is! List) {
      throw const FormatException('Invalid screenshot dictionary relations');
    }
    final terms = readTerms((item.value as List).cast<dynamic>(), 'relations');
    relationTermCount += terms.length;
    if (relationTermCount > 200) {
      throw const FormatException('Too many screenshot dictionary relations');
    }
    relations[item.key as String] = terms;
  }
  final examples = <ScreenshotDictionaryExample>[];
  for (final raw in rawExamples) {
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid screenshot dictionary example');
    }
    final example = Map<String, Object?>.from(raw);
    final english = example['englishText'];
    final chinese = example['chineseText'];
    final review = example['reviewStatus'];
    if (english is! String ||
        english.length > 10000 ||
        chinese is! String ||
        chinese.length > 10000 ||
        review is! String ||
        review.length > 128) {
      throw const FormatException('Invalid screenshot dictionary example');
    }
    examples.add(
      ScreenshotDictionaryExample(
        englishText: english,
        chineseText: chinese,
        reviewStatus: review,
      ),
    );
  }
  return ScreenshotDictionaryLookupResult(
    word: text('word', maxLength: 128),
    ipa: text('ipa', maxLength: 512),
    partOfSpeech: text('partOfSpeech', maxLength: 512),
    meanings: List.unmodifiable(meanings),
    example: text('example', maxLength: 10000),
    exampleTranslation: text('exampleTranslation', maxLength: 10000),
    qualityStatus: text('qualityStatus', maxLength: 128),
    examples: List.unmodifiable(examples),
    variants: readTerms(rawVariants.cast<dynamic>(), 'variants'),
    collocations: readTerms(rawCollocations.cast<dynamic>(), 'collocations'),
    relations: Map.unmodifiable(relations),
  );
}

/// Explicit request to translate one OCR word after the local dictionary misses.
/// It carries text only and is revalidated against the active screenshot session.
final class ScreenshotWordTranslationRequest {
  const ScreenshotWordTranslationRequest({
    required this.sessionId,
    required this.word,
    required this.recognizedText,
  });

  final String sessionId;
  final String word;
  final String recognizedText;

  Map<String, Object?> toPayload() => {
    'sessionId': sessionId,
    'word': word,
    'recognizedText': recognizedText,
  };

  factory ScreenshotWordTranslationRequest.fromMessage(
    ScreenshotTranslationWindowMessage message,
  ) {
    const fields = {'sessionId', 'word', 'recognizedText'};
    final payload = message.payload;
    if (message.type != 'translateScreenshotWord' ||
        payload.length != fields.length ||
        payload.keys.any((key) => !fields.contains(key))) {
      throw const FormatException(
        'Invalid screenshot word translation request',
      );
    }
    String text(String key, int limit) {
      final value = payload[key];
      if (value is! String || value.trim().isEmpty || value.length > limit) {
        throw FormatException(
          'Invalid screenshot word translation field: $key',
        );
      }
      return value;
    }

    final word = text('word', 32).trim();
    if (dictionaryTermAtInput(word) != word) {
      throw const FormatException('Select one valid dictionary term');
    }
    return ScreenshotWordTranslationRequest(
      sessionId: text('sessionId', 240),
      word: word,
      recognizedText: text('recognizedText', 100000),
    );
  }
}

Future<String> requestScreenshotWordTranslation({
  required ScreenshotWordTranslationRequest request,
  required String requestId,
  required Future<Object?> Function(Map<String, Object?>) send,
  Duration ackTimeout = screenshotWordTranslationAckTimeout,
}) async {
  if (ackTimeout <= Duration.zero) {
    throw ArgumentError.value(ackTimeout, 'ackTimeout');
  }
  final message = ScreenshotTranslationWindowMessage(
    type: 'translateScreenshotWord',
    requestId: requestId,
    payload: request.toPayload(),
  );
  late final Object? rawAck;
  try {
    rawAck = await send(message.toMap()).timeout(ackTimeout);
  } on TimeoutException {
    // Use the existing retryable UI state so a missing cross-window ACK does
    // not leave the selected word spinner active forever.
    throw const ScreenshotWordRequestException('translation_timeout');
  }
  final ack = ScreenshotTranslationWindowMessage.fromMap(rawAck);
  if (ack.type != 'ack' || ack.requestId != requestId) {
    throw const FormatException(
      'Missing screenshot word translation acknowledgement',
    );
  }
  if (ack.payload['errorCode'] case final String code) {
    throw ScreenshotWordRequestException(code);
  }
  final translation = ack.payload['translation'];
  if (translation is! String ||
      translation.trim().isEmpty ||
      translation.length > 10000) {
    throw const FormatException('Invalid screenshot word translation result');
  }
  return translation;
}

Future<bool> cancelScreenshotWordTranslation({
  required String operationId,
  required String requestId,
  required Future<Object?> Function(Map<String, Object?>) send,
  Duration ackTimeout = screenshotWordTranslationCancellationAckTimeout,
}) async {
  if (ackTimeout <= Duration.zero) {
    throw ArgumentError.value(ackTimeout, 'ackTimeout');
  }
  final message = ScreenshotTranslationWindowMessage(
    type: 'cancelScreenshotWordTranslation',
    requestId: requestId,
    payload: {'operationId': operationId},
  );
  late final Object? rawAck;
  try {
    rawAck = await send(message.toMap()).timeout(ackTimeout);
  } on TimeoutException {
    // False keeps the caller's existing recoverable "still processing" state
    // while allowing it to select another word and continue using the window.
    return false;
  }
  final ack = ScreenshotTranslationWindowMessage.fromMap(rawAck);
  if (ack.type != 'ack' || ack.requestId != requestId) {
    throw const FormatException(
      'Missing screenshot word translation cancellation acknowledgement',
    );
  }
  return ack.payload['cancelled'] == true;
}

/// The parent translation handler has a 45 second processing deadline. This
/// slightly longer child deadline lets its timeout/cancellation ACK arrive,
/// while still recovering if the cross-window message itself gets stuck.
const screenshotWordTranslationAckTimeout = Duration(seconds: 50);

/// Cancellation is a best-effort message; bound it so changing selection does
/// not keep the screenshot result window waiting for an absent parent ACK.
const screenshotWordTranslationCancellationAckTimeout = Duration(seconds: 3);

/// Text-only command. Child engines never receive a learning repository.
final class ScreenshotWordRequest {
  const ScreenshotWordRequest({
    required this.sessionId,
    required this.word,
    required this.recognizedText,
    required this.translatedText,
    required this.historyEntryId,
  });

  final String sessionId;
  final String word;
  final String recognizedText;
  final String translatedText;
  final String historyEntryId;

  Map<String, Object?> toPayload() => {
    'sessionId': sessionId,
    'word': word,
    'recognizedText': recognizedText,
    'translatedText': translatedText,
    'historyEntryId': historyEntryId,
  };

  factory ScreenshotWordRequest.fromMessage(
    ScreenshotTranslationWindowMessage message,
  ) {
    const fields = {
      'sessionId',
      'word',
      'recognizedText',
      'translatedText',
      'historyEntryId',
    };
    final payload = message.payload;
    if (message.type != 'addScreenshotWord' ||
        payload.length != fields.length ||
        payload.keys.any((key) => !fields.contains(key))) {
      // An allowlist also rejects imageBytes hidden in an extra nested field.
      throw const FormatException('Invalid screenshot word payload');
    }
    String text(String key, int limit, {bool allowEmpty = false}) {
      final value = payload[key];
      if (value is! String ||
          value.length > limit ||
          (!allowEmpty && value.trim().isEmpty)) {
        throw FormatException('Invalid screenshot word field: $key');
      }
      return value;
    }

    final word = text('word', 32);
    if (englishWordAtSelection(word, 0, word.length) != word) {
      throw const FormatException('Select one valid English word');
    }
    return ScreenshotWordRequest(
      sessionId: text('sessionId', 240),
      word: word,
      recognizedText: text('recognizedText', 100000),
      translatedText: text('translatedText', 100000, allowEmpty: true),
      historyEntryId: text('historyEntryId', 240),
    );
  }
}

final class ScreenshotTranslationWindowArguments {
  const ScreenshotTranslationWindowArguments({
    required this.role,
    required this.parentWindowId,
  });

  final ScreenshotTranslationWindowRole role;
  final String parentWindowId;

  String encode() => jsonEncode({
    'version': ScreenshotTranslationWindowMessage.protocolVersion,
    'role': role.name,
    'parentWindowId': parentWindowId,
  });

  factory ScreenshotTranslationWindowArguments.decode(String arguments) {
    final Object? value;
    try {
      value = jsonDecode(arguments);
    } on FormatException {
      throw const FormatException(
        'Invalid screenshot window startup arguments',
      );
    }
    if (value is! Map) {
      throw const FormatException(
        'Invalid screenshot window startup arguments',
      );
    }
    if (value['version'] !=
        ScreenshotTranslationWindowMessage.protocolVersion) {
      throw FormatException(
        'Unsupported screenshot window protocol: ${value['version']}',
      );
    }
    final roleName = value['role'];
    final parentWindowId = value['parentWindowId'];
    if (roleName is! String ||
        parentWindowId is! String ||
        parentWindowId.isEmpty) {
      throw const FormatException(
        'Invalid screenshot window startup arguments',
      );
    }
    for (final role in ScreenshotTranslationWindowRole.values) {
      if (role.name == roleName) {
        return ScreenshotTranslationWindowArguments(
          role: role,
          parentWindowId: parentWindowId,
        );
      }
    }
    throw FormatException('Unknown screenshot window role: $roleName');
  }
}
