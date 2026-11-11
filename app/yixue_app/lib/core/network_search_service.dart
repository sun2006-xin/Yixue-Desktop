import 'dart:io';

typedef NetworkSearchLauncher = Future<void> Function(String query);

class NetworkSearchException implements Exception {
  const NetworkSearchException(this.code);

  final String code;

  @override
  String toString() => 'NetworkSearchException($code)';
}

/// Provides the first, user-confirmed network search boundary.
///
/// The current preview opens a fixed HTTPS search URL in the user's browser.
/// It deliberately does not send the query to a translation model or upload a
/// whole document. A later retrieval adapter can implement the same launcher
/// contract after the user explicitly enables it.
class NetworkSearchService {
  const NetworkSearchService._();

  static const maxQueryLength = 200;

  static Uri buildSearchUri(String rawQuery) {
    final query = normalizeQuery(rawQuery);
    return Uri.https('www.bing.com', '/search', {'q': query});
  }

  static String normalizeQuery(String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      throw const NetworkSearchException('empty_query');
    }
    if (query.length > maxQueryLength) {
      throw const NetworkSearchException('query_too_long');
    }
    if (query.contains(RegExp(r'[\u0000-\u001F\u007F]'))) {
      throw const NetworkSearchException('control_character');
    }
    return query;
  }

  static Future<void> openInBrowser(String rawQuery) async {
    final uri = buildSearchUri(rawQuery);
    final executable = Platform.isWindows
        ? 'explorer.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    await Process.start(executable, [uri.toString()]);
  }
}
