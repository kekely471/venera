// WebDAV PDF 解析与缓存服务
// @author: kirk

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/io.dart';

class WebDavPdfBook {
  final String id;
  final String title;
  final String filePath;
  final DateTime createdAt;

  const WebDavPdfBook({
    required this.id,
    required this.title,
    required this.filePath,
    required this.createdAt,
  });
}

class WebDavPdfService {
  WebDavPdfService._();

  static WebDavPdfService? _instance;

  factory WebDavPdfService() {
    return _instance ??= WebDavPdfService._();
  }

  static const int _metaSchemaVersion = 1;

  Future<WebDavPdfBook> prepareFromWebDav({
    required String remotePath,
    required String fileName,
    int? remoteSize,
    DateTime? remoteModifiedTime,
  }) async {
    remotePath = _normalizeRemotePath(remotePath);
    final key = md5.convert(utf8.encode(remotePath)).toString();
    final cacheDir = Directory(FilePath.join(App.cachePath, 'webdav_pdf', key));
    final metadataFile = cacheDir.joinFile('meta.json');
    final pdfFile = cacheDir.joinFile('book.pdf');
    final metadata = await _loadMetadata(metadataFile);

    if (_isCacheUsable(metadata, remoteSize, remoteModifiedTime, pdfFile)) {
      try {
        return _bookFromMetadata(metadata!, pdfFile.path, fileName);
      } catch (_) {
        // ignore broken metadata and rebuild cache
      }
    }

    final bytes = await WebDavComicManager().readFile(remotePath);
    if (bytes.isEmpty) {
      throw Exception('PDF file is empty');
    }

    await cacheDir.deleteIgnoreError(recursive: true);
    await cacheDir.create(recursive: true);
    await pdfFile.writeAsBytes(bytes, flush: false);

    final createdAt = DateTime.now();
    final metadataToSave = <String, dynamic>{
      'schema': _metaSchemaVersion,
      'id': 'webdav_pdf_$key',
      'title': _stripFileExtension(fileName),
      'createdAt': createdAt.millisecondsSinceEpoch,
      'remotePath': remotePath,
      'remoteSize': remoteSize,
      'remoteModifiedTime': remoteModifiedTime?.millisecondsSinceEpoch,
    };
    await metadataFile.writeAsString(jsonEncode(metadataToSave));

    return _bookFromMetadata(metadataToSave, pdfFile.path, fileName);
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
    File pdfFile,
  ) {
    if (metadata == null) return false;
    if (metadata['schema'] != _metaSchemaVersion) return false;
    if (!pdfFile.existsSync()) return false;

    final localSize = pdfFile.lengthSync();
    if (localSize <= 0) return false;

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

    return true;
  }

  WebDavPdfBook _bookFromMetadata(
    Map<String, dynamic> metadata,
    String filePath,
    String fallbackFileName,
  ) {
    final fallbackTitle = _stripFileExtension(fallbackFileName);
    return WebDavPdfBook(
      id: metadata['id'] as String,
      title: (metadata['title'] as String?)?.trim().isNotEmpty == true
          ? metadata['title'] as String
          : fallbackTitle,
      filePath: filePath,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        metadata['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
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
