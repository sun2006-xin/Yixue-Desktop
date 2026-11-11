import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/windows_associated_file_opener.dart';

void main() {
  test('opens the selected file with the Windows default association', () {
    String? receivedVerb;
    String? receivedPath;

    final result = openWindowsAssociatedFile(
      r'D:\recordings folder\lesson 01.mp4',
      shellExecute: (verb, path) {
        receivedVerb = verb;
        receivedPath = path;
        return 33;
      },
    );

    expect(result, 33);
    expect(receivedVerb, 'open');
    expect(receivedPath, r'D:\recordings folder\lesson 01.mp4');
  });

  test('surfaces Windows file-association failures', () {
    expect(
      () => openWindowsAssociatedFile(
        r'D:\recordings\missing.wav',
        shellExecute: (_, _) => 31,
      ),
      throwsA(isA<WindowsAssociatedFileOpenException>()),
    );
  });
}
