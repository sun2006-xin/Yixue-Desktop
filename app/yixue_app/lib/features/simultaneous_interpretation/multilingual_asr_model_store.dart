import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'streaming_asr_model_store.dart';

/// A pinned asset used by the multilingual Whisper/VAD package.
final class MultilingualAsrModelAsset {
  const MultilingualAsrModelAsset({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256Hex,
    required this.sourceUri,
  });

  final String fileName;
  final int sizeBytes;
  final String sha256Hex;
  final Uri sourceUri;
}

/// Paths to the multilingual offline recognizer and its VAD dependency.
final class MultilingualAsrModelAssets {
  const MultilingualAsrModelAssets({required this.modelDirectory});

  final Directory modelDirectory;

  File get encoder => _file('tiny-encoder.int8.onnx');
  File get decoder => _file('tiny-decoder.int8.onnx');
  File get tokens => _file('tiny-tokens.txt');
  File get vad => _file('silero_vad.onnx');

  File _file(String name) =>
      File('${modelDirectory.path}${Platform.pathSeparator}$name');
}

/// Explicitly downloads the pinned Whisper Tiny multilingual and Silero VAD
/// assets. Construction and [isInstalled] are local-only; network access only
/// occurs after [downloadAndInstall] is called.
final class MultilingualAsrModelStore {
  MultilingualAsrModelStore({required Directory applicationDataDirectory})
    : _applicationDataDirectory = applicationDataDirectory.absolute;

  static const modelId = 'sherpa-onnx-whisper-tiny-multilingual-int8';
  static const modelRevision = '18e7b4cce9526312a66981ec3af7b9446b70db66';
  static const modelDirectoryName = 'sherpa-onnx-whisper-tiny-multilingual';
  static const totalBytes = 104253551;

  static final _huggingFaceBaseUri = Uri.https(
    'huggingface.co',
    '/csukuangfj/sherpa-onnx-whisper-tiny/resolve/$modelRevision',
  );
  static final _vadUri = Uri.https(
    'github.com',
    '/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
  );

  static final List<MultilingualAsrModelAsset>
  assets = List<MultilingualAsrModelAsset>.unmodifiable(
    <MultilingualAsrModelAsset>[
      MultilingualAsrModelAsset(
        fileName: 'tiny-encoder.int8.onnx',
        sizeBytes: 12937678,
        sha256Hex:
            'dd5531121627e7e184a6b8f6a6e353edf39b40e328032dfdc146b5a359a3e3d0',
        sourceUri: _huggingFaceBaseUri.replace(
          path: '${_huggingFaceBaseUri.path}/tiny-encoder.int8.onnx',
        ),
      ),
      MultilingualAsrModelAsset(
        fileName: 'tiny-decoder.int8.onnx',
        sizeBytes: 89855289,
        sha256Hex:
            'dd29c14f2104c14c3aca7dc8e13308190bbe4c65be21c82f4b86a27d8326b26b',
        sourceUri: _huggingFaceBaseUri.replace(
          path: '${_huggingFaceBaseUri.path}/tiny-decoder.int8.onnx',
        ),
      ),
      MultilingualAsrModelAsset(
        fileName: 'tiny-tokens.txt',
        sizeBytes: 816730,
        sha256Hex:
            'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126',
        sourceUri: _huggingFaceBaseUri.replace(
          path: '${_huggingFaceBaseUri.path}/tiny-tokens.txt',
        ),
      ),
      MultilingualAsrModelAsset(
        fileName: 'silero_vad.onnx',
        sizeBytes: 643854,
        sha256Hex:
            '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        sourceUri: _vadUri,
      ),
    ],
  );

  final Directory _applicationDataDirectory;

  Directory get modelRoot => Directory(
    '${_applicationDataDirectory.path}${Platform.pathSeparator}models',
  );

  Directory get modelDirectory => Directory(
    '${modelRoot.path}${Platform.pathSeparator}$modelDirectoryName',
  );

  Future<bool> isInstalled() async => _matchesInstalledModel(modelDirectory);

