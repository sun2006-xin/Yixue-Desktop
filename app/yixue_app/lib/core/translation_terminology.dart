import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum TerminologyDirection { englishToChinese, chineseToEnglish }

class TranslationTermRule {
  const TranslationTermRule({
    required this.id,
    required this.source,
    required this.target,
    required this.direction,
  });

  final String id;
  final String source;
  final String target;
  final TerminologyDirection direction;

  Map<String, String> toJson() => {
    'id': id,
    'source': source,
    'target': target,
    'direction': direction.name,
  };

  factory TranslationTermRule.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final source = json['source'];
    final target = json['target'];
    final direction = json['direction'];
    if (id is! String ||
        source is! String ||
        target is! String ||
        id.trim().isEmpty ||
        source.trim().isEmpty ||
        target.trim().isEmpty ||
        id.length > 128 ||
        source.length > 256 ||
        target.length > 256) {
      throw const FormatException('invalid terminology rule');
    }
    final parsedDirection = TerminologyDirection.values.firstWhere(
      (value) => value.name == direction,
      orElse: () =>
          throw const FormatException('invalid terminology direction'),
    );
    return TranslationTermRule(
      id: id.trim(),
      source: source.trim(),
      target: target.trim(),
      direction: parsedDirection,
    );
  }
}

class TranslationTerminology {
  const TranslationTerminology(this.rules);

  static const maxRules = 2000;
  static const termSentinel = 'YXTERM';
  static final RegExp _screenshotOcrBlockMarker = RegExp(
    r'⟦YIXUE_OCR_[A-Za-z0-9_-]{1,80}_\d+_(?:START|END)⟧',
  );
  final List<TranslationTermRule> rules;

  List<TranslationTermRule> forDirection(TerminologyDirection direction) =>
      rules
          .where((rule) => rule.direction == direction)
          .toList(growable: false);

  TranslationTerminologyProtectedInput protect(
    String sourceText,
    TerminologyDirection direction,
  ) {
    final translatableText = sourceText.replaceAll(
      _screenshotOcrBlockMarker,
      '',
    );
    final matching =
        forDirection(direction)
            .where((rule) => translatableText.contains(rule.source))
            .toList(growable: false)
          ..sort(
            (left, right) => right.source.length.compareTo(left.source.length),
          );
    if (matching.isEmpty) {
      return TranslationTerminologyProtectedInput._(sourceText, const []);
    }
    final pattern = RegExp(
      matching.map((rule) => RegExp.escape(rule.source)).join('|'),
      caseSensitive: false,
    );
    final targets = <String>[];
    String maskTerms(String text) => text.replaceAllMapped(pattern, (match) {
      final source = match.group(0)!.toLowerCase();
      final rule = matching.firstWhere(
        (candidate) => candidate.source.toLowerCase() == source,
      );
      targets.add(rule.target);
      return termSentinel;
    });
    final masked = StringBuffer();
    var cursor = 0;
    for (final marker in _screenshotOcrBlockMarker.allMatches(sourceText)) {
      masked
        ..write(maskTerms(sourceText.substring(cursor, marker.start)))
        ..write(marker.group(0));
      cursor = marker.end;
    }
    masked.write(maskTerms(sourceText.substring(cursor)));
    return TranslationTerminologyProtectedInput._(masked.toString(), targets);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'rules': rules.map((rule) => rule.toJson()).toList(growable: false),
  };

  factory TranslationTerminology.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['rules'] is! List<dynamic>) {
      throw const FormatException('unsupported terminology schema');
    }
    final rules = (json['rules'] as List<dynamic>)
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('invalid terminology rule object');
          }
          return TranslationTermRule.fromJson(value);
        })
        .toList(growable: false);
    if (rules.length > maxRules) {
      throw const FormatException('too many terminology rules');
    }
    final ids = rules.map((rule) => rule.id).toSet();
    if (ids.length != rules.length) {
      throw const FormatException('duplicate terminology rule id');
    }
    return TranslationTerminology(List.unmodifiable(rules));
  }
}

class TranslationTerminologyProtectedInput {
  const TranslationTerminologyProtectedInput._(this.maskedText, this.targets);

  final String maskedText;
  final List<String> targets;

  String restore(String translatedText) {
    final parts = translatedText.split(TranslationTerminology.termSentinel);
    if (parts.length - 1 != targets.length) {
      throw const FormatException('terminology_placeholder_integrity_failed');
    }
    if (targets.isEmpty) return translatedText;
    final restored = StringBuffer(parts.first);
    for (var index = 0; index < targets.length; index += 1) {
      restored
        ..write(targets[index])
        ..write(parts[index + 1]);
    }
    return restored.toString();
  }
}

abstract interface class TranslationTerminologyStore {
  Future<TranslationTerminology?> read();

  Future<void> write(TranslationTerminology terminology);
}

class FileTranslationTerminologyStore implements TranslationTerminologyStore {
  FileTranslationTerminologyStore(this.file);

  final File file;

  @override
  Future<TranslationTerminology?> read() async {
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return null;
      return TranslationTerminology.fromJson(value);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  @override
  Future<void> write(TranslationTerminology terminology) async {
    if (terminology.rules.length > TranslationTerminology.maxRules) {
      throw const FormatException('too many terminology rules');
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(terminology.toJson()), flush: true);
  }
}

class TranslationTerminologyController extends ChangeNotifier {
  TranslationTerminologyController({TranslationTerminology? initialValue})
    : _value = initialValue ?? const TranslationTerminology([]);

  TranslationTerminology _value;

  TranslationTerminology get value => _value;

  void update(TranslationTerminology value) {
    if (listEquals(_value.rules, value.rules)) return;
    _value = value;
    notifyListeners();
  }
}
