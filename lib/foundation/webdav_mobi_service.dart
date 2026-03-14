// WebDAV MOBI 解析与缓存服务
// @author: kirk

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dart_mobi/dart_mobi.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/io.dart';

class WebDavMobiBook {
  final String id;
  final String title;
  final String subtitle;
  final List<String> tags;
  final String directory;
  final String cover;
  final DateTime createdAt;

  const WebDavMobiBook({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.cover,
    required this.createdAt,
  });
}

class WebDavMobiService {
  WebDavMobiService._();

  static WebDavMobiService? _instance;

  factory WebDavMobiService() {
    return _instance ??= WebDavMobiService._();
  }

  static const String mobiDirectoryPrefix = 'webdav-mobi://';
  static const String streamDirectoryPrefix = 'webdav-mobi-stream://';
  static const int _metaSchemaVersion = 3;
  static const int _streamMetaSchemaVersion = 1;

  static bool isMobiDirectory(String directory) {
    return directory.startsWith(mobiDirectoryPrefix);
  }

  static String encodeDirectory(String localPath) {
    return '$mobiDirectoryPrefix${Uri.encodeComponent(localPath)}';
  }

  static String? decodeDirectory(String encodedPath) {
    if (!isMobiDirectory(encodedPath)) return null;
    try {
      return Uri.decodeComponent(
        encodedPath.substring(mobiDirectoryPrefix.length),
      );
    } catch (_) {
      return null;
    }
  }

  static bool isStreamDirectory(String directory) {
    return directory.startsWith(streamDirectoryPrefix);
  }

