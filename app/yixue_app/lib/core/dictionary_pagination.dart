import 'package:yixue_app/core/native_core_bridge.dart';

/// Reads the complete stored dictionary when the connected core supports
/// pagination, while retaining compatibility with older native libraries.
///
/// Older DLLs report `unknown_command` for the page endpoint. In that one
/// version-mismatch case, fall back to the legacy bounded lookup instead of
/// dropping all persisted dictionary terms from the learning workspace.
Future<List<DictionaryEntryData>> loadStoredDictionaryEntries(
  DictionaryCore core, {
  int pageSize = 100,
}) async {
  if (pageSize < 1 || pageSize > 100) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be between 1 and 100');
  }

  if (core case final PagedDictionaryCore paged) {
    final entries = <DictionaryEntryData>[];
    var offset = 0;
    try {
      while (true) {
        final page = paged.listDictionaryEntryPage(
          limit: pageSize,
          offset: offset,
        );
        entries.addAll(page.entries);
        if (!page.hasMore || page.entries.isEmpty) break;
        offset += page.entries.length;
        // Each FFI page is synchronous. Yield between pages so loading a
        // large local dictionary does not monopolize the UI isolate.
        await Future<void>.delayed(Duration.zero);
      }
      return List.unmodifiable(entries);
    } on CoreBridgeException catch (error) {
      if (error.code != 'unknown_command') rethrow;
      return core.lookupDictionary('', limit: 50);
    }
  }

  return core.lookupDictionary('', limit: 50);
}
