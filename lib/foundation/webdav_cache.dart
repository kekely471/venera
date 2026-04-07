// WebDAV 缓存路径工具
// @author: kirk

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/webdav_archive_service.dart';
import 'package:venera/foundation/webdav_epub_service.dart';
import 'package:venera/foundation/webdav_mobi_service.dart';
import 'package:venera/foundation/webdav_pdf_service.dart';
import 'package:venera/utils/io.dart';

class WebDavCachePaths {
  static const String rootCoverTag = 'webdav:cover-root';
  static const String metadataDirectoryName = '.venera';
  static const String metadataDirectoryPath = '/.venera';
  static const String readingProgressFilePath =
      '/.venera/reading_progress.json';

  static const List<String> allCacheDirectoryNames = [
    'webdav_comics',
    'webdav_mobi',
    'webdav_mobi_stream',
    'webdav_mobi_preview',
    'webdav_pdf',
    'webdav_archive',
    'webdav_archive_stream',
    'webdav_epub_stream',
  ];

  static Directory cacheDirectory(String name) {
    return Directory(FilePath.join(App.cachePath, name));
  }

  static String? decodeCachedDirectory(String directory) {
    return WebDavMobiService.decodeStreamDirectory(directory) ??
        WebDavMobiService.decodeDirectory(directory) ??
        WebDavArchiveService.decodeStreamDirectory(directory) ??
        WebDavArchiveService.decodeDirectory(directory) ??
        WebDavEpubService.decodeStreamDirectory(directory);
  }

  static File? resolveLocalCoverFile({
    required String directory,
    required String cover,
  }) {
    final cacheDir = decodeCachedDirectory(directory);
    if (cacheDir == null) return null;

    final coverFile = File(FilePath.join(cacheDir, cover));
    if (!coverFile.existsSync()) return null;
    return coverFile;
  }

  static String buildRemoteCoverPath({
    required String directory,
    required String cover,
    required bool hasChapters,
    required String? firstChapterId,
    required Iterable<String> tags,
  }) {
    final normalizedCover = cover.replaceAll('\\', '/');
    if (normalizedCover.contains('/')) {
      return _joinRemotePath(directory, normalizedCover);
    }
    if (!hasChapters ||
        firstChapterId == null ||
        tags.contains(rootCoverTag)) {
      return _joinRemotePath(directory, normalizedCover);
    }
    return _joinRemotePath(directory, '$firstChapterId/$normalizedCover');
  }

  static bool isInternalMetadataEntry({
    required String name,
    required bool isDirectory,
  }) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (isDirectory) {
      return normalized == metadataDirectoryName;
    }
    return normalized == 'reading_progress.json';
  }

  static Directory remoteImageCacheDir(String remotePath) {
    return Directory(remoteImageCacheFile(remotePath).path);
  }

  static File remoteImageCacheFile(String remotePath) {
    var normalized = remotePath;
    while (normalized.startsWith('/') || normalized.startsWith('\\')) {
      normalized = normalized.substring(1);
    }
    return File(FilePath.join(App.cachePath, 'webdav_comics', normalized));
  }

  static List<FileSystemEntity> cacheEntitiesForDirectory(String directory) {
    final entities = <FileSystemEntity>[];
    final seenPaths = <String>{};

    void addEntity(FileSystemEntity entity) {
      if (seenPaths.add(entity.path)) {
        entities.add(entity);
      }
    }

    final cacheDir = decodeCachedDirectory(directory);
    if (cacheDir != null) {
      addEntity(Directory(cacheDir));

      final previewFile = _resolveMobiPreviewFile(
        encodedDirectory: directory,
        cacheDirectoryPath: cacheDir,
      );
      if (previewFile != null) {
        addEntity(previewFile);
      }
      return entities;
    }

    final pdfRemotePath = WebDavPdfService.decodeDirectory(directory);
    if (pdfRemotePath != null) {
      addEntity(WebDavPdfService.cacheDirectoryForRemotePath(pdfRemotePath));
      return entities;
    }

    if (_looksLikeRemotePath(directory)) {
      addEntity(remoteImageCacheDir(directory));
    }

    return entities;
  }

  static bool _looksLikeRemotePath(String path) {
    return path.startsWith('/') || path.startsWith('\\');
  }

  static File? _resolveMobiPreviewFile({
    required String encodedDirectory,
    required String cacheDirectoryPath,
  }) {
    if (!WebDavMobiService.isMobiDirectory(encodedDirectory) &&
        !WebDavMobiService.isStreamDirectory(encodedDirectory)) {
      return null;
    }

    final metadataFile = File(FilePath.join(cacheDirectoryPath, 'meta.json'));
    if (!metadataFile.existsSync()) {
      return null;
    }

    try {
      final metadata = jsonDecode(metadataFile.readAsStringSync());
      if (metadata is! Map) {
        return null;
      }
      final remotePath = metadata['remotePath'];
      if (remotePath is! String || remotePath.trim().isEmpty) {
        return null;
      }
      return mobiPreviewFile(remotePath);
    } catch (_) {
      return null;
    }
  }

  static File mobiPreviewFile(String remotePath) {
    final key = md5.convert(utf8.encode(remotePath)).toString();
    return File(FilePath.join(App.cachePath, 'webdav_mobi_preview', '$key.bin'));
  }

  static String _joinRemotePath(String base, String name) {
    if (base.endsWith('/')) {
      return '$base$name';
    }
    return '$base/$name';
  }
}
