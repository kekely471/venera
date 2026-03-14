// WebDAV 压缩漫画解析与缓存服务
// @author: kirk

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';

class WebDavArchiveBook {
  final String id;
  final String title;
  final String subtitle;
  final List<String> tags;
  final String directory;
  final String cover;
  final int pages;
  final DateTime createdAt;

  const WebDavArchiveBook({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.cover,
    required this.pages,
    required this.createdAt,
  });
}

class WebDavArchiveService {
  WebDavArchiveService._();

  static WebDavArchiveService? _instance;

  factory WebDavArchiveService() {
    return _instance ??= WebDavArchiveService._();
  }

  static const String archiveDirectoryPrefix = 'webdav-archive://';
  static const String streamDirectoryPrefix = 'webdav-archive-stream://';
  static const int _metaSchemaVersion = 1;
  static const int _streamMetaSchemaVersion = 1;
  static const int _zipTailReadSize = 512 * 1024;
  static const int _maxCentralDirectorySize = 32 * 1024 * 1024;
  static const int _maxEntryCompressedSize = 64 * 1024 * 1024;

  static const int _zipEocdSignature = 0x06054b50;
  static const int _zip64EocdSignature = 0x06064b50;
  static const int _zip64LocatorSignature = 0x07064b50;
  static const int _zipCentralDirFileHeaderSignature = 0x02014b50;
  static const int _zipLocalFileHeaderSignature = 0x04034b50;
  static const int _streamReadRetryTimes = 2;
  static const int _maxStreamPrefetchConcurrency = 2;
  static const int _streamPrefetchBefore = 1;
  static const int _streamPrefetchAfter = 2;

  final Map<String, Future<Uint8List>> _streamReadInFlight = {};
  final Map<String, _ArchiveStreamMeta> _streamMetaCache = {};
  final Map<String, Future<void>> _streamPrefetchInFlight = {};
  final List<_ArchiveStreamPrefetchTask> _streamPrefetchQueue = [];
  int _streamPrefetchRunning = 0;
  String? _activeMetaKey;

  static bool isArchiveDirectory(String directory) {
    return directory.startsWith(archiveDirectoryPrefix);
  }

  static bool isStreamDirectory(String directory) {
    return directory.startsWith(streamDirectoryPrefix);
  }

  static String encodeDirectory(String localPath) {
    return '$archiveDirectoryPrefix${Uri.encodeComponent(localPath)}';
  }

  static String encodeStreamDirectory(String localPath) {
    return '$streamDirectoryPrefix${Uri.encodeComponent(localPath)}';
  }

  static String? decodeDirectory(String encodedPath) {
    if (!isArchiveDirectory(encodedPath)) return null;
    try {
      return Uri.decodeComponent(
        encodedPath.substring(archiveDirectoryPrefix.length),
      );
    } catch (_) {
      return null;
    }
  }

  static String? decodeStreamDirectory(String encodedPath) {
    if (!isStreamDirectory(encodedPath)) return null;
    try {
      return Uri.decodeComponent(
        encodedPath.substring(streamDirectoryPrefix.length),
      );
    } catch (_) {
      return null;
    }
  }