  Future<MultilingualAsrModelAssets> downloadAndInstall({
    required bool Function() shouldCancel,
    required void Function(StreamingAsrModelDownloadProgress progress)
    onProgress,
  }) async {
    _throwIfCancelled(shouldCancel);
    final destination = modelDirectory;
    final parent = destination.parent;
    try {
      await _applicationDataDirectory.create(recursive: true);
      await parent.create(recursive: true);
      _throwIfCancelled(shouldCancel);

      final destinationType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound) {
        if (destinationType == FileSystemEntityType.directory &&
            await _matchesInstalledModel(
              destination,
              shouldCancel: shouldCancel,
            )) {
          _throwIfCancelled(shouldCancel);
          _reportComplete(onProgress);
          return MultilingualAsrModelAssets(modelDirectory: destination);
        }
        throw const StreamingAsrModelStoreException('destination_conflict');
      }

      final staging = await parent.createTemp('.multilingual-asr-install-');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..idleTimeout = const Duration(seconds: 60)
        ..userAgent = 'Yixue-MultilingualAsrModelStore/1.0';
      var clientClosed = false;
      var cancelledDuringRequest = false;
      Timer? cancellationPoll;

      void closeClient() {
        if (clientClosed) return;
        clientClosed = true;
        client.close(force: true);
      }

      try {
        cancellationPoll = Timer.periodic(const Duration(milliseconds: 100), (
          _,
        ) {
          if (!cancelledDuringRequest && shouldCancel()) {
            cancelledDuringRequest = true;
            closeClient();
          }
        });

        var completedBytes = 0;
        _reportProgress(
          onProgress,
          currentAsset: assets.first,
          currentFileBytes: 0,
          completedBytes: 0,
          completedFiles: 0,
        );
        for (var index = 0; index < assets.length; index += 1) {
          _throwIfCancelled(shouldCancel);
          final asset = assets[index];
          final stagedFile = File(
            '${staging.path}${Platform.pathSeparator}${asset.fileName}',
          );
          final receivedBytes = await _downloadAsset(
            client: client,
            asset: asset,
            destination: stagedFile,
            closeClient: closeClient,
            shouldCancel: shouldCancel,
            isCancelled: () => cancelledDuringRequest,
            onProgress: (currentFileBytes) {
              _reportProgress(
                onProgress,
                currentAsset: asset,
                currentFileBytes: currentFileBytes,
                completedBytes: completedBytes,
                completedFiles: index,
              );
            },
          );
          completedBytes += receivedBytes;
          _throwIfCancelled(shouldCancel);
          if (!await _matchesPinnedFile(stagedFile, asset)) {
            throw StreamingAsrModelStoreException(
              'download_hash_mismatch',
              fileName: asset.fileName,
            );
          }
        }

        _throwIfCancelled(shouldCancel);
        cancellationPoll.cancel();
        cancellationPoll = null;
        closeClient();
        _reportComplete(onProgress);
        try {
          await staging.rename(destination.path);
        } on FileSystemException {
          if (await _matchesInstalledModel(
            destination,
            shouldCancel: shouldCancel,
          )) {
            _throwIfCancelled(shouldCancel);
            return MultilingualAsrModelAssets(modelDirectory: destination);
          }
          if (await FileSystemEntity.type(
                destination.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
            throw const StreamingAsrModelStoreException('destination_conflict');
          }
          rethrow;
        }
        return MultilingualAsrModelAssets(modelDirectory: destination);
      } on TimeoutException {
        if (cancelledDuringRequest || shouldCancel()) {
          throw const StreamingAsrModelStoreException('download_cancelled');
        }
        throw const StreamingAsrModelStoreException('download_timeout');
      } on StreamingAsrModelStoreException {
        rethrow;
      } on FileSystemException {
        if (cancelledDuringRequest || shouldCancel()) {
          throw const StreamingAsrModelStoreException('download_cancelled');
        }
        rethrow;
      } on IOException {
        if (cancelledDuringRequest || shouldCancel()) {
          throw const StreamingAsrModelStoreException('download_cancelled');
        }
        throw const StreamingAsrModelStoreException('download_io_error');
      } finally {
        cancellationPoll?.cancel();
        closeClient();
        if (await staging.exists()) await staging.delete(recursive: true);
      }
    } on StreamingAsrModelStoreException {
      rethrow;
    } on TimeoutException {
      if (shouldCancel()) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      throw const StreamingAsrModelStoreException('download_timeout');
    } on FileSystemException {
      if (shouldCancel()) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      throw const StreamingAsrModelStoreException('destination_unavailable');
    } on IOException {
      if (shouldCancel()) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      throw const StreamingAsrModelStoreException('download_io_error');
    }
  }

