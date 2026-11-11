import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef WindowsShellExecuteInvoker = int Function(String verb, String path);

/// Requests Windows to open a file with its registered application association.
///
/// A successful return means ShellExecute accepted the request; it does not
/// confirm that the associated application rendered or played the file.
///
/// [shellExecute] is an injectable seam for tests. Production calls use the
/// documented ShellExecuteW `open` verb and never pass a file path through a
/// command shell.
int openWindowsAssociatedFile(
  String path, {
  WindowsShellExecuteInvoker? shellExecute,
}) {
  final result = shellExecute?.call('open', path) ?? _shellExecuteOpen(path);
  if (result <= 32) throw WindowsAssociatedFileOpenException(result);
  return result;
}

final class WindowsAssociatedFileOpenException implements Exception {
  const WindowsAssociatedFileOpenException(this.shellResult);

  final int shellResult;

  @override
  String toString() =>
      'Windows could not open this file with its associated application '
      '(ShellExecuteW=$shellResult).';
}

typedef _ShellExecuteWNative = IntPtr Function(
  Pointer<Void> window,
  Pointer<Utf16> operation,
  Pointer<Utf16> file,
  Pointer<Utf16> parameters,
  Pointer<Utf16> directory,
  Int32 showCommand,
);

typedef _ShellExecuteWDart = int Function(
  Pointer<Void> window,
  Pointer<Utf16> operation,
  Pointer<Utf16> file,
  Pointer<Utf16> parameters,
  Pointer<Utf16> directory,
  int showCommand,
);

final _shellExecuteW = DynamicLibrary.open('shell32.dll')
    .lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>('ShellExecuteW');

int _shellExecuteOpen(String path) {
  final arena = Arena();
  try {
    return _shellExecuteW(
      nullptr,
      'open'.toNativeUtf16(allocator: arena),
      path.toNativeUtf16(allocator: arena),
      nullptr,
      nullptr,
      1,
    );
  } finally {
    arena.releaseAll();
  }
}
