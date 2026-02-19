// WebDAV MOBI 解析与缓存服务
// @author: kirk

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dart_mobi/dart_mobi.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:venera/foundation/app.dart';
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
  static const int _metaSchemaVersion = 3;

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

    final hasAnyImage = cacheDir.listSync().whereType<File>().any(
      (f) => _isImageFile(f.name) && !f.name.toLowerCase().startsWith('cover.'),
    );
    return hasAnyImage;
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