  Future<int> _downloadAsset({
    required HttpClient client,
    required MultilingualAsrModelAsset asset,
    required File destination,
    required void Function() closeClient,
    required bool Function() shouldCancel,
    required bool Function() isCancelled,
    required void Function(int downloadedBytes) onProgress,
  }) async {
    _throwIfCancelled(shouldCancel);
    var requestUri = asset.sourceUri;
    late final HttpClientResponse response;
    for (var redirectCount = 0; ; redirectCount += 1) {
      if (isCancelled() || shouldCancel()) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      final request = await client
          .getUrl(requestUri)
          .timeout(const Duration(seconds: 45));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final currentResponse = await request.close().timeout(
        const Duration(seconds: 60),
      );
      final statusCode = currentResponse.statusCode;
      final isRedirect =
          statusCode == HttpStatus.movedPermanently ||
          statusCode == HttpStatus.found ||
          statusCode == HttpStatus.seeOther ||
          statusCode == HttpStatus.temporaryRedirect ||
          statusCode == HttpStatus.permanentRedirect;
      final location = currentResponse.headers.value(
        HttpHeaders.locationHeader,
      );
      if (!isRedirect || location == null) {
        response = currentResponse;
        break;
      }
      if (redirectCount >= 5) {
        throw StreamingAsrModelStoreException(
          'download_redirect_rejected',
          fileName: asset.fileName,
        );
      }
      requestUri = StreamingAsrModelStore.resolveHttpsRedirect(
        requestUri,
        location,
      );
      await currentResponse.drain<void>().timeout(const Duration(seconds: 60));
    }
    if (response.statusCode != HttpStatus.ok) {
      closeClient();
      throw StreamingAsrModelStoreException(
        'download_http_error',
        fileName: asset.fileName,
        statusCode: response.statusCode,
      );
    }
    if (response.contentLength >= 0 &&
        response.contentLength != asset.sizeBytes) {
      closeClient();
      throw StreamingAsrModelStoreException(
        'download_size_mismatch',
        fileName: asset.fileName,
      );
    }
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    var downloadedBytes = 0;
    var lastProgressBytes = 0;
    final iterator = StreamIterator<List<int>>(
      response.timeout(const Duration(seconds: 60)),
    );
    final deadline = Stopwatch()..start();
    try {
      onProgress(0);
      while (await iterator.moveNext()) {
        if (isCancelled() || shouldCancel()) {
          throw const StreamingAsrModelStoreException('download_cancelled');
        }
        if (deadline.elapsed > const Duration(hours: 2)) {
          throw StreamingAsrModelStoreException(
            'download_timeout',
            fileName: asset.fileName,
          );
        }
        final chunk = iterator.current;
        if (chunk.length > asset.sizeBytes - downloadedBytes) {
          throw StreamingAsrModelStoreException(
            'download_size_mismatch',
            fileName: asset.fileName,
          );
        }
        downloadedBytes += chunk.length;
        sink.add(chunk);
        if (downloadedBytes - lastProgressBytes >= 1024 * 1024) {
          lastProgressBytes = downloadedBytes;
          onProgress(downloadedBytes);
        }
      }
      if (isCancelled() || shouldCancel()) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      await sink.flush();
    } on TimeoutException {
      if (isCancelled() || shouldCancel()) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      throw StreamingAsrModelStoreException(
        'download_timeout',
        fileName: asset.fileName,
      );
    } finally {
      await iterator.cancel();
      await sink.close();
    }

    if (downloadedBytes != asset.sizeBytes ||
        await destination.length() != asset.sizeBytes) {
      throw StreamingAsrModelStoreException(
        'download_size_mismatch',
        fileName: asset.fileName,
      );
    }
    return downloadedBytes;
  }

  Future<bool> _matchesInstalledModel(
    Directory directory, {
    bool Function()? shouldCancel,
  }) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    for (final asset in assets) {
      if (shouldCancel?.call() ?? false) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      final file = File(
        '${directory.path}${Platform.pathSeparator}${asset.fileName}',
      );
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      if (!await _matchesPinnedFile(file, asset)) return false;
    }
    return true;
  }

  Future<bool> _matchesPinnedFile(
    File file,
    MultilingualAsrModelAsset asset,
  ) async {
    if (!await file.exists() || await file.length() != asset.sizeBytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == asset.sha256Hex;
  }

  void _reportProgress(
    void Function(StreamingAsrModelDownloadProgress progress) callback, {
    required MultilingualAsrModelAsset currentAsset,
    required int currentFileBytes,
    required int completedBytes,
    required int completedFiles,
  }) {
    callback(
      StreamingAsrModelDownloadProgress(
        currentFileName: currentAsset.fileName,
        currentFileDownloadedBytes: currentFileBytes,
        currentFileTotalBytes: currentAsset.sizeBytes,
        downloadedBytes: completedBytes + currentFileBytes,
        totalBytes: totalBytes,
        completedFiles: completedFiles,
        fileCount: assets.length,
      ),
    );
  }

  void _reportComplete(
    void Function(StreamingAsrModelDownloadProgress progress) callback,
  ) {
    final lastAsset = assets.last;
    callback(
      StreamingAsrModelDownloadProgress(
        currentFileName: lastAsset.fileName,
        currentFileDownloadedBytes: lastAsset.sizeBytes,
        currentFileTotalBytes: lastAsset.sizeBytes,
        downloadedBytes: totalBytes,
        totalBytes: totalBytes,
        completedFiles: assets.length,
        fileCount: assets.length,
      ),
    );
  }

  void _throwIfCancelled(bool Function() shouldCancel) {
    if (shouldCancel()) {
      throw const StreamingAsrModelStoreException('download_cancelled');
    }
  }
}
