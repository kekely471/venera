// WebDAV 压缩漫画解析与缓存服务
// @author: kirk

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
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
  static const int _metaSchemaVersion = 1;

  static bool isArchiveDirectory(String directory) {
    return directory.startsWith(archiveDirectoryPrefix);
  }

  static String encodeDirectory(String localPath) {
    return '$archiveDirectoryPrefix${Uri.encodeComponent(localPath)}';
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
    if (pages is! int || pages <= 0) return false;

    final hasAnyImage = cacheDir.listSync().whereType<File>().any(
      (f) => _isImageFile(f.name),
    );
    return hasAnyImage;
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
