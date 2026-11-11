/// Describes where a translation request is handled without exposing secrets.
enum TranslationExecutionRouteKind {
  localDictionary,
  localModel,
  localCompatibleApi,
  remoteProvider,
  unavailable,
  unknown,
}

final class TranslationExecutionRoute {
  const TranslationExecutionRoute._({required this.kind, this.displayName});

  const TranslationExecutionRoute.localDictionary()
    : this._(kind: TranslationExecutionRouteKind.localDictionary);

  factory TranslationExecutionRoute.localModel(String displayName) =>
      TranslationExecutionRoute._(
        kind: TranslationExecutionRouteKind.localModel,
        displayName: _cleanDisplayName(displayName),
      );

  factory TranslationExecutionRoute.remoteProvider(String displayName) =>
      TranslationExecutionRoute._(
        kind: TranslationExecutionRouteKind.remoteProvider,
        displayName: _cleanDisplayName(displayName),
      );

  factory TranslationExecutionRoute.localCompatibleApi(String displayName) =>
      TranslationExecutionRoute._(
        kind: TranslationExecutionRouteKind.localCompatibleApi,
        displayName: _cleanDisplayName(displayName),
      );

  const TranslationExecutionRoute.unavailable()
    : this._(kind: TranslationExecutionRouteKind.unavailable);

  const TranslationExecutionRoute.unknown()
    : this._(kind: TranslationExecutionRouteKind.unknown);

  final TranslationExecutionRouteKind kind;
  final String? displayName;

  Map<String, Object?> toMap() => {
    'kind': kind.name,
    if (displayName != null) 'displayName': displayName,
  };

  factory TranslationExecutionRoute.fromMap(Map value) {
    final rawKind = value['kind'];
    final kind = TranslationExecutionRouteKind.values.firstWhere(
      (candidate) => candidate.name == rawKind,
      orElse: () => TranslationExecutionRouteKind.unknown,
    );
    final rawName = value['displayName'];
    final displayName = rawName is String ? _cleanDisplayName(rawName) : null;
    return TranslationExecutionRoute._(kind: kind, displayName: displayName);
  }
}

String? _cleanDisplayName(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return null;
  return normalized.length <= 80
      ? normalized
      : '${normalized.substring(0, 79)}…';
}