  Future<WebDavArchiveBook> prepareFromWebDav({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();
    final cacheDir = Directory(
      FilePath.join(App.cachePath, 'webdav_archive', key),
    );
    final metadataFile = cacheDir.joinFile('meta.json');
    final metadata = await _loadMetadata(metadataFile);

    if (_isCacheUsable(metadata, remoteSize, remoteModifiedTime, cacheDir)) {
      try {
        return _bookFromMetadata(metadata!, fileName);
      } catch (_) {
        // ignore broken metadata and rebuild cache
      }
    }

    await cacheDir.deleteIgnoreError(recursive: true);
    await cacheDir.create(recursive: true);

    final sourceFile = cacheDir.joinFile(
      'source${_pickArchiveExtension(fileName)}',
    );
    final extractDir = Directory(FilePath.join(cacheDir.path, '_extract'));

    try {
      await WebDavComicManager().readFileToLocal(remotePath, sourceFile.path);
      if (!await sourceFile.exists() || await sourceFile.length() <= 0) {
        throw Exception('Archive file is empty');
      }

      await extractDir.create(recursive: true);
      await CBZ.extractArchive(sourceFile, extractDir);

      final imageFiles = await _collectImageFiles(extractDir);
      if (imageFiles.isEmpty) {
        throw Exception('No images found in archive');
      }

      final nameWidth = imageFiles.length.toString().length.clamp(3, 6);
      final pageFiles = <String>[];
      String? coverName;
      for (int i = 0; i < imageFiles.length; i++) {
        final src = imageFiles[i];
        final ext = _pickImageExtension(src.file);
        final outName = '${(i + 1).toString().padLeft(nameWidth, '0')}.$ext';
        final outFile = cacheDir.joinFile(outName);
        await src.file.copyMem(outFile.path);
        pageFiles.add(outName);
        if (coverName == null && src.isCover) {
          coverName = outName;
        }
      }
      coverName ??= pageFiles.first;

      final createdAt = DateTime.now();
      final metadataToSave = <String, dynamic>{
        'schema': _metaSchemaVersion,
        'id': 'webdav_archive_$key',
        'title': _stripFileExtension(fileName),
        'subtitle': '',
        'tags': const <String>['webdav:archive'],
        'directory': encodeDirectory(cacheDir.path),
        'cover': coverName,
        'pages': pageFiles.length,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'remotePath': remotePath,
        'remoteSize': remoteSize,
        'remoteModifiedTime': remoteModifiedTime?.millisecondsSinceEpoch,
      };
      await metadataFile.writeAsString(jsonEncode(metadataToSave));
      return _bookFromMetadata(metadataToSave, fileName);
    } catch (_) {
      await cacheDir.deleteIgnoreError(recursive: true);
      rethrow;
    } finally {
      await sourceFile.deleteIgnoreError();
      await extractDir.deleteIgnoreError(recursive: true);
    }
  }

  /// 通过 Range 请求解析 ZIP/CBZ 中央目录，仅缓存元数据和封面图。
  /// 失败时返回 null，调用方可回退到全量下载模式。
  Future<WebDavArchiveBook?> prepareStreamingMeta({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();
    final metaDir = Directory(
      FilePath.join(App.cachePath, 'webdav_archive_stream', key),
    );
    final metadataFile = metaDir.joinFile('meta.json');
    final existingMeta = await _loadMetadata(metadataFile);

    if (_isStreamCacheUsable(
      existingMeta,
      remoteSize,
      remoteModifiedTime,
      metaDir,
    )) {
      try {
        return _bookFromStreamMetadata(existingMeta!, fileName);
      } catch (_) {
        // 缓存损坏，继续重建
      }
    }

    try {
      final manager = WebDavComicManager();
      var totalSize = remoteSize;
      totalSize ??= await manager.getFileSize(remotePath);
      if (totalSize <= 0) return null;

      final directoryInfo = await _parseZipCentralDirectory(
        manager,
        remotePath,
        totalSize,
      );
      if (directoryInfo == null || directoryInfo.imageRecords.isEmpty) {
        return null;
      }

      final records = directoryInfo.imageRecords;
      var coverIndex = records.indexWhere((e) => e.isCover);
      if (coverIndex < 0) coverIndex = 0;

      await metaDir.deleteIgnoreError(recursive: true);
      await metaDir.create(recursive: true);

      final coverRecord = records[coverIndex];
      final coverBytes = await _readZipImageRecordBytes(
        manager: manager,
        remotePath: remotePath,
        record: coverRecord,
      );
      if (coverBytes.isEmpty) return null;
      final coverExt = _pickImageExtensionFromNameOrBytes(
        coverRecord.fileName,
        coverBytes,
      );
      final coverName = 'cover.$coverExt';
      await metaDir.joinFile(coverName).writeAsBytes(coverBytes, flush: false);

      final createdAt = DateTime.now();
      final metadataToSave = <String, dynamic>{
        'schema': _streamMetaSchemaVersion,
        'id': 'webdav_archive_stream_$key',
        'title': _stripFileExtension(fileName),
        'subtitle': '',
        'tags': const <String>['webdav:archive', 'webdav:stream'],
        'directory': encodeStreamDirectory(metaDir.path),
        'cover': coverName,
        'pages': records.length,
        'imageCount': records.length,
        'coverIndex': coverIndex,
        'entries': records.map((e) => e.toJson()).toList(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'remotePath': remotePath,
        'remoteSize': remoteSize ?? totalSize,
        'remoteModifiedTime': remoteModifiedTime?.millisecondsSinceEpoch,
      };
      await metadataFile.writeAsString(jsonEncode(metadataToSave));
      _streamMetaCache.remove(key);
      return _bookFromStreamMetadata(metadataToSave, fileName);
    } catch (e, s) {
      Log.warning(
        'WebDavArchiveService',
        'prepareStreamingMeta failed for $remotePath: $e\n$s',
      );
      return null;
    }
  }

  /// 仅获取 ZIP/CBZ 封面，成功返回本地路径。
  Future<String?> fetchCoverOnly({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    final book = await prepareStreamingMeta(
      remotePath: remotePath,
      fileName: fileName,
      remoteSize: remoteSize,
      remoteModifiedTime: remoteModifiedTime,
    );
    if (book == null) return null;
    final dir = decodeStreamDirectory(book.directory);
    if (dir == null || dir.isEmpty) return null;
    final coverFile = File(FilePath.join(dir, book.cover));
    if (await coverFile.exists() && await coverFile.length() > 0) {
      return coverFile.path;
    }
    return null;
  }

  /// 取消指定 metaKey 的所有排队中的预取任务，释放并发槽位。
  void cancelPrefetch(String metaKey) {
    _streamPrefetchQueue.removeWhere((task) {
      if (task.metaKey == metaKey) {
        if (!task.done.isCompleted) {
          task.done.complete();
        }
        return true;
      }
      return false;
    });
    _streamPrefetchInFlight.removeWhere(
      (key, _) => key.startsWith('$metaKey/'),
    );
  }

  /// 按页读取流式 ZIP 图片。
  Future<Uint8List> readStreamingImage({
    required String metaKey,
    required int imageIndex,
  }) async {
    // 切换漫画时自动取消旧的预取任务
    if (_activeMetaKey != null && _activeMetaKey != metaKey) {
      cancelPrefetch(_activeMetaKey!);
    }
    _activeMetaKey = metaKey;

    final requestKey = '$metaKey/$imageIndex';
    final inFlight = _streamReadInFlight[requestKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _readStreamingImageInternal(
      metaKey: metaKey,
      imageIndex: imageIndex,
    );
    _streamReadInFlight[requestKey] = future;
    try {
      final bytes = await future;
      unawaited(
        prefetchStreamingAround(
          metaKey: metaKey,
          centerIndex: imageIndex,
          before: _streamPrefetchBefore,
          after: _streamPrefetchAfter,
        ),
      );
      return bytes;
    } finally {
      if (identical(_streamReadInFlight[requestKey], future)) {
        _streamReadInFlight.remove(requestKey);
      }
    }
  }

  Future<void> prefetchStreamingAround({
    required String metaKey,
    required int centerIndex,
    int before = 1,
    int after = 2,
  }) async {
    if (before <= 0 && after <= 0) return;

    _ArchiveStreamMeta streamMeta;
    try {
      streamMeta = await _loadStreamMeta(metaKey);
    } catch (_) {
      return;
    }

    final total = streamMeta.entries.length;
    if (total <= 0) return;

    final targets = <int>[];
    for (int i = 1; i <= after; i++) {
      final target = centerIndex + i;
      if (target >= 0 && target < total) {
        targets.add(target);
      }
    }
    for (int i = 1; i <= before; i++) {
      final target = centerIndex - i;
      if (target >= 0 && target < total) {
        targets.add(target);
      }
    }

    for (final target in targets) {
      final requestKey = '$metaKey/$target';
      if (_streamReadInFlight.containsKey(requestKey)) continue;
      final existing = _streamPrefetchInFlight[requestKey];
      if (existing != null) continue;
      final future = _enqueueStreamPrefetch(metaKey, target);
      _streamPrefetchInFlight[requestKey] = future;
    }
  }

  Future<Uint8List> _readStreamingImageInternal({
    required String metaKey,
    required int imageIndex,
  }) async {
    final streamMeta = await _loadStreamMeta(metaKey);
    if (imageIndex < 0 || imageIndex >= streamMeta.entries.length) {
      throw Exception('Archive stream image index out of range: $imageIndex');
    }

    final cachedFile = await _findCachedStreamImage(
      streamMeta.metaDir,
      imageIndex,
    );
    if (cachedFile != null) {
      return cachedFile.readAsBytes();
    }

    final record = streamMeta.entries[imageIndex];
    final bytes = await _readZipImageRecordBytesWithRetry(
      manager: WebDavComicManager(),
      remotePath: streamMeta.remotePath,
      record: record,
      maxAttempts: _streamReadRetryTimes,
    );
    if (bytes.isEmpty) {
      throw Exception('Archive stream image is empty: $imageIndex');
    }

    final ext = _pickImageExtensionFromNameOrBytes(record.fileName, bytes);
    final outFile = streamMeta.metaDir.joinFile('$imageIndex.$ext');
    try {
      await outFile.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // 缓存写入失败不影响读取
    }
    return bytes;
  }

  Future<_ArchiveStreamMeta> _loadStreamMeta(String metaKey) async {
    final cached = _streamMetaCache[metaKey];
    if (cached != null) {
      return cached;
    }

    final metaDir = Directory(
      FilePath.join(App.cachePath, 'webdav_archive_stream', metaKey),
    );
    final metaFile = metaDir.joinFile('meta.json');
    if (!await metaFile.exists()) {
      throw Exception('Archive stream metadata not found');
    }

    final metaJson = jsonDecode(await metaFile.readAsString());
    if (metaJson is! Map<String, dynamic>) {
      throw Exception('Invalid archive stream metadata');
    }

    final remotePath = metaJson['remotePath'] as String?;
    final entries = metaJson['entries'];
    if (remotePath == null || entries is! List) {
      throw Exception('Archive stream metadata is missing entries');
    }

    final parsedEntries = <_ArchiveZipImageRecord>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      parsedEntries.add(
        _ArchiveZipImageRecord.fromJson(Map<String, dynamic>.from(entry)),
      );
    }
    if (parsedEntries.isEmpty) {
      throw Exception('Archive stream metadata has no readable entries');
    }

    final result = _ArchiveStreamMeta(
      metaDir: metaDir,
      remotePath: remotePath,
      entries: parsedEntries,
    );
    _streamMetaCache[metaKey] = result;
    if (_streamMetaCache.length > 128) {
      _streamMetaCache.remove(_streamMetaCache.keys.first);
    }
    return result;
  }

  Future<void> _enqueueStreamPrefetch(String metaKey, int imageIndex) async {
    final task = _ArchiveStreamPrefetchTask(
      metaKey: metaKey,
      imageIndex: imageIndex,
    );
    _streamPrefetchQueue.add(task);
    _pumpStreamPrefetchQueue();
    await task.done.future;
  }

  void _pumpStreamPrefetchQueue() {
    while (_streamPrefetchRunning < _maxStreamPrefetchConcurrency &&
        _streamPrefetchQueue.isNotEmpty) {
      final task = _streamPrefetchQueue.removeAt(0);
      _streamPrefetchRunning++;
      unawaited(
        Future<void>(() async {
          try {
            final requestKey = '${task.metaKey}/${task.imageIndex}';
            final existing = _streamReadInFlight[requestKey];
            if (existing != null) {
              await existing;
            } else {
              final future = _readStreamingImageInternal(
                metaKey: task.metaKey,
                imageIndex: task.imageIndex,
              );
              _streamReadInFlight[requestKey] = future;
              try {
                await future;
              } finally {
                if (identical(_streamReadInFlight[requestKey], future)) {
                  _streamReadInFlight.remove(requestKey);
                }
              }
            }
          } catch (_) {
            // 预取失败不影响主流程
          } finally {
            final requestKey = '${task.metaKey}/${task.imageIndex}';
            _streamPrefetchInFlight.remove(requestKey);
            if (!task.done.isCompleted) {
              task.done.complete();
            }
            _streamPrefetchRunning--;
            _pumpStreamPrefetchQueue();
          }
        }),
      );
    }
  }

  Future<Uint8List> _readZipImageRecordBytesWithRetry({
    required WebDavComicManager manager,
    required String remotePath,
    required _ArchiveZipImageRecord record,
    required int maxAttempts,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _readZipImageRecordBytes(
          manager: manager,
          remotePath: remotePath,
          record: record,
        );
      } catch (e, s) {
        lastError = e;
        lastStack = s;
        if (attempt >= maxAttempts) {
          break;
        }
        await Future.delayed(Duration(milliseconds: 120 * attempt));
      }
    }
    if (lastError != null && lastStack != null) {
      Error.throwWithStackTrace(lastError, lastStack);
    }
    throw Exception('Archive stream read failed');
  }

  Future<Map<String, dynamic>?> _loadMetadata(File metadataFile) async {
    if (!await metadataFile.exists()) return null;
    try {
      final content = await metadataFile.readAsString();
      final json = jsonDecode(content);
      if (json is Map<String, dynamic>) {
        return json;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _isCacheUsable(
    Map<String, dynamic>? metadata,
    int? remoteSize,
    DateTime? remoteModifiedTime,
    Directory cacheDir,
  ) {
    if (metadata == null) return false;
    if (metadata['schema'] != _metaSchemaVersion) return false;
    if (!cacheDir.existsSync()) return false;

    final remoteSizeInMeta = metadata['remoteSize'];
    if (remoteSize != null &&
        remoteSizeInMeta is int &&
        remoteSizeInMeta != remoteSize) {
      return false;
    }

    final remoteModifiedInMeta = metadata['remoteModifiedTime'];
    if (remoteModifiedTime != null &&
        remoteModifiedInMeta is int &&
        remoteModifiedInMeta != remoteModifiedTime.millisecondsSinceEpoch) {
      return false;
    }

    final cover = metadata['cover'] as String?;
    if (cover == null || cover.isEmpty) return false;
    final coverFile = cacheDir.joinFile(cover);
    if (!coverFile.existsSync()) return false;

    final pages = metadata['pages'];
    return pages is int && pages > 0;
  }

  bool _isStreamCacheUsable(
    Map<String, dynamic>? metadata,
    int? remoteSize,
    DateTime? remoteModifiedTime,
    Directory metaDir,
  ) {
    if (metadata == null) return false;
    if (metadata['schema'] != _streamMetaSchemaVersion) return false;
    if (!metaDir.existsSync()) return false;

    final remoteSizeInMeta = metadata['remoteSize'];
    if (remoteSize != null &&
        remoteSizeInMeta is int &&
        remoteSizeInMeta != remoteSize) {
      return false;
    }

    final remoteModifiedInMeta = metadata['remoteModifiedTime'];
    if (remoteModifiedTime != null &&
        remoteModifiedInMeta is int &&
        remoteModifiedInMeta != remoteModifiedTime.millisecondsSinceEpoch) {
      return false;
    }

    final imageCount = metadata['imageCount'];
    if (imageCount is! int || imageCount <= 0) return false;
    final entries = metadata['entries'];
    if (entries is! List || entries.length != imageCount) return false;

    final cover = metadata['cover'] as String?;
    if (cover == null || cover.isEmpty) return false;
    final coverFile = metaDir.joinFile(cover);
    if (!coverFile.existsSync()) return false;
    return true;
  }

  WebDavArchiveBook _bookFromMetadata(
    Map<String, dynamic> metadata,
    String fallbackFileName,
  ) {
    final fallbackTitle = _stripFileExtension(fallbackFileName);
    return WebDavArchiveBook(
      id: metadata['id'] as String,
      title: (metadata['title'] as String?)?.trim().isNotEmpty == true
          ? metadata['title'] as String
          : fallbackTitle,
      subtitle: metadata['subtitle'] as String? ?? '',
      tags: List<String>.from(metadata['tags'] ?? const <String>[]),
      directory: metadata['directory'] as String,
      cover: metadata['cover'] as String,
      pages: metadata['pages'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        metadata['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  WebDavArchiveBook _bookFromStreamMetadata(
    Map<String, dynamic> metadata,
    String fallbackFileName,
  ) {
    final fallbackTitle = _stripFileExtension(fallbackFileName);
    return WebDavArchiveBook(
      id: metadata['id'] as String,
      title: (metadata['title'] as String?)?.trim().isNotEmpty == true
          ? metadata['title'] as String
          : fallbackTitle,
      subtitle: metadata['subtitle'] as String? ?? '',
      tags: List<String>.from(metadata['tags'] ?? const <String>[]),
      directory: metadata['directory'] as String,
      cover: metadata['cover'] as String? ?? 'cover.jpg',
      pages: metadata['imageCount'] as int? ?? metadata['pages'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        metadata['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<_ZipCentralDirectoryInfo?> _parseZipCentralDirectory(
    WebDavComicManager manager,
    String remotePath,
    int totalSize,
  ) async {
    if (totalSize <= 22) return null;

    final tailReadSize = math.min(totalSize, _zipTailReadSize);
    final tailStart = math.max(totalSize - tailReadSize, 0);
    final tailResult = await manager.readFileRange(
      remotePath,
      start: tailStart,
      end: totalSize - 1,
    );
    if (!tailResult.isPartial) {
      return null;
    }

    final tailBytes = tailResult.bytes;
    final eocdOffsetInTail = _findLastSignature(tailBytes, _zipEocdSignature);
    if (eocdOffsetInTail < 0 || eocdOffsetInTail + 22 > tailBytes.length) {
      return null;
    }

    var centralDirectoryOffset = _readUint32LE(
      tailBytes,
      eocdOffsetInTail + 16,
    );
    var centralDirectorySize = _readUint32LE(tailBytes, eocdOffsetInTail + 12);
    var entryCount = _readUint16LE(tailBytes, eocdOffsetInTail + 10);

    final needsZip64 =
        entryCount == 0xFFFF ||
        centralDirectorySize == 0xFFFFFFFF ||
        centralDirectoryOffset == 0xFFFFFFFF;
    if (needsZip64) {
      final locatorOffset = eocdOffsetInTail - 20;
      if (locatorOffset < 0 || locatorOffset + 20 > tailBytes.length) {
        return null;
      }
      final locatorSignature = _readUint32LE(tailBytes, locatorOffset);
      if (locatorSignature != _zip64LocatorSignature) {
        return null;
      }

      final zip64EocdOffset = _readUint64LE(tailBytes, locatorOffset + 8);
      final zip64Result = await manager.readFileRange(
        remotePath,
        start: zip64EocdOffset,
        end: zip64EocdOffset + 95,
      );
      if (!zip64Result.isPartial || zip64Result.bytes.length < 56) {
        return null;
      }
      final zip64Bytes = zip64Result.bytes;
      final zip64Signature = _readUint32LE(zip64Bytes, 0);
      if (zip64Signature != _zip64EocdSignature) {
        return null;
      }

      entryCount = _readUint64LE(zip64Bytes, 32);
      centralDirectorySize = _readUint64LE(zip64Bytes, 40);
      centralDirectoryOffset = _readUint64LE(zip64Bytes, 48);
    }

    if (entryCount <= 0 ||
        centralDirectorySize <= 0 ||
        centralDirectoryOffset < 0) {
      return null;
    }
    if (centralDirectorySize > _maxCentralDirectorySize) {
      return null;
    }
    if (centralDirectoryOffset + centralDirectorySize > totalSize) {
      return null;
    }

    final centralDirectoryResult = await manager.readFileRange(
      remotePath,
      start: centralDirectoryOffset,
      end: centralDirectoryOffset + centralDirectorySize - 1,
    );
    final centralDirectoryData = centralDirectoryResult.bytes;
    if (centralDirectoryData.length < centralDirectorySize) {
      return null;
    }

    final imageRecords = _parseZipImageRecords(centralDirectoryData, totalSize);
    if (imageRecords.isEmpty) {
      return null;
    }

    return _ZipCentralDirectoryInfo(
      entryCount: entryCount,
      centralDirectoryOffset: centralDirectoryOffset,
      centralDirectorySize: centralDirectorySize,
      imageRecords: imageRecords,
    );
  }

  List<_ArchiveZipImageRecord> _parseZipImageRecords(
    Uint8List centralDirectoryData,
    int totalSize,
  ) {
    final records = <_ArchiveZipImageRecord>[];
    var offset = 0;

    while (offset + 46 <= centralDirectoryData.length) {
      final signature = _readUint32LE(centralDirectoryData, offset);
      if (signature != _zipCentralDirFileHeaderSignature) {
        break;
      }

      final flags = _readUint16LE(centralDirectoryData, offset + 8);
      final method = _readUint16LE(centralDirectoryData, offset + 10);
      final compressedSize32 = _readUint32LE(centralDirectoryData, offset + 20);
      final uncompressedSize32 = _readUint32LE(
        centralDirectoryData,
        offset + 24,
      );
      final fileNameLength = _readUint16LE(centralDirectoryData, offset + 28);
      final extraLength = _readUint16LE(centralDirectoryData, offset + 30);
      final commentLength = _readUint16LE(centralDirectoryData, offset + 32);
      final diskStart = _readUint16LE(centralDirectoryData, offset + 34);
      final localHeaderOffset32 = _readUint32LE(
        centralDirectoryData,
        offset + 42,
      );

      final nextOffset =
          offset + 46 + fileNameLength + extraLength + commentLength;
      if (nextOffset > centralDirectoryData.length) {
        break;
      }

      final fileNameStart = offset + 46;
      final fileNameEnd = fileNameStart + fileNameLength;
      final extraStart = fileNameEnd;
      final extraEnd = extraStart + extraLength;
      final nameBytes = Uint8List.sublistView(
        centralDirectoryData,
        fileNameStart,
        fileNameEnd,
      );
      final extraBytes = Uint8List.sublistView(
        centralDirectoryData,
        extraStart,
        extraEnd,
      );
      final fileName = _decodeZipFileName(nameBytes, flags);
      final normalizedName = fileName.replaceAll('\\', '/');
      final simpleName = normalizedName.split('/').last;
      final isDirectory =
          normalizedName.endsWith('/') || normalizedName.endsWith('\\');

      var compressedSize = compressedSize32;
      var uncompressedSize = uncompressedSize32;
      var localHeaderOffset = localHeaderOffset32;
      if (compressedSize32 == 0xFFFFFFFF ||
          uncompressedSize32 == 0xFFFFFFFF ||
          localHeaderOffset32 == 0xFFFFFFFF ||
          diskStart == 0xFFFF) {
        final zip64Info = _parseZip64ExtendedInfo(
          extraBytes,
          hasUncompressedSize: uncompressedSize32 == 0xFFFFFFFF,
          hasCompressedSize: compressedSize32 == 0xFFFFFFFF,
          hasLocalHeaderOffset: localHeaderOffset32 == 0xFFFFFFFF,
        );
        if (uncompressedSize32 == 0xFFFFFFFF) {
          uncompressedSize = zip64Info.uncompressedSize;
        }
        if (compressedSize32 == 0xFFFFFFFF) {
          compressedSize = zip64Info.compressedSize;
        }
        if (localHeaderOffset32 == 0xFFFFFFFF) {
          localHeaderOffset = zip64Info.localHeaderOffset;
        }
      }

      final encrypted = (flags & 0x01) != 0;
      final supportedMethod = method == 0 || method == 8;
      final isValidImage =
          !isDirectory &&
          _isImageFile(fileName) &&
          !encrypted &&
          supportedMethod &&
          compressedSize > 0 &&
          compressedSize <= _maxEntryCompressedSize &&
          localHeaderOffset >= 0 &&
          localHeaderOffset + 30 < totalSize;

      if (isValidImage) {
        records.add(
          _ArchiveZipImageRecord(
            fileName: normalizedName,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
            isCover: _isCoverFileName(simpleName),
          ),
        );
      }

      offset = nextOffset;
    }

    records.sort(_compareZipImageRecords);
    return records;
  }

  _Zip64ExtendedInfo _parseZip64ExtendedInfo(
    Uint8List extraBytes, {
    required bool hasUncompressedSize,
    required bool hasCompressedSize,
    required bool hasLocalHeaderOffset,
  }) {
    var offset = 0;
    while (offset + 4 <= extraBytes.length) {
      final headerId = _readUint16LE(extraBytes, offset);
      final dataSize = _readUint16LE(extraBytes, offset + 2);
      final dataStart = offset + 4;
      final dataEnd = dataStart + dataSize;
      if (dataEnd > extraBytes.length) break;

      if (headerId == 0x0001) {
        var cursor = dataStart;
        var uncompressedSize = -1;
        var compressedSize = -1;
        var localHeaderOffset = -1;

        if (hasUncompressedSize && cursor + 8 <= dataEnd) {
          uncompressedSize = _readUint64LE(extraBytes, cursor);
          cursor += 8;
        }
        if (hasCompressedSize && cursor + 8 <= dataEnd) {
          compressedSize = _readUint64LE(extraBytes, cursor);
          cursor += 8;
        }
        if (hasLocalHeaderOffset && cursor + 8 <= dataEnd) {
          localHeaderOffset = _readUint64LE(extraBytes, cursor);
        }
        return _Zip64ExtendedInfo(
          uncompressedSize: uncompressedSize,
          compressedSize: compressedSize,
          localHeaderOffset: localHeaderOffset,
        );
      }
      offset = dataEnd;
    }

    return const _Zip64ExtendedInfo(
      uncompressedSize: -1,
      compressedSize: -1,
      localHeaderOffset: -1,
    );
  }

  Future<Uint8List> _readZipImageRecordBytes({
    required WebDavComicManager manager,
    required String remotePath,
    required _ArchiveZipImageRecord record,
  }) async {
    final localHeaderStart = record.localHeaderOffset;
    final localHeaderResult = await manager.readFileRange(
      remotePath,
      start: localHeaderStart,
      end: localHeaderStart + 29,
    );
    final localHeaderData = localHeaderResult.bytes;
    if (localHeaderData.length < 30) {
      throw Exception('Invalid local header size');
    }
    final localHeaderSignature = _readUint32LE(localHeaderData, 0);
    if (localHeaderSignature != _zipLocalFileHeaderSignature) {
      throw Exception('Invalid local header signature');
    }

    final fileNameLength = _readUint16LE(localHeaderData, 26);
    final extraLength = _readUint16LE(localHeaderData, 28);
    final dataStart = localHeaderStart + 30 + fileNameLength + extraLength;
    final dataEnd = dataStart + record.compressedSize - 1;
    if (dataEnd < dataStart) {
      throw Exception('Invalid archive data range');
    }

    final compressedResult = await manager.readFileRange(
      remotePath,
      start: dataStart,
      end: dataEnd,
    );
    final compressedBytes = compressedResult.bytes;
    if (compressedBytes.isEmpty) {
      throw Exception('Archive image data is empty');
    }

    if (record.method == 0) {
      return compressedBytes;
    }
    if (record.method == 8) {
      final decoded = ZLibDecoder(raw: true).convert(compressedBytes);
      return Uint8List.fromList(decoded);
    }
    throw Exception('Unsupported zip compression method: ${record.method}');
  }

  Future<File?> _findCachedStreamImage(
    Directory metaDir,
    int imageIndex,
  ) async {
    if (!await metaDir.exists()) return null;
    for (final ext in const [
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'bmp',
      'avif',
      'heic',
      'heif',
      'tif',
      'tiff',
    ]) {
      final file = metaDir.joinFile('$imageIndex.$ext');
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
    }
    return null;
  }

  int _compareZipImageRecords(
    _ArchiveZipImageRecord a,
    _ArchiveZipImageRecord b,
  ) {
    final aNum = _extractFirstNumber(_baseName(a.fileName));
    final bNum = _extractFirstNumber(_baseName(b.fileName));
    if (aNum != null && bNum != null && aNum != bNum) {
      return aNum.compareTo(bNum);
    }
    return a.fileName.compareTo(b.fileName);
  }

  int _findLastSignature(Uint8List bytes, int signature) {
    if (bytes.length < 4) return -1;
    final b0 = signature & 0xFF;
    final b1 = (signature >> 8) & 0xFF;
    final b2 = (signature >> 16) & 0xFF;
    final b3 = (signature >> 24) & 0xFF;
    for (var i = bytes.length - 4; i >= 0; i--) {
      if (bytes[i] == b0 &&
          bytes[i + 1] == b1 &&
          bytes[i + 2] == b2 &&
          bytes[i + 3] == b3) {
        return i;
      }
    }
    return -1;
  }

  String _decodeZipFileName(Uint8List fileNameBytes, int flags) {
    if ((flags & 0x0800) != 0) {
      return utf8.decode(fileNameBytes, allowMalformed: true);
    }
    return latin1.decode(fileNameBytes);
  }

  int _readUint16LE(Uint8List data, int offset) {
    return data[offset] | (data[offset + 1] << 8);
  }

  int _readUint32LE(Uint8List data, int offset) {
    return (data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24)) &
        0xFFFFFFFF;
  }

  int _readUint64LE(Uint8List data, int offset) {
    final low = _readUint32LE(data, offset);
    final high = _readUint32LE(data, offset + 4);
    return (high << 32) | (low & 0xFFFFFFFF);
  }

  String _pickImageExtensionFromNameOrBytes(String fileName, Uint8List bytes) {
    final magic = _detectImageMagic(bytes);
    if (magic != null) return magic;
    final ext = fileName.split('.').last.toLowerCase();
    if (_isImageExtension(ext)) return ext;
    return 'jpg';
  }

  String? _detectImageMagic(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'jpg';
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'gif';
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return null;
  }

  String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index >= 0 && index < normalized.length - 1) {
      return normalized.substring(index + 1);
    }
    return normalized;
  }

  Future<List<_ArchiveImageEntry>> _collectImageFiles(Directory root) async {
    final files = <_ArchiveImageEntry>[];
    if (!await root.exists()) return files;

    await for (var entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!_isImageFile(entity.name)) continue;
      final relative = _normalizeRelativePath(entity.path, root.path);
      if (relative.isEmpty) continue;
      files.add(
        _ArchiveImageEntry(
          file: entity,
          relativePath: relative,
          isCover: _isCoverFileName(entity.name),
        ),
      );
    }

    files.sort(_compareArchiveImages);
    return files;
  }

  int _compareArchiveImages(_ArchiveImageEntry a, _ArchiveImageEntry b) {
    final aNum = _extractFirstNumber(a.file.name);
    final bNum = _extractFirstNumber(b.file.name);
    if (aNum != null && bNum != null && aNum != bNum) {
      return aNum.compareTo(bNum);
    }
    return a.relativePath.compareTo(b.relativePath);
  }

  int? _extractFirstNumber(String name) {
    final match = RegExp(r'\d+').firstMatch(name);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  String _normalizeRelativePath(String fullPath, String rootPath) {
    var relative = fullPath;
    if (relative.startsWith(rootPath)) {
      relative = relative.substring(rootPath.length);
    }
    while (relative.startsWith('/') || relative.startsWith('\\')) {
      relative = relative.substring(1);
    }
    return relative.replaceAll('\\', '/');
  }

  bool _isCoverFileName(String fileName) {
    return fileName.toLowerCase().startsWith('cover');
  }

  String _pickImageExtension(File file) {
    final ext = file.extension.toLowerCase();
    if (_isImageExtension(ext)) return ext;
    return 'jpg';
  }

  bool _isImageFile(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return _isImageExtension(ext);
  }

  bool _isImageExtension(String ext) {
    const imageExtensions = [
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'jpe',
      'avif',
      'bmp',
      'tif',
      'tiff',
      'jfif',
      'heic',
      'heif',
    ];
    return imageExtensions.contains(ext);
  }

  String _pickArchiveExtension(String fileName) {
    final ext = fileName.split('.').last.trim().toLowerCase();
    if (ext.isEmpty || ext == fileName.toLowerCase()) {
      return '.bin';
    }
    return '.$ext';
  }

  String _stripFileExtension(String fileName) {
    final index = fileName.lastIndexOf('.');
    if (index > 0) {
      return fileName.substring(0, index).trim();
    }
    return fileName.trim();
  }

  String _normalizeRemotePath(String path) {
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    return path;
  }
}

class _ArchiveImageEntry {
  final File file;
  final String relativePath;
  final bool isCover;

  const _ArchiveImageEntry({
    required this.file,
    required this.relativePath,
    required this.isCover,
  });
}

class _ArchiveStreamMeta {
  final Directory metaDir;
  final String remotePath;
  final List<_ArchiveZipImageRecord> entries;

  const _ArchiveStreamMeta({
    required this.metaDir,
    required this.remotePath,
    required this.entries,
  });
}

class _ArchiveStreamPrefetchTask {
  final String metaKey;
  final int imageIndex;
  final Completer<void> done = Completer<void>();

  _ArchiveStreamPrefetchTask({required this.metaKey, required this.imageIndex});
}

class _ArchiveZipImageRecord {
  final String fileName;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final bool isCover;

  const _ArchiveZipImageRecord({
    required this.fileName,
    required this.method,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.isCover,
  });

  factory _ArchiveZipImageRecord.fromJson(Map<String, dynamic> json) {
    int readInt(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return _ArchiveZipImageRecord(
      fileName: json['fileName'] as String? ?? '',
      method: readInt('method'),
      compressedSize: readInt('compressedSize'),
      uncompressedSize: readInt('uncompressedSize'),
      localHeaderOffset: readInt('localHeaderOffset'),
      isCover: json['isCover'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fileName': fileName,
      'method': method,
      'compressedSize': compressedSize,
      'uncompressedSize': uncompressedSize,
      'localHeaderOffset': localHeaderOffset,
      'isCover': isCover,
    };
  }
}

class _ZipCentralDirectoryInfo {
  final int entryCount;
  final int centralDirectoryOffset;
  final int centralDirectorySize;
  final List<_ArchiveZipImageRecord> imageRecords;

  const _ZipCentralDirectoryInfo({
    required this.entryCount,
    required this.centralDirectoryOffset,
    required this.centralDirectorySize,
    required this.imageRecords,
  });
}

class _Zip64ExtendedInfo {
  final int uncompressedSize;
  final int compressedSize;
  final int localHeaderOffset;

  const _Zip64ExtendedInfo({
    required this.uncompressedSize,
    required this.compressedSize,
    required this.localHeaderOffset,
  });
}
