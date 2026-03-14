// WebDAV EPUB 漫画解析与缓存服务
// @author: luoyang

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/io.dart';

class WebDavEpubBook {
  final String id;
  final String title;
  final String subtitle;
  final List<String> tags;
  final String directory;
  final String cover;
  final int pages;
  final DateTime createdAt;

  const WebDavEpubBook({
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

class WebDavEpubService {
  WebDavEpubService._();

  static WebDavEpubService? _instance;

  factory WebDavEpubService() {
    return _instance ??= WebDavEpubService._();
  }

  static const String streamDirectoryPrefix = 'webdav-epub-stream://';
  static const int _streamMetaSchemaVersion = 1;
  static const int _zipTailReadSize = 512 * 1024;
  static const int _maxCentralDirectorySize = 32 * 1024 * 1024;
  static const int _maxEntryCompressedSize = 64 * 1024 * 1024;
  static const int _maxXmlEntrySize = 2 * 1024 * 1024;

  static const int _zipEocdSignature = 0x06054b50;
  static const int _zip64EocdSignature = 0x06064b50;
  static const int _zip64LocatorSignature = 0x07064b50;
  static const int _zipCentralDirFileHeaderSignature = 0x02014b50;
  static const int _zipLocalFileHeaderSignature = 0x04034b50;
  static const int _streamReadRetryTimes = 2;
  static const int _maxStreamPrefetchConcurrency = 2;
  static const int _streamPrefetchBefore = 1;
  static const int _streamPrefetchAfter = 2;

  // 预编译正则表达式
  static final _containerRootfileRe = RegExp(
    r'<rootfile[^>]+full-path\s*=\s*"([^"]+)"',
    caseSensitive: false,
  );
  static final _titleRe = RegExp(
    r'<dc:title[^>]*>([^<]+)</dc:title>',
    caseSensitive: false,
  );
  static final _authorRe = RegExp(
    r'<dc:creator[^>]*>([^<]+)</dc:creator>',
    caseSensitive: false,
  );
  static final _coverMetaRe = RegExp(
    r'<meta[^>]+name\s*=\s*"cover"[^>]+content\s*=\s*"([^"]+)"',
    caseSensitive: false,
  );
  static final _itemRe = RegExp(
    r'<item\s[^>]*/>|<item\s[^>]*>[^<]*</item>',
    caseSensitive: false,
  );
  static final _attrIdRe = RegExp(r'id\s*=\s*"([^"]+)"');
  static final _attrHrefRe = RegExp(r'href\s*=\s*"([^"]+)"');
  static final _attrMediaTypeRe = RegExp(r'media-type\s*=\s*"([^"]+)"');

  final Map<String, Future<Uint8List>> _streamReadInFlight = {};
  final Map<String, _EpubStreamMeta> _streamMetaCache = {};
  final Map<String, Future<void>> _streamPrefetchInFlight = {};
  final List<_EpubStreamPrefetchTask> _streamPrefetchQueue = [];
  int _streamPrefetchRunning = 0;
  String? _activeMetaKey;

  static bool isStreamDirectory(String directory) {
    return directory.startsWith(streamDirectoryPrefix);
  }

  static String encodeStreamDirectory(String localPath) {
    return '$streamDirectoryPrefix${Uri.encodeComponent(localPath)}';
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

  /// 通过 Range 请求解析 EPUB（ZIP）结构，提取图片条目列表。
  /// 失败时返回 null。
  Future<WebDavEpubBook?> prepareStreamingMeta({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();
    final metaDir = Directory(
      FilePath.join(App.cachePath, 'webdav_epub_stream', key),
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
      } catch (e) {
        Log.warning('WebDavEpubService', 'Stream meta cache corrupted: $e');
      }
    }

    try {
      final manager = WebDavComicManager();
      var totalSize = remoteSize;
      totalSize ??= await manager.getFileSize(remotePath);
      if (totalSize <= 0) return null;

      // 1. 解析 ZIP 中央目录，获取所有条目
      final allRecords = await _parseZipAllRecords(
        manager,
        remotePath,
        totalSize,
      );
      if (allRecords == null || allRecords.isEmpty) return null;

      // 2. 读取 META-INF/container.xml，定位 content.opf
      final containerRecord = allRecords.firstWhere(
        (r) =>
            r.fileName.toLowerCase() == 'meta-inf/container.xml' &&
            r.compressedSize < _maxXmlEntrySize,
        orElse: () => _ZipEntryRecord.empty(),
      );
      if (containerRecord.isEmpty) return null;

      final containerXml = await _readZipEntryAsString(
        manager: manager,
        remotePath: remotePath,
        record: containerRecord,
      );
      if (containerXml == null) return null;

      final opfPath = _parseContainerXml(containerXml);
      if (opfPath == null) return null;

      // 3. 读取 content.opf，提取图片清单和阅读顺序
      final opfRecord = allRecords.firstWhere(
        (r) =>
            r.fileName == opfPath &&
            r.compressedSize < _maxXmlEntrySize,
        orElse: () => _ZipEntryRecord.empty(),
      );
      if (opfRecord.isEmpty) return null;

      final opfXml = await _readZipEntryAsString(
        manager: manager,
        remotePath: remotePath,
        record: opfRecord,
      );
      if (opfXml == null) return null;

      final opfDir =
          opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
      final epubMeta = _parseContentOpf(opfXml, opfDir);

      // 4. 将 OPF 中的图片引用匹配到 ZIP 条目
      final entryMap = <String, _ZipEntryRecord>{};
      for (final r in allRecords) {
        entryMap[r.fileName] = r;
      }

      final imageRecords = <_EpubZipImageRecord>[];
      for (final href in epubMeta.imageHrefs) {
        final record = entryMap[href];
        if (record == null) continue;
        if (record.compressedSize <= 0 ||
            record.compressedSize > _maxEntryCompressedSize) {
          continue;
        }
        imageRecords.add(
          _EpubZipImageRecord(
            fileName: record.fileName,
            method: record.method,
            compressedSize: record.compressedSize,
            uncompressedSize: record.uncompressedSize,
            localHeaderOffset: record.localHeaderOffset,
            isCover: record.fileName == epubMeta.coverHref,
          ),
        );
      }

      if (imageRecords.isEmpty) return null;

      // 5. 下载封面图
      await metaDir.deleteIgnoreError(recursive: true);
      await metaDir.create(recursive: true);

      var coverIndex = imageRecords.indexWhere((e) => e.isCover);
      if (coverIndex < 0) coverIndex = 0;

      final coverRecord = imageRecords[coverIndex];
      final coverBytes = await _readZipEntryBytes(
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

      // 6. 保存元数据
      final createdAt = DateTime.now();
      final metadataToSave = <String, dynamic>{
        'schema': _streamMetaSchemaVersion,
        'id': 'webdav_epub_stream_$key',
        'title': epubMeta.title ?? _stripFileExtension(fileName),
        'subtitle': epubMeta.author ?? '',
        'tags': const <String>['webdav:epub', 'webdav:stream'],
        'directory': encodeStreamDirectory(metaDir.path),
        'cover': coverName,
        'pages': imageRecords.length,
        'imageCount': imageRecords.length,
        'coverIndex': coverIndex,
        'entries': imageRecords.map((e) => e.toJson()).toList(),
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
        'WebDavEpubService',
        'prepareStreamingMeta failed for $remotePath: $e\n$s',
      );
      return null;
    }
  }

  /// 仅获取 EPUB 封面，成功返回本地路径。
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

  /// 按页读取流式 EPUB 图片。
  Future<Uint8List> readStreamingImage({
    required String metaKey,
    required int imageIndex,
  }) async {
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

    _EpubStreamMeta streamMeta;
    try {
      streamMeta = await _loadStreamMeta(metaKey);
    } catch (_) {
      return;
    }

    final total = streamMeta.entries.length;
    if (total <= 0) return;

    final startIndex = math.max(0, centerIndex - before);
    final endIndex = math.min(total - 1, centerIndex + after);

    for (var i = startIndex; i <= endIndex; i++) {
      if (i == centerIndex) continue;
      final prefetchKey = '$metaKey/$i';
      if (_streamPrefetchInFlight.containsKey(prefetchKey)) continue;
      if (_streamReadInFlight.containsKey(prefetchKey)) continue;

      final metaDir = streamMeta.metaDir;
      final cachedFile = await _findCachedStreamImage(metaDir, i);
      if (cachedFile != null) continue;

      final future = _enqueueStreamPrefetch(metaKey, i);
      _streamPrefetchInFlight[prefetchKey] = future;
    }
  }

  Future<Uint8List> _readStreamingImageInternal({
    required String metaKey,
    required int imageIndex,
  }) async {
    final streamMeta = await _loadStreamMeta(metaKey);
    if (imageIndex < 0 || imageIndex >= streamMeta.entries.length) {
      throw Exception('EPUB stream image index out of range: $imageIndex');
    }

    final metaDir = streamMeta.metaDir;
    final cachedFile = await _findCachedStreamImage(metaDir, imageIndex);
    if (cachedFile != null) {
      return await cachedFile.readAsBytes();
    }

    final record = streamMeta.entries[imageIndex];
    final bytes = await _readZipEntryBytesWithRetry(
      manager: WebDavComicManager(),
      remotePath: streamMeta.remotePath,
      record: record,
      maxAttempts: _streamReadRetryTimes,
    );
    if (bytes.isEmpty) {
      throw Exception('EPUB stream image is empty: $imageIndex');
    }

    final ext = _pickImageExtensionFromNameOrBytes(record.fileName, bytes);
    final outFile = streamMeta.metaDir.joinFile('$imageIndex.$ext');
    try {
      await outFile.writeAsBytes(bytes, flush: false);
    } catch (e) {
      Log.warning('WebDavEpubService', 'Cache write failed: $e');
    }
    return bytes;
  }

  Future<_EpubStreamMeta> _loadStreamMeta(String metaKey) async {
    final cached = _streamMetaCache[metaKey];
    if (cached != null) return cached;

    final metaDir = Directory(
      FilePath.join(App.cachePath, 'webdav_epub_stream', metaKey),
    );
    final metaFile = metaDir.joinFile('meta.json');
    if (!await metaFile.exists()) {
      throw Exception('EPUB stream metadata not found');
    }

    final metaJson = jsonDecode(await metaFile.readAsString());
    if (metaJson is! Map<String, dynamic>) {
      throw Exception('Invalid EPUB stream metadata');
    }

    final remotePath = metaJson['remotePath'] as String?;
    final entries = metaJson['entries'];
    if (remotePath == null || entries is! List) {
      throw Exception('EPUB stream metadata is missing entries');
    }

    final parsedEntries = <_EpubZipImageRecord>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      parsedEntries.add(
        _EpubZipImageRecord.fromJson(Map<String, dynamic>.from(entry)),
      );
    }
    if (parsedEntries.isEmpty) {
      throw Exception('EPUB stream metadata has no readable entries');
    }

    final result = _EpubStreamMeta(
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
    final task = _EpubStreamPrefetchTask(
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
          } catch (e) {
            Log.warning('WebDavEpubService', 'Prefetch failed: $e');
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

  // ─────────────────── EPUB XML 解析 ───────────────────

  /// 从 container.xml 中提取 content.opf 的路径
  String? _parseContainerXml(String xml) {
    // <rootfile full-path="OEBPS/content.opf" .../>
    final match = _containerRootfileRe.firstMatch(xml);
    return match?.group(1);
  }

  /// 从 content.opf 中提取图片清单和元数据
  _EpubContentMeta _parseContentOpf(String xml, String opfDir) {
    // 提取 title
    final titleMatch = _titleRe.firstMatch(xml);
    final title = titleMatch?.group(1)?.trim();

    // 提取 author
    final authorMatch = _authorRe.firstMatch(xml);
    final author = authorMatch?.group(1)?.trim();

    // 提取 cover 图片引用
    // <meta name="cover" content="cover_image"/>
    final coverMetaMatch = _coverMetaRe.firstMatch(xml);
    final coverId = coverMetaMatch?.group(1);

    // 构建 manifest id → href 映射
    final manifestItems = <String, _ManifestItem>{};
    for (final itemMatch in _itemRe.allMatches(xml)) {
      final itemXml = itemMatch.group(0)!;
      final idMatch = _attrIdRe.firstMatch(itemXml);
      final hrefMatch = _attrHrefRe.firstMatch(itemXml);
      final mediaMatch = _attrMediaTypeRe.firstMatch(itemXml);
      if (idMatch == null || hrefMatch == null) continue;
      manifestItems[idMatch.group(1)!] = _ManifestItem(
        id: idMatch.group(1)!,
        href: hrefMatch.group(1)!,
        mediaType: mediaMatch?.group(1) ?? '',
      );
    }

    // 提取 spine 中的 itemref 顺序
    final spineMatch = RegExp(
      r'<spine[^>]*>(.*?)</spine>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);

    // 收集 spine 引用的 HTML 文件中可能嵌入的图片（对于图片型漫画 EPUB）
    // 但更实用的方式：直接收集 manifest 中所有图片类型的条目
    final imageHrefs = <String>[];
    String? coverHref;

    // 确定 cover 图片的 href
    if (coverId != null && manifestItems.containsKey(coverId)) {
      final item = manifestItems[coverId]!;
      coverHref = _resolveHref(item.href, opfDir);
    }

    // 对于漫画 EPUB，图片通常通过 spine 中的 HTML 页面引用
    // 但最可靠的方式是：如果 spine 的 itemref 直接引用图片类型，直接用
    // 否则收集所有图片 manifest 条目
    if (spineMatch != null) {
      final spineContent = spineMatch.group(1)!;
      final itemRefPattern = RegExp(
        r'<itemref[^>]+idref\s*=\s*"([^"]+)"',
        caseSensitive: false,
      );
      for (final ref in itemRefPattern.allMatches(spineContent)) {
        final idRef = ref.group(1)!;
        final item = manifestItems[idRef];
        if (item != null && _isImageMediaType(item.mediaType)) {
          imageHrefs.add(_resolveHref(item.href, opfDir));
        }
      }
    }

    // 如果 spine 中没有找到直接的图片引用，收集 manifest 中所有图片
    if (imageHrefs.isEmpty) {
      // 按 manifest 出现顺序收集所有图片条目
      final imageItems = manifestItems.values
          .where((item) => _isImageMediaType(item.mediaType))
          .toList();

      // 尝试按照数字排序
      imageItems.sort((a, b) {
        final aNum = _extractFirstNumber(a.href);
        final bNum = _extractFirstNumber(b.href);
        if (aNum != null && bNum != null && aNum != bNum) {
          return aNum.compareTo(bNum);
        }
        return a.href.compareTo(b.href);
      });

      for (final item in imageItems) {
        imageHrefs.add(_resolveHref(item.href, opfDir));
      }
    }

    return _EpubContentMeta(
      title: title,
      author: author,
      coverHref: coverHref,
      imageHrefs: imageHrefs,
    );
  }

  String _resolveHref(String href, String opfDir) {
    // 解码 URL 编码
    final decoded = Uri.decodeFull(href);
    if (decoded.startsWith('/')) return decoded.substring(1);
    return '$opfDir$decoded';
  }

  bool _isImageMediaType(String mediaType) {
    return mediaType.startsWith('image/');
  }

  // ─────────────────── ZIP 解析 ───────────────────

  /// 解析 ZIP 中央目录，返回所有条目（不仅限于图片）
  Future<List<_ZipEntryRecord>?> _parseZipAllRecords(
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
    if (!tailResult.isPartial) return null;

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
      if (locatorSignature != _zip64LocatorSignature) return null;

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
      if (_readUint32LE(zip64Bytes, 0) != _zip64EocdSignature) return null;

      entryCount = _readUint64LE(zip64Bytes, 32);
      centralDirectorySize = _readUint64LE(zip64Bytes, 40);
      centralDirectoryOffset = _readUint64LE(zip64Bytes, 48);
    }

    if (entryCount <= 0 ||
        centralDirectorySize <= 0 ||
        centralDirectoryOffset < 0) {
      return null;
    }
    if (centralDirectorySize > _maxCentralDirectorySize) return null;
    if (centralDirectoryOffset + centralDirectorySize > totalSize) return null;

    final cdResult = await manager.readFileRange(
      remotePath,
      start: centralDirectoryOffset,
      end: centralDirectoryOffset + centralDirectorySize - 1,
    );
    final cdData = cdResult.bytes;
    if (cdData.length < centralDirectorySize) return null;

    return _parseAllZipRecords(cdData, totalSize);
  }

  /// 解析中央目录中的所有条目
  List<_ZipEntryRecord> _parseAllZipRecords(
    Uint8List cdData,
    int totalSize,
  ) {
    final records = <_ZipEntryRecord>[];
    var offset = 0;

    while (offset + 46 <= cdData.length) {
      final signature = _readUint32LE(cdData, offset);
      if (signature != _zipCentralDirFileHeaderSignature) break;

      final flags = _readUint16LE(cdData, offset + 8);
      final method = _readUint16LE(cdData, offset + 10);
      final compressedSize32 = _readUint32LE(cdData, offset + 20);
      final uncompressedSize32 = _readUint32LE(cdData, offset + 24);
      final fileNameLength = _readUint16LE(cdData, offset + 28);
      final extraLength = _readUint16LE(cdData, offset + 30);
      final commentLength = _readUint16LE(cdData, offset + 32);
      final diskStart = _readUint16LE(cdData, offset + 34);
      final localHeaderOffset32 = _readUint32LE(cdData, offset + 42);

      final nextOffset = offset + 46 + fileNameLength + extraLength + commentLength;
      if (nextOffset > cdData.length) break;

      final fileNameStart = offset + 46;
      final fileNameEnd = fileNameStart + fileNameLength;
      final extraStart = fileNameEnd;
      final extraEnd = extraStart + extraLength;
      final nameBytes = Uint8List.sublistView(cdData, fileNameStart, fileNameEnd);
      final extraBytes = Uint8List.sublistView(cdData, extraStart, extraEnd);
      final fileName = _decodeZipFileName(nameBytes, flags);
      final normalizedName = fileName.replaceAll('\\', '/');
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
      final isValid =
          !isDirectory &&
          !encrypted &&
          supportedMethod &&
          compressedSize > 0 &&
          localHeaderOffset >= 0 &&
          localHeaderOffset + 30 < totalSize;

      if (isValid) {
        records.add(
          _ZipEntryRecord(
            fileName: normalizedName,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
          ),
        );
      }

      offset = nextOffset;
    }

    return records;
  }

  /// 读取 ZIP 条目内容为字符串（用于 XML 文件）
  Future<String?> _readZipEntryAsString({
    required WebDavComicManager manager,
    required String remotePath,
    required _ZipEntryRecord record,
  }) async {
    try {
      final bytes = await _readZipEntryBytes(
        manager: manager,
        remotePath: remotePath,
        record: record,
      );
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      Log.warning('WebDavEpubService', 'Failed to read zip entry ${record.fileName}: $e');
      return null;
    }
  }

  /// 读取 ZIP 条目的原始字节
  Future<Uint8List> _readZipEntryBytes({
    required WebDavComicManager manager,
    required String remotePath,
    required _ZipEntryRecord record,
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
    if (_readUint32LE(localHeaderData, 0) != _zipLocalFileHeaderSignature) {
      throw Exception('Invalid local header signature');
    }

    final fileNameLength = _readUint16LE(localHeaderData, 26);
    final extraLength = _readUint16LE(localHeaderData, 28);
    final dataStart = localHeaderStart + 30 + fileNameLength + extraLength;
    final dataEnd = dataStart + record.compressedSize - 1;
    if (dataEnd < dataStart) {
      throw Exception('Invalid data range');
    }

    final compressedResult = await manager.readFileRange(
      remotePath,
      start: dataStart,
      end: dataEnd,
    );
    final compressedBytes = compressedResult.bytes;
    if (compressedBytes.isEmpty) {
      throw Exception('Entry data is empty');
    }

    if (record.method == 0) return compressedBytes;
    if (record.method == 8) {
      final decoded = ZLibDecoder(raw: true).convert(compressedBytes);
      return Uint8List.fromList(decoded);
    }
    throw Exception('Unsupported zip compression method: ${record.method}');
  }

  Future<Uint8List> _readZipEntryBytesWithRetry({
    required WebDavComicManager manager,
    required String remotePath,
    required _EpubZipImageRecord record,
    required int maxAttempts,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _readZipEntryBytes(
          manager: manager,
          remotePath: remotePath,
          record: record,
        );
      } catch (e, s) {
        lastError = e;
        lastStack = s;
        if (attempt >= maxAttempts) break;
        await Future.delayed(Duration(milliseconds: 120 * attempt));
      }
    }
    if (lastError != null && lastStack != null) {
      Error.throwWithStackTrace(lastError, lastStack);
    }
    throw Exception('EPUB stream read failed');
  }

  // ─────────────────── 工具方法 ───────────────────

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

  Future<Map<String, dynamic>?> _loadMetadata(File metadataFile) async {
    if (!await metadataFile.exists()) return null;
    try {
      final content = await metadataFile.readAsString();
      final json = jsonDecode(content);
      if (json is Map<String, dynamic>) return json;
      return null;
    } catch (_) {
      return null;
    }
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

  WebDavEpubBook _bookFromStreamMetadata(
    Map<String, dynamic> metadata,
    String fallbackFileName,
  ) {
    final fallbackTitle = _stripFileExtension(fallbackFileName);
    return WebDavEpubBook(
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

  Future<File?> _findCachedStreamImage(
    Directory metaDir,
    int imageIndex,
  ) async {
    if (!await metaDir.exists()) return null;
    for (final ext in const [
      'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif', 'heic', 'heif',
      'tif', 'tiff',
    ]) {
      final file = metaDir.joinFile('$imageIndex.$ext');
      if (await file.exists() && await file.length() > 0) return file;
    }
    return null;
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
    return (high << 32) | low;
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

  bool _isImageExtension(String ext) {
    const imageExtensions = [
      'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe', 'avif', 'bmp',
      'tif', 'tiff', 'jfif', 'heic', 'heif',
    ];
    return imageExtensions.contains(ext);
  }

  int? _extractFirstNumber(String name) {
    final match = RegExp(r'\d+').firstMatch(name);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  String _stripFileExtension(String fileName) {
    final index = fileName.lastIndexOf('.');
    if (index > 0) return fileName.substring(0, index).trim();
    return fileName.trim();
  }

  String _normalizeRemotePath(String path) {
    if (!path.startsWith('/')) path = '/$path';
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    return path;
  }
}

// ─────────────────── 数据类 ───────────────────

class _EpubContentMeta {
  final String? title;
  final String? author;
  final String? coverHref;
  final List<String> imageHrefs;

  const _EpubContentMeta({
    this.title,
    this.author,
    this.coverHref,
    required this.imageHrefs,
  });
}

class _ManifestItem {
  final String id;
  final String href;
  final String mediaType;

  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
  });
}

class _EpubStreamMeta {
  final Directory metaDir;
  final String remotePath;
  final List<_EpubZipImageRecord> entries;

  const _EpubStreamMeta({
    required this.metaDir,
    required this.remotePath,
    required this.entries,
  });
}

class _EpubStreamPrefetchTask {
  final String metaKey;
  final int imageIndex;
  final Completer<void> done = Completer<void>();

  _EpubStreamPrefetchTask({required this.metaKey, required this.imageIndex});
}

class _EpubZipImageRecord extends _ZipEntryRecord {
  final bool isCover;

  const _EpubZipImageRecord({
    required super.fileName,
    required super.method,
    required super.compressedSize,
    required super.uncompressedSize,
    required super.localHeaderOffset,
    required this.isCover,
  });

  factory _EpubZipImageRecord.fromJson(Map<String, dynamic> json) {
    int readInt(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return _EpubZipImageRecord(
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

class _ZipEntryRecord {
  final String fileName;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  const _ZipEntryRecord({
    required this.fileName,
    required this.method,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  factory _ZipEntryRecord.empty() {
    return const _ZipEntryRecord(
      fileName: '',
      method: 0,
      compressedSize: 0,
      uncompressedSize: 0,
      localHeaderOffset: 0,
    );
  }

  bool get isEmpty => fileName.isEmpty;
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
