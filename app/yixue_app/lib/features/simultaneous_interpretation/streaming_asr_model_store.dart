import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _encoderFileName = 'encoder-epoch-99-avg-1.int8.onnx';
const _decoderFileName = 'decoder-epoch-99-avg-1.onnx';
const _joinerFileName = 'joiner-epoch-99-avg-1.onnx';
const _tokensFileName = 'tokens.txt';

/// Aggregate progress for the four pinned sherpa-onnx model assets.
///
/// [downloadedBytes] counts bytes received across all files so far. The
/// [currentFileDownloadedBytes] field is scoped to [currentFileName].
final class StreamingAsrModelDownloadProgress {
  const StreamingAsrModelDownloadProgress({
    required this.currentFileName,
    required this.currentFileDownloadedBytes,
    required this.currentFileTotalBytes,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.completedFiles,
    required this.fileCount,
  });

  final String currentFileName;
  final int currentFileDownloadedBytes;
  final int currentFileTotalBytes;
  final int downloadedBytes;
  final int totalBytes;
  final int completedFiles;
  final int fileCount;
}

final class StreamingAsrModelStoreException implements Exception {
  const StreamingAsrModelStoreException(
    this.code, {
    this.fileName,
    this.statusCode,
  });

  final String code;
  final String? fileName;
  final int? statusCode;

  @override
  String toString() =>
      'StreamingAsrModelStoreException($code'
      '${fileName == null ? '' : ', fileName: $fileName'}'
      '${statusCode == null ? '' : ', statusCode: $statusCode'})';
}

/// Paths to the four files required by the official sherpa-onnx Flutter
/// streaming ASR example.
final class StreamingAsrModelAssets {
  const StreamingAsrModelAssets({required this.modelDirectory});

  final Directory modelDirectory;

  File get encoder => File(_join(modelDirectory.path, _encoderFileName));
  File get decoder => File(_join(modelDirectory.path, _decoderFileName));
  File get joiner => File(_join(modelDirectory.path, _joinerFileName));
  File get tokens => File(_join(modelDirectory.path, _tokensFileName));
}

/// Explicitly downloads and installs the pinned bilingual sherpa-onnx
/// streaming Zipformer model into the app's data directory.
///
/// Constructing this service and calling [isInstalled] never access the
/// network. A network request occurs only when [downloadAndInstall] is called.
final class StreamingAsrModelStore {
  StreamingAsrModelStore({required Directory applicationDataDirectory})
    : _applicationDataDirectory = applicationDataDirectory.absolute;

  static const modelRevision = '98590b7ed6443e77b714204da2757d75e1a642f4';
  static const modelDirectoryName =
      'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20';
  static const _totalModelBytes = 208661419;

  static const _assets = <_PinnedModelFile>[
    _PinnedModelFile(
      fileName: _encoderFileName,
      sizeBytes: 181895032,
      sha256Hex:
          '8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b',
    ),
    _PinnedModelFile(
      fileName: _decoderFileName,
      sizeBytes: 13876452,
      sha256Hex:
          '2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d',
    ),
    _PinnedModelFile(
      fileName: _joinerFileName,
      sizeBytes: 12833618,
      sha256Hex:
          '5f2adc585dd1bec6421c8bb8660d2a73fc8b9ceb24491ef51399ba2a2f0fc31b',
    ),
    _PinnedModelFile(
      fileName: _tokensFileName,
      sizeBytes: 56317,
      sha256Hex:
          'a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3',
    ),
  ];

  static final _modelBaseUri = Uri.https(
    'huggingface.co',
    '/csukuangfj/$modelDirectoryName/resolve/$modelRevision',
  );

  final Directory _applicationDataDirectory;

  /// Resolves a model-host redirect relative to the URL that returned it and
  /// rejects schemes that could downgrade or expose credentials.
  static Uri resolveHttpsRedirect(Uri currentUri, String location) {
    final resolved = currentUri.resolve(location);
    if (resolved.scheme != 'https' ||
        resolved.host.isEmpty ||
        resolved.userInfo.isNotEmpty) {
      throw const StreamingAsrModelStoreException('download_redirect_rejected');
    }
    return resolved;
  }

  Directory get modelDirectory => Directory(
    _join(_join(_applicationDataDirectory.path, 'models'), modelDirectoryName),
  );

  /// Returns true only if all four installed files match their pinned sizes
  /// and SHA-256 digests. This method performs local disk reads only.
  Future<bool> isInstalled() async => _matchesInstalledModel(modelDirectory);