  static String encodeStreamDirectory(String metaDirPath) {
    return '$streamDirectoryPrefix${Uri.encodeComponent(metaDirPath)}';
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

  Future<WebDavMobiBook> prepareFromWebDav({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();
    final cacheDir = Directory(
      FilePath.join(App.cachePath, 'webdav_mobi', key),
    );
    final metadataFile = cacheDir.joinFile('meta.json');
    final metadata = await _loadMetadata(metadataFile);

    if (_isCacheUsable(metadata, remoteSize, remoteModifiedTime, cacheDir)) {
      try {
        return _bookFromMetadata(metadata!);
      } catch (_) {
        // ignore broken metadata and rebuild cache
      }
    }

    final bytes = await WebDavComicManager().readFile(remotePath);
    final parseResult = await _parseMobi(bytes, fileName);

    await cacheDir.deleteIgnoreError(recursive: true);
    await cacheDir.create(recursive: true);

    final imageNameWidth = parseResult.images.length.toString().length.clamp(
      3,
      6,
    );
    final pageFiles = <String>[];
    String? coverName;
    for (int i = 0; i < parseResult.images.length; i++) {
      final image = parseResult.images[i];
      final fileName =
          '${(i + 1).toString().padLeft(imageNameWidth, '0')}.${image.extension}';
      final outFile = cacheDir.joinFile(fileName);
      await outFile.writeAsBytes(image.bytes, flush: false);
      pageFiles.add(fileName);

      if (parseResult.coverUid != null && parseResult.coverUid == image.uid) {
        coverName = fileName;
      }
    }
    coverName ??= pageFiles.first;

    final createdAt = DateTime.now();
    final metadataToSave = <String, dynamic>{
      'schema': _metaSchemaVersion,
      'id': 'webdav_mobi_$key',
      'title': parseResult.title,
      'subtitle': parseResult.author,
      'tags': parseResult.tags,
      'directory': encodeDirectory(cacheDir.path),
      'cover': coverName,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'remotePath': remotePath,
      'remoteSize': remoteSize,
      'remoteModifiedTime': remoteModifiedTime?.millisecondsSinceEpoch,
    };
    await metadataFile.writeAsString(jsonEncode(metadataToSave));

    return _bookFromMetadata(metadataToSave);
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

    // 封面文件存在即可视为缓存可用，无需遍历目录
    final cover = metadata['cover'] as String?;
    if (cover == null || cover.isEmpty) return false;
    return cacheDir.joinFile(cover).existsSync();
  }

  WebDavMobiBook _bookFromMetadata(Map<String, dynamic> metadata) {
    return WebDavMobiBook(
      id: metadata['id'] as String,
      title: metadata['title'] as String,
      subtitle: metadata['subtitle'] as String? ?? '',
      tags: List<String>.from(metadata['tags'] ?? const <String>[]),
      directory: metadata['directory'] as String,
      cover: metadata['cover'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        metadata['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<_MobiParseResult> _parseMobi(Uint8List bytes, String fileName) async {
    final mobiData = await DartMobiReader.read(bytes);
    final rawml = mobiData.parseOpt(false, false, false);

    final images = <_MobiImagePart>[];
    MobiPart? curr = rawml.resources;
    while (curr != null) {
      if (_isImageType(curr.fileType) && curr.data != null && curr.size > 0) {
        images.add(
          _MobiImagePart(
            uid: curr.uid,
            bytes: Uint8List.fromList(curr.data!),
            extension: _extensionForType(curr.fileType),
          ),
        );
      }
      curr = curr.next;
    }

    if (images.isEmpty) {
      throw Exception('No readable images found in mobi');
    }

    final title = _pickTitle(mobiData, fileName);
    final author = _pickAuthor(mobiData);
    final coverUid = _pickCoverUid(mobiData);

    return _MobiParseResult(
      title: title,
      author: author,
      tags: const <String>['webdav:mobi'],
      coverUid: coverUid,
      images: images,
    );
  }

  String _pickTitle(MobiData data, String fileName) {
    final headerTitle = (data.mobiHeader?.fullname ?? '').trim();
    final exthTitle = _readExthText(data, MobiExthTag.title);
    final fileTitle = _stripFileExtension(fileName);
    final candidates = <String>{};
    if (headerTitle.isNotEmpty) {
      candidates.add(headerTitle);
    }
    if (exthTitle.isNotEmpty) {
      candidates.add(exthTitle);
    }
    if (fileTitle.isNotEmpty) {
      candidates.add(fileTitle);
    }

    if (candidates.isEmpty) return fileName;
    return candidates.reduce((best, current) {
      final bestScore = _decodeScore(best);
      final currentScore = _decodeScore(current);
      return currentScore > bestScore ? current : best;
    });
  }

  String _pickAuthor(MobiData data) {
    return _readExthText(data, MobiExthTag.author);
  }

  int? _pickCoverUid(MobiData data) {
    final exth = DartMobiReader.getExthRecordByTag(
      data,
      MobiExthTag.coverOffset,
    );
    if (exth == null || exth.data == null || exth.size == null) {
      return null;
    }
    return DartMobiReader.decodeExthValue(exth.data!, exth.size!);
  }

  String _readExthText(MobiData data, MobiExthTag tag) {
    final exth = DartMobiReader.getExthRecordByTag(data, tag);
    if (exth == null || exth.data == null || exth.data!.isEmpty) {
      return '';
    }
    return _decodeText(exth.data!);
  }

  String _decodeText(Uint8List value) {
    final candidates = <String>{};

    final utf8Text = _tryDecodeUtf8(value);
    if (utf8Text != null && utf8Text.isNotEmpty) {
      candidates.add(utf8Text);
    }

    final gbkText = _tryDecodeGbk(value);
    if (gbkText != null && gbkText.isNotEmpty) {
      candidates.add(gbkText);
    }

    final latin1Text = latin1.decode(value, allowInvalid: true).trim();
    if (latin1Text.isNotEmpty) {
      candidates.add(latin1Text);
    }

    if (candidates.isEmpty) return '';

    return candidates.reduce((best, current) {
      final bestScore = _decodeScore(best);
      final currentScore = _decodeScore(current);
      return currentScore > bestScore ? current : best;
    });
  }

  String? _tryDecodeUtf8(Uint8List value) {
    try {
      return utf8.decode(value, allowMalformed: false).trim();
    } catch (_) {
      return null;
    }
  }

  String? _tryDecodeGbk(Uint8List value) {
    try {
      return const GbkCodec().decode(value).trim();
    } catch (_) {
      return null;
    }
  }

  int _decodeScore(String text) {
    var score = 0;
    for (final rune in text.runes) {
      if (rune == 0xFFFD) {
        score -= 24;
        continue;
      }
      if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
        score -= 10;
        continue;
      }
      if (_isCjkRune(rune)) {
        score += 6;
        continue;
      }
      if (rune >= 0x20 && rune <= 0x7E) {
        score += 2;
        continue;
      }
      if (rune >= 0x00A0 && rune <= 0x024F) {
        score += 1;
        continue;
      }
      score += 1;
    }

    score -= _suspiciousMojibakePattern.allMatches(text).length * 4;
    return score;
  }

  bool _isCjkRune(int rune) {
    return (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF);
  }

  String _stripFileExtension(String fileName) {
    final index = fileName.lastIndexOf('.');
    if (index > 0) {
      return fileName.substring(0, index).trim();
    }
    return fileName.trim();
  }

  static final RegExp _suspiciousMojibakePattern = RegExp(
    r'[ÃÂÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ]',
  );

  /// 通过 Range 请求仅下载 MOBI 头部，解析并缓存流式元数据。
  /// 成功返回 WebDavMobiBook（directory 使用 stream 前缀），失败返回 null。
  Future<WebDavMobiBook?> prepareStreamingMeta({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();
    final metaDir = Directory(
      FilePath.join(App.cachePath, 'webdav_mobi_stream', key),
    );
    final metadataFile = metaDir.joinFile('meta.json');

    // 1. 检查缓存
    final existingMeta = await _loadMetadata(metadataFile);
    if (_isStreamCacheUsable(
      existingMeta,
      remoteSize,
      remoteModifiedTime,
      metaDir,
    )) {
      try {
        return _bookFromStreamMeta(existingMeta!);
      } catch (_) {
        // 缓存损坏，重新生成
      }
    }

    try {
      final manager = WebDavComicManager();
      const tag = 'WebDavMobiService.stream';

      // 2. Range 读取头部
      const initialSize = 8 * 1024;
      final r1 = await manager.readFileRange(
        remotePath,
        start: 0,
        end: initialSize - 1,
      );
      Log.info(tag, 'r1: ${r1.bytes.length} bytes, isPartial=${r1.isPartial}, totalSize=${r1.totalSize}');
      if (r1.bytes.length < 86) {
        Log.warning(tag, 'Header too small: ${r1.bytes.length} < 86');
        return null;
      }
      if (!r1.isPartial) {
        Log.warning(tag, 'Server does not support Range (returned full file)');
        return null;
      }

      final totalSize = r1.totalSize;
      var headerData = r1.bytes;

      // 3. 解析 PDB Header
      var pdb = _parsePdbHeader(headerData);
      if (pdb == null || pdb.recordCount < 2) {
        Log.warning(tag, 'PDB parse failed or recordCount < 2: ${pdb?.recordCount}');
        return null;
      }
      Log.info(tag, 'PDB: recordCount=${pdb.recordCount}, parsedOffsets=${pdb.recordOffsets.length}, tableEnd=${pdb.tableEnd}');

      // Record Info Table 可能未完整下载
      if (pdb.recordOffsets.length < pdb.recordCount) {
        final needed = pdb.tableEnd + 4096;
        Log.info(tag, 'Extending header read to $needed bytes for full record table');
        final r1ext = await manager.readFileRange(
          remotePath,
          start: 0,
          end: needed,
        );
        headerData = r1ext.bytes;
        pdb = _parsePdbHeader(headerData);
        if (pdb == null) {
          Log.warning(tag, 'PDB re-parse failed after extension');
          return null;
        }
        Log.info(tag, 'PDB after extension: parsedOffsets=${pdb.recordOffsets.length}');
      }

      // 4. 解析 MOBI Header
      final record0Offset = pdb.recordOffsets[0];
      final mobiMagicOffset = record0Offset + 16;
      if (mobiMagicOffset + 132 > headerData.length) {
        final needed = mobiMagicOffset + 4096;
        final r1ext = await manager.readFileRange(
          remotePath,
          start: 0,
          end: needed,
        );
        headerData = r1ext.bytes;
      }

      final mobi = _parseMobiHeader(headerData, record0Offset);
      if (mobi == null) {
        Log.warning(tag, 'MOBI header parse failed at record0Offset=$record0Offset');
        return null;
      }
      Log.info(tag, 'MOBI: imageIndex=${mobi.imageIndex}, hasExth=${mobi.hasExth}, headerSize=${mobi.headerSize}');

      // 5. 解析 EXTH（title, author, coverOffset）
      var title = _stripFileExtension(fileName);
      var author = '';
      int? coverOffset;

      if (mobi.hasExth) {
        final exthStart = record0Offset + 16 + mobi.headerSize;

        if (exthStart + 12 > headerData.length) {
          final r2 = await manager.readFileRange(
            remotePath,
            start: 0,
            end: exthStart + 4096,
          );
          headerData = r2.bytes;
        }

        if (exthStart + 12 <= headerData.length) {
          final magic = _readAscii(headerData, exthStart, 4);
          if (magic == 'EXTH') {
            final exthLength = _readUint32BE(headerData, exthStart + 4);
            if (exthStart + exthLength > headerData.length) {
              final r2 = await manager.readFileRange(
                remotePath,
                start: 0,
                end: exthStart + exthLength,
              );
              headerData = r2.bytes;
            }
            // tag 100=author, 201=coverOffset, 503=updatedTitle
            final exthRecords = _parseExthRecords(
              headerData,
              exthStart,
              const {100, 201, 503},
            );
            if (exthRecords.containsKey(503)) {
              final decoded = _decodeText(exthRecords[503]!);
              if (decoded.isNotEmpty) title = decoded;
            }
            if (exthRecords.containsKey(100)) {
              author = _decodeText(exthRecords[100]!);
            }
            if (exthRecords.containsKey(201) &&
                exthRecords[201]!.length >= 4) {
              coverOffset = _readUint32BE(exthRecords[201]!, 0);
            }
          }
        }
      }

      // 6. 确定图片 record 范围
      var imageStartRecord = mobi.imageIndex;
      // 记录原始 imageIndex，用于后续封面索引计算
      final originalImageIndex = mobi.imageIndex;
      if (imageStartRecord <= 0 ||
          imageStartRecord >= pdb.recordCount ||
          imageStartRecord >= pdb.recordOffsets.length) {
        // KF8/AZW3 格式的 imageIndex 常为 0，需要通过探测定位
        Log.info(tag, 'imageIndex=$imageStartRecord invalid, probing for image records...');

        // 利用 coverOffset 作为已知图片 record 参考点
        // coverOffset 是相对于 imageIndex 的偏移量，无法直接作为绝对 record 号
        int? knownImageRecord;
        if (coverOffset != null &&
            originalImageIndex > 0 &&
            originalImageIndex + coverOffset < pdb.recordCount &&
            originalImageIndex + coverOffset < pdb.recordOffsets.length) {
          knownImageRecord = originalImageIndex + coverOffset;
        }

        imageStartRecord = await _probeImageStartRecord(
          manager,
          remotePath,
          pdb,
          knownImageRecord,
          totalSize,
        );
        if (imageStartRecord < 0) {
          Log.warning(tag, 'Cannot find any image record by probing');
          return null;
        }
        Log.info(tag, 'Probed imageStartRecord=$imageStartRecord');
      }

      // 从尾部反向探测，排除非图片 record（FLIS/FCIS 等）
      var imageEndRecord = pdb.recordCount - 1;
      var tailProbeFound = false;
      for (var i = imageEndRecord;
          i >= imageStartRecord;
          i--) {
        if (i >= pdb.recordOffsets.length) continue;
        final recordStart = pdb.recordOffsets[i];
        final int recordEnd;
        if (i + 1 < pdb.recordOffsets.length) {
          recordEnd = pdb.recordOffsets[i + 1] - 1;
        } else if (totalSize != null) {
          recordEnd = totalSize - 1;
        } else {
          continue;
        }
        if (recordEnd - recordStart + 1 < 8) {
          continue;
        }
        // 下载前 8 字节检查 magic
        final probe = await manager.readFileRange(
          remotePath,
          start: recordStart,
          end: recordStart + 7,
        );
        if (_detectImageMagic(probe.bytes) != null) {
          imageEndRecord = i;
          tailProbeFound = true;
          Log.info(tag, 'Tail probe found last image at record $i');
          break;
        }
      }

      if (!tailProbeFound) {
        Log.warning(tag, 'Tail probe found no image records (start=$imageStartRecord, count=${pdb.recordCount})');
        return null;
      }

      // 构建 imageRecords 列表
      final imageRecords = <Map<String, int>>[];
      for (var i = imageStartRecord; i <= imageEndRecord; i++) {
        if (i >= pdb.recordOffsets.length) break;
        final recordStart = pdb.recordOffsets[i];
        final int recordEnd;
        if (i + 1 < pdb.recordOffsets.length) {
          recordEnd = pdb.recordOffsets[i + 1] - 1;
        } else if (totalSize != null) {
          recordEnd = totalSize - 1;
        } else {
          break;
        }
        if (recordEnd <= recordStart) continue;
        if (recordEnd - recordStart + 1 > 10 * 1024 * 1024) continue;
        imageRecords.add({'start': recordStart, 'end': recordEnd});
      }

      if (imageRecords.isEmpty) {
        Log.warning(tag, 'No valid imageRecords built (imageStart=$imageStartRecord, imageEnd=$imageEndRecord)');
        return null;
      }

      Log.info(tag, 'Built ${imageRecords.length} imageRecords');

      // 7. 确定封面索引
      // coverOffset 是相对于原始 imageIndex 的偏移量
      // 需要转换为相对于 imageRecords 列表的索引
      int coverIndex = 0;
      if (coverOffset != null) {
        final absoluteCoverRecord = originalImageIndex > 0
            ? originalImageIndex + coverOffset
            : imageStartRecord + coverOffset;
        final relativeIndex = absoluteCoverRecord - imageStartRecord;
        if (relativeIndex >= 0 && relativeIndex < imageRecords.length) {
          coverIndex = relativeIndex;
        }
      }

      // 8. 下载并缓存封面图
      await metaDir.deleteIgnoreError(recursive: true);
      await metaDir.create(recursive: true);

      var coverFile = 'cover.jpg';
      final coverRecord = imageRecords[coverIndex];
      final coverResult = await manager.readFileRange(
        remotePath,
        start: coverRecord['start']!,
        end: coverRecord['end']!,
      );
      if (coverResult.bytes.isNotEmpty) {
        final ext = _detectImageMagic(coverResult.bytes) ?? 'jpg';
        coverFile = 'cover.$ext';
        await metaDir.joinFile(coverFile).writeAsBytes(
          coverResult.bytes,
          flush: false,
        );
      }

      // 9. 保存 meta.json
      final createdAt = DateTime.now();
      final metaMap = <String, dynamic>{
        'schema': _streamMetaSchemaVersion,
        'id': 'webdav_mobi_stream_$key',
        'remotePath': remotePath,
        'totalSize': totalSize,
        'title': title,
        'author': author,
        'tags': const ['webdav:mobi'],
        'coverIndex': coverIndex,
        'coverFile': coverFile,
        'imageCount': imageRecords.length,
        'imageRecords': imageRecords,
        'directory': encodeStreamDirectory(metaDir.path),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'remoteSize': remoteSize,
        'remoteModifiedTime': remoteModifiedTime?.millisecondsSinceEpoch,
      };
      await metadataFile.writeAsString(jsonEncode(metaMap));

      Log.info(tag, 'Stream meta saved: ${imageRecords.length} images, cover=$coverFile');
      return _bookFromStreamMeta(metaMap);
    } catch (e, s) {
      Log.warning(
        'WebDavMobiService',
        'prepareStreamingMeta failed for $remotePath: $e\n$s',
      );
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
    return imageCount is int && imageCount > 0;
  }

  WebDavMobiBook _bookFromStreamMeta(Map<String, dynamic> metadata) {
    return WebDavMobiBook(
      id: metadata['id'] as String,
      title: metadata['title'] as String,
      subtitle: metadata['author'] as String? ?? '',
      tags: List<String>.from(metadata['tags'] ?? const <String>[]),
      directory: metadata['directory'] as String,
      cover: metadata['coverFile'] as String? ?? 'cover.jpg',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        metadata['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 仅通过 Range 请求获取 MOBI 文件封面图，避免全量下载。
  /// 返回封面图片的本地文件路径，失败返回 null。
  Future<String?> fetchCoverOnly({
    required String remotePath,
    int? remoteSize,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();

    final previewFile = File(
      FilePath.join(App.cachePath, 'webdav_mobi_preview', '$key.bin'),
    );
    if (await previewFile.exists() && await previewFile.length() > 0) {
      return previewFile.path;
    }

    try {
      final manager = WebDavComicManager();

      // Request 1: 读取前 8KB（覆盖 PDB Header + Record Info Table + MOBI/EXTH）
      const initialSize = 8 * 1024;
      final r1 = await manager.readFileRange(
        remotePath,
        start: 0,
        end: initialSize - 1,
      );
      if (r1.bytes.length < 86) return null; // 至少 PDB Header + 1 条 Record

      // 服务器不支持 Range，返回 null 由调用方 fallback
      if (!r1.isPartial) return null;

      final totalSize = r1.totalSize;

      // 解析 PDB Header
      final pdb = _parsePdbHeader(r1.bytes);
      if (pdb == null || pdb.recordCount < 2) return null;

      // 解析 MOBI Header
      final record0Offset = pdb.recordOffsets[0];
      var headerData = r1.bytes;

      final mobiMagicOffset = record0Offset + 16;
      if (mobiMagicOffset + 132 > headerData.length) {
        // 数据不足，扩展读取
        final needed = mobiMagicOffset + 4096;
        final r1ext = await manager.readFileRange(
          remotePath,
          start: 0,
          end: needed,
        );
        headerData = r1ext.bytes;
      }

      final mobi = _parseMobiHeader(headerData, record0Offset);
      if (mobi == null) return null;

      // 解析 EXTH 获取 coverOffset
      int? coverOffset;
      if (mobi.hasExth) {
        final exthStart = record0Offset + 16 + mobi.headerSize;

        if (exthStart + 12 > headerData.length) {
          final r2 = await manager.readFileRange(
            remotePath,
            start: 0,
            end: exthStart + 4096,
          );
          headerData = r2.bytes;
        }

        if (exthStart + 12 <= headerData.length) {
          final magic = _readAscii(headerData, exthStart, 4);
          if (magic == 'EXTH') {
            final exthLength = _readUint32BE(headerData, exthStart + 4);
            if (exthStart + exthLength > headerData.length) {
              final r2 = await manager.readFileRange(
                remotePath,
                start: 0,
                end: exthStart + exthLength,
              );
              headerData = r2.bytes;
            }
            coverOffset = _parseExthCoverOffset(headerData, exthStart);
          }
        }
      }

      // 计算封面 Record 编号
      final coverRecordIndex = mobi.imageIndex + (coverOffset ?? 0);
      if (coverRecordIndex < 0 || coverRecordIndex >= pdb.recordCount) {
        return null;
      }
      if (coverRecordIndex >= pdb.recordOffsets.length) return null;

      // 计算封面 Record 的字节区间
      final coverStart = pdb.recordOffsets[coverRecordIndex];
      final int coverEnd;
      if (coverRecordIndex + 1 < pdb.recordOffsets.length) {
        coverEnd = pdb.recordOffsets[coverRecordIndex + 1] - 1;
      } else if (totalSize != null) {
        coverEnd = totalSize - 1;
      } else {
        return null;
      }

      if (coverEnd <= coverStart) return null;
      // 安全限制：单张封面不应超过 2MB
      if (coverEnd - coverStart + 1 > 2 * 1024 * 1024) return null;

      // Request 3: 获取封面图数据
      final r3 = await manager.readFileRange(
        remotePath,
        start: coverStart,
        end: coverEnd,
      );
      if (r3.bytes.isEmpty) return null;

      // 验证是否为合法图片
      if (_detectImageMagic(r3.bytes) == null) return null;

      // 保存到预览缓存
      await previewFile.parent.create(recursive: true);
      await previewFile.writeAsBytes(r3.bytes, flush: false);

      return previewFile.path;
    } catch (e, s) {
      Log.warning(
        'WebDavMobiService',
        'fetchCoverOnly failed for $remotePath: $e\n$s',
      );
      return null;
    }
  }

  // --------------- PDB/MOBI 二进制解析工具 ---------------

  int _readUint32BE(Uint8List data, int offset) {
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  int _readUint16BE(Uint8List data, int offset) {
    return (data[offset] << 8) | data[offset + 1];
  }

  String _readAscii(Uint8List data, int offset, int length) {
    if (offset + length > data.length) return '';
    return String.fromCharCodes(data.sublist(offset, offset + length));
  }

  _PdbHeaderInfo? _parsePdbHeader(Uint8List data) {
    if (data.length < 78 + 8) return null;
    final recordCount = _readUint16BE(data, 76);
    if (recordCount <= 0) return null;

    final tableEnd = 78 + recordCount * 8;
    final offsets = <int>[];
    for (int i = 0; i < recordCount; i++) {
      final entryOffset = 78 + i * 8;
      if (entryOffset + 4 > data.length) break;
      offsets.add(_readUint32BE(data, entryOffset));
    }
    if (offsets.isEmpty) return null;

    return _PdbHeaderInfo(
      recordCount: recordCount,
      recordOffsets: offsets,
      tableEnd: tableEnd,
    );
  }

  _MobiHeaderInfo? _parseMobiHeader(Uint8List data, int record0Offset) {
    final mobiStart = record0Offset + 16;
    if (mobiStart + 132 > data.length) return null;

    final magic = _readAscii(data, mobiStart, 4);
    if (magic != 'MOBI') return null;

    final headerSize = _readUint32BE(data, mobiStart + 4);
    // imageIndex 位于 MOBI header 偏移 108（相对 MOBI 起始）
    // 即 mobiStart + 108
    final imageIndex = _readUint32BE(data, mobiStart + 108);
    // exthFlags 位于 MOBI header 偏移 112
    final exthFlags = _readUint32BE(data, mobiStart + 112);
    final hasExth = (exthFlags & 0x40) != 0;

    return _MobiHeaderInfo(
      headerSize: headerSize,
      imageIndex: imageIndex,
      hasExth: hasExth,
    );
  }

  int? _parseExthCoverOffset(Uint8List data, int exthStart) {
    if (exthStart + 12 > data.length) return null;
    final magic = _readAscii(data, exthStart, 4);
    if (magic != 'EXTH') return null;

    final recordCount = _readUint32BE(data, exthStart + 8);
    var pos = exthStart + 12;

    for (int i = 0; i < recordCount; i++) {
      if (pos + 8 > data.length) break;
      final tag = _readUint32BE(data, pos);
      final size = _readUint32BE(data, pos + 4);
      if (size < 8) break;

      // tag 201 = coverOffset
      if (tag == 201 && size >= 12 && pos + 12 <= data.length) {
        return _readUint32BE(data, pos + 8);
      }
      pos += size;
    }
    return null;
  }

  /// 通用 EXTH 解析：一次遍历提取多个 tag 的原始数据
  Map<int, Uint8List> _parseExthRecords(
    Uint8List data,
    int exthStart,
    Set<int> targetTags,
  ) {
    final results = <int, Uint8List>{};
    if (exthStart + 12 > data.length) return results;
    final magic = _readAscii(data, exthStart, 4);
    if (magic != 'EXTH') return results;

    final recordCount = _readUint32BE(data, exthStart + 8);
    var pos = exthStart + 12;

    for (int i = 0; i < recordCount; i++) {
      if (pos + 8 > data.length) break;
      final tag = _readUint32BE(data, pos);
      final size = _readUint32BE(data, pos + 4);
      if (size < 8) break;

      if (targetTags.contains(tag) && pos + size <= data.length) {
        results[tag] = Uint8List.sublistView(data, pos + 8, pos + size);
      }
      pos += size;
    }
    return results;
  }

  /// 当 imageIndex 无效时，通过二分探测定位第一个图片 record。
  /// 返回 record 索引，失败返回 -1。
  Future<int> _probeImageStartRecord(
    WebDavComicManager manager,
    String remotePath,
    _PdbHeaderInfo pdb,
    int? knownImageRecord,
    int? totalSize,
  ) async {
    final maxRecord = pdb.recordOffsets.length - 1;

    // 1. 如果没有已知图片 record，从后往前找一个
    if (knownImageRecord == null || knownImageRecord > maxRecord) {
      for (var i = maxRecord; i >= 1; i--) {
        final start = pdb.recordOffsets[i];
        final probe = await manager.readFileRange(
          remotePath,
          start: start,
          end: start + 7,
        );
        if (_detectImageMagic(probe.bytes) != null) {
          knownImageRecord = i;
          break;
        }
        // 最多向后探测 10 个 record
        if (maxRecord - i >= 10) break;
      }
    }
    if (knownImageRecord == null) return -1;

    // 2. 从 knownImageRecord 向前二分搜索第一个图片 record
    var lo = 1;
    var hi = knownImageRecord;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (mid >= pdb.recordOffsets.length) {
        lo = mid + 1;
        continue;
      }
      final start = pdb.recordOffsets[mid];
      final probe = await manager.readFileRange(
        remotePath,
        start: start,
        end: start + 7,
      );
      if (_detectImageMagic(probe.bytes) != null) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }

    // 3. 验证 lo 确实是图片
    if (lo >= pdb.recordOffsets.length) return -1;
    final start = pdb.recordOffsets[lo];
    final probe = await manager.readFileRange(
      remotePath,
      start: start,
      end: start + 7,
    );
    return _detectImageMagic(probe.bytes) != null ? lo : -1;
  }

  String? _detectImageMagic(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'jpg';
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
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

  String _normalizeRemotePath(String path) {
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    return path;
  }

  bool _isImageType(MobiFileType type) {
    return type == MobiFileType.jpg ||
        type == MobiFileType.png ||
        type == MobiFileType.gif ||
        type == MobiFileType.bmp;
  }

  String _extensionForType(MobiFileType type) {
    if (type == MobiFileType.png) return 'png';
    if (type == MobiFileType.gif) return 'gif';
    if (type == MobiFileType.bmp) return 'bmp';
    return 'jpg';
  }

  bool _isImageFile(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return const <String>[
      'jpg',
      'jpeg',
      'png',
      'gif',
      'bmp',
      'webp',
    ].contains(ext);
  }
}

class _MobiImagePart {
  final int uid;
  final Uint8List bytes;
  final String extension;

  const _MobiImagePart({
    required this.uid,
    required this.bytes,
    required this.extension,
  });
}

class _MobiParseResult {
  final String title;
  final String author;
  final List<String> tags;
  final int? coverUid;
  final List<_MobiImagePart> images;

  const _MobiParseResult({
    required this.title,
    required this.author,
    required this.tags,
    required this.coverUid,
    required this.images,
  });
}

class _PdbHeaderInfo {
  final int recordCount;
  final List<int> recordOffsets;
  final int tableEnd;

  const _PdbHeaderInfo({
    required this.recordCount,
    required this.recordOffsets,
    required this.tableEnd,
  });
}

class _MobiHeaderInfo {
  final int headerSize;
  final int imageIndex;
  final bool hasExth;

  const _MobiHeaderInfo({
    required this.headerSize,
    required this.imageIndex,
    required this.hasExth,
  });
}
