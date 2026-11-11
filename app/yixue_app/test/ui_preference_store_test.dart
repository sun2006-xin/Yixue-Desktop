import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/ui_preference_store.dart';

void main() {
  test('sidebar preference survives a new file store instance', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-ui-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}ui.json');

    await FileUiPreferenceStore(file).writeSidebarExpanded(false);
    final restored = await FileUiPreferenceStore(file).readSidebarExpanded();

    expect(restored, isFalse);
  });

  test('missing or malformed preference falls back safely', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-ui-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}ui.json');
    final store = FileUiPreferenceStore(file);

    expect(await store.readSidebarExpanded(), isNull);
    await file.writeAsString('{broken json');
    expect(await store.readSidebarExpanded(), isNull);
  });
}