  /// Downloads the four explicitly listed files and atomically installs them.
  ///
  /// The caller controls cancellation through [shouldCancel]. Each response is
  /// capped at the pinned file size and has a per-file deadline, so a server
  /// cannot cause this service to consume unbounded disk space or wait forever.
  Future<StreamingAsrModelAssets> downloadAndInstall({
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

      final existingType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (existingType != FileSystemEntityType.notFound) {
        if (existingType == FileSystemEntityType.directory &&
            await _matchesInstalledModel(
              destination,
              shouldCancel: shouldCancel,
            )) {
          _throwIfCancelled(shouldCancel);
          _reportComplete(onProgress);
          return StreamingAsrModelAssets(modelDirectory: destination);
        }
        throw const StreamingAsrModelStoreException('destination_conflict');
      }

      final staging = await parent.createTemp('.streaming-asr-install-');
      late final HttpClient client;
      try {
        client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30)
          ..idleTimeout = const Duration(seconds: 60)
          ..userAgent = 'Yixue-StreamingAsrModelStore/1.0';
      } catch (_) {
        await staging.delete(recursive: true);
        rethrow;
      }
      var clientClosed = false;
      var cancelledDuringRequest = false;
      Timer? cancellationPoll;

      void closeClient() {
        if (!clientClosed) {
          clientClosed = true;
          client.close(force: true);
        }
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
          currentFile: _assets.first,
          currentFileBytes: 0,
          completedBytes: 0,
          completedFiles: 0,
        );

        for (var index = 0; index < _assets.length; index += 1) {
          _throwIfCancelled(shouldCancel);
          final asset = _assets[index];
          final stagedFile = File(_join(staging.path, asset.fileName));
          final receivedBytes = await _downloadFile(
            client: client,
            asset: asset,
            destination: stagedFile,
            closeClient: closeClient,
            shouldCancel: shouldCancel,
            isCancelled: () => cancelledDuringRequest,
            onProgress: (currentFileBytes) {
              _reportProgress(
                onProgress,
                currentFile: asset,
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
          _throwIfCancelled(shouldCancel);
          _reportProgress(
            onProgress,
            currentFile: asset,
            currentFileBytes: asset.sizeBytes,
            completedBytes: completedBytes - asset.sizeBytes,
            completedFiles: index,
          );
        }

        _throwIfCancelled(shouldCancel);
        cancellationPoll.cancel();
        cancellationPoll = null;
        closeClient();
        _reportComplete(onProgress);

        try {
          await staging.rename(destination.path);
        } on FileSystemException {
          // A second caller may have installed the same pinned model after our
          // initial destination check. Reuse it only after revalidating it.
          if (await _matchesInstalledModel(
            destination,
            shouldCancel: shouldCancel,
          )) {
            _throwIfCancelled(shouldCancel);
            return StreamingAsrModelAssets(modelDirectory: destination);
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

        return StreamingAsrModelAssets(modelDirectory: destination);
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
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
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

  Future<int> _downloadFile({
    required HttpClient client,
    required _PinnedModelFile asset,
    required File destination,
    required void Function() closeClient,
    required bool Function() shouldCancel,
    required bool Function() isCancelled,
    required void Function(int downloadedBytes) onProgress,
  }) async {
    final fileDeadline = Stopwatch()..start();
    _throwIfCancelled(shouldCancel);
    final uri = _modelBaseUri.replace(
      path: '${_modelBaseUri.path}/${asset.fileName}',
      queryParameters: const <String, String>{'download': 'true'},
    );
    var requestUri = uri;
    late final HttpClientResponse response;
    for (var redirectCount = 0; ; redirectCount += 1) {
      _throwIfRequestCancelled(shouldCancel, isCancelled);
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
      requestUri = resolveHttpsRedirect(requestUri, location);
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
    try {
      onProgress(0);
      while (await iterator.moveNext()) {
        _throwIfRequestCancelled(shouldCancel, isCancelled);
        if (fileDeadline.elapsed > const Duration(hours: 2)) {
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
      _throwIfRequestCancelled(shouldCancel, isCancelled);
      if (fileDeadline.elapsed > const Duration(hours: 2)) {
        throw StreamingAsrModelStoreException(
          'download_timeout',
          fileName: asset.fileName,
        );
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
    for (final asset in _assets) {
      if (shouldCancel?.call() ?? false) {
        throw const StreamingAsrModelStoreException('download_cancelled');
      }
      final file = File(_join(directory.path, asset.fileName));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      if (!await _matchesPinnedFile(file, asset)) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _matchesPinnedFile(File file, _PinnedModelFile asset) async {
    if (!await file.exists() || await file.length() != asset.sizeBytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == asset.sha256Hex;
  }

  void _reportProgress(
    void Function(StreamingAsrModelDownloadProgress progress) callback, {
    required _PinnedModelFile currentFile,
    required int currentFileBytes,
    required int completedBytes,
    required int completedFiles,
  }) {
    callback(
      StreamingAsrModelDownloadProgress(
        currentFileName: currentFile.fileName,
        currentFileDownloadedBytes: currentFileBytes,
        currentFileTotalBytes: currentFile.sizeBytes,
        downloadedBytes: completedBytes + currentFileBytes,
        totalBytes: _totalModelBytes,
        completedFiles: completedFiles,
        fileCount: _assets.length,
      ),
    );
  }

  void _reportComplete(
    void Function(StreamingAsrModelDownloadProgress progress) callback,
  ) {
    final lastAsset = _assets.last;
    callback(
      StreamingAsrModelDownloadProgress(
        currentFileName: lastAsset.fileName,
        currentFileDownloadedBytes: lastAsset.sizeBytes,
        currentFileTotalBytes: lastAsset.sizeBytes,
        downloadedBytes: _totalModelBytes,
        totalBytes: _totalModelBytes,
        completedFiles: _assets.length,
        fileCount: _assets.length,
      ),
    );
  }

  void _throwIfRequestCancelled(
    bool Function() shouldCancel,
    bool Function() isCancelled,
  ) {
    if (isCancelled() || shouldCancel()) {
      throw const StreamingAsrModelStoreException('download_cancelled');
    }
  }

  void _throwIfCancelled(bool Function() shouldCancel) {
    if (shouldCancel()) {
      throw const StreamingAsrModelStoreException('download_cancelled');
    }
  }
}

final class _PinnedModelFile {
  const _PinnedModelFile({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256Hex,
  });

  final String fileName;
  final int sizeBytes;
  final String sha256Hex;
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';
