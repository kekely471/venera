// WebDAV 漫画管理器
// @author: kirk

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_archive_service.dart';
import 'package:venera/foundation/webdav_cache.dart';
import 'package:venera/foundation/webdav_config.dart';
import 'package:venera/foundation/webdav_epub_service.dart';
import 'package:venera/foundation/webdav_mobi_service.dart';
import 'package:venera/foundation/webdav_pdf_service.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:venera/utils/io.dart';

/// WebDAV 文件信息
class WebDavFile {
  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedTime;

  const WebDavFile({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifiedTime,
  });

  factory WebDavFile.fromWebDav(webdav.File webdavFile) {
    return WebDavFile(
      name: webdavFile.name ?? '',
      path: webdavFile.path ?? '',
      isDirectory: webdavFile.isDir ?? false,
      size: webdavFile.size,
      modifiedTime: webdavFile.mTime,
    );
  }
}

class WebDavRangeReadResult {
  final Uint8List bytes;
  final int? totalSize;
  final bool isPartial;

  const WebDavRangeReadResult({
    required this.bytes,
    required this.totalSize,
    required this.isPartial,
  });
}

class _WebDavChapterDirectory {
  final String name;
  final String cover;

  const _WebDavChapterDirectory({required this.name, required this.cover});
}

/// WebDAV 漫画管理器（单例）
///
/// 负责管理 WebDAV 连接、配置和漫画扫描
class WebDavComicManager with ChangeNotifier {
  WebDavComicManager._();

  static WebDavComicManager? _instance;

  factory WebDavComicManager() =>
      _instance ?? (_instance = WebDavComicManager._());

  webdav.Client? _client;
  DateTime? _lastUsed;

  /// 获取 WebDAV 配置
  WebDavConnectionConfig? get config => WebDavSettings.readComicsConfig();

  WebDavConnectionConfig? get ownConfig => WebDavSettings.readComicsOwnConfig();

  bool get useSyncConfig => WebDavSettings.comicsUsesSyncConfig();

  /// 是否已配置 WebDAV
  bool get isConfigured => config?.isConfigured ?? false;

  /// 保存配置
  Future<void> saveConfig({
    required WebDavConnectionConfig? config,
    required bool useSyncConfig,
  }) async {
    if (useSyncConfig &&
        !(WebDavSettings.readSyncConfig()?.isConfigured ?? false)) {
      throw Exception('Sync WebDAV is not configured');
    }
    await WebDavSettings.saveComicsConfig(
      config: config,
      useSyncConfig: useSyncConfig,
    );

    // 清除旧客户端
    _client = null;
    _lastUsed = null;

    notifyListeners();
  }

  Future<void> testConnection(WebDavConnectionConfig config) async {
    final normalizedConfig = config.normalized();
    await _withRetry(() async {
      final client = WebDavClientFactory.create(normalizedConfig);
      final fullPath = WebDavPathUtils.scope(normalizedConfig, '/');
      Log.info('WebDavComicManager', 'Testing connection: $fullPath');
      await client.readDir(fullPath);
    });
  }

  /// 清除配置
  Future<void> clearConfig() async {
    await WebDavSettings.saveComicsConfig(config: null, useSyncConfig: false);

    _client = null;
    _lastUsed = null;

    notifyListeners();
  }

  /// 获取或创建 WebDAV 客户端
  webdav.Client _getClient() {
    final cfg = config;
    if (cfg == null || !cfg.isConfigured) {
      throw Exception('WebDAV not configured');
    }

    // 复用现有客户端
    if (_client != null && _lastUsed != null) {
      var elapsed = DateTime.now().difference(_lastUsed!);
      if (elapsed.inMinutes < 5) {
        _lastUsed = DateTime.now();
        return _client!;
      } else {
        _client = null;
      }
    }

    // 创建新客户端
    _client = WebDavClientFactory.create(cfg);
    _lastUsed = DateTime.now();

    return _client!;
  }

  /// 带重试的网络操作包装器
  Future<T> _withRetry<T>(
    Future<T> Function() operation, {
    int maxRetries = 3,
  }) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        return await operation();
      } catch (e) {
        if (i == maxRetries - 1 || !_shouldRetry(e)) rethrow;
        // 指数退避
        await Future.delayed(Duration(seconds: i + 1));
        Log.warning(
          'WebDavComicManager',
          'Retry attempt ${i + 1} after error: $e',
        );
      }
    }
    throw Exception('Max retries exceeded');
  }

  bool _shouldRetry(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null &&
          statusCode >= 400 &&
          statusCode < 500 &&
          statusCode != 408 &&
          statusCode != 429) {
        return false;
      }
    }

    final text = error.toString();
    if (RegExp(r'Invalid Status Code:?\s*(401|403|404)\b').hasMatch(text)) {
      return false;
    }
    return true;
  }

  /// 列举目录内容
  ///
  /// [path] 相对于 basePath 的路径（如 "/" 或 "/OnePiece"）
  Future<List<WebDavFile>> listDirectory(String path) async {
    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);

      Log.info('WebDavComicManager', 'Listing directory: $fullPath');

      var files = await client.readDir(fullPath);
      return files.map((f) => WebDavFile.fromWebDav(f)).toList();
    });
  }

  /// 读取文件内容
  ///
  /// [path] 相对于 basePath 的路径
  Future<Uint8List> readFile(String path) async {
    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);

      Log.info('WebDavComicManager', 'Reading file: $fullPath');

      var bytes = await client.read(fullPath);
      return Uint8List.fromList(bytes);
    });
  }

  /// 按字节范围读取文件内容
  ///
  /// [path] 相对于 basePath 的路径
  /// [start] 起始字节位置（包含）
  /// [end] 结束字节位置（包含），为 null 时表示读取到末尾
  Future<WebDavRangeReadResult> readFileRange(
    String path, {
    required int start,
    int? end,
  }) async {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'must be >= 0');
    }
    if (end != null && end < start) {
      throw ArgumentError.value(end, 'end', 'must be >= start');
    }

    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);
      final rangeHeader = end == null ? 'bytes=$start-' : 'bytes=$start-$end';

      Log.info('WebDavComicManager', 'Reading range: $fullPath [$rangeHeader]');

      var response = await client.c.req<List<int>>(
        client,
        'GET',
        fullPath,
        optionsHandler: (options) {
          options.responseType = ResponseType.bytes;
          options.headers ??= {};
          options.headers!['range'] = rangeHeader;
        },
      );
      var statusCode = response.statusCode ?? 0;
      if (statusCode != 206 && statusCode != 200) {
        throw Exception('Unexpected response status: $statusCode');
      }

      var rawData = response.data ?? const <int>[];
      var allBytes = Uint8List.fromList(rawData);
      var totalSize = _parseTotalSizeFromHeaders(response.headers);

      if (statusCode == 206) {
        return WebDavRangeReadResult(
          bytes: allBytes,
          totalSize: totalSize,
          isPartial: true,
        );
      }

      // 服务器忽略 Range，返回整文件时按请求区间切片。
      var from = math.min(math.max(start, 0), allBytes.length);
      var to = end == null
          ? allBytes.length
          : math.min(end + 1, allBytes.length);
      var sliced = from < to
          ? Uint8List.sublistView(allBytes, from, to)
          : Uint8List(0);
      return WebDavRangeReadResult(
        bytes: sliced,
        totalSize: totalSize ?? allBytes.length,
        isPartial: false,
      );
    });
  }

  Future<int> getFileSize(String path) async {
    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);

      var file = await client.readProps(fullPath);
      var size = file.size;
      if (size == null || size < 0) {
        throw Exception('Unable to determine file size: $fullPath');
      }
      return size;
    });
  }

  int? _parseTotalSizeFromHeaders(Headers headers) {
    var contentRange = headers.value('content-range');
    if (contentRange != null) {
      var match = RegExp(
        r'^bytes\s+\d+-\d+/(\d+|\*)$',
        caseSensitive: false,
      ).firstMatch(contentRange.trim());
      if (match != null) {
        var value = match.group(1);
        if (value != null && value != '*') {
          return int.tryParse(value);
        }
      }
    }
    var contentLength = headers.value('content-length');
    if (contentLength != null) {
      return int.tryParse(contentLength);
    }
    return null;
  }

  /// 读取文件并直接写入本地路径
  ///
  /// [path] 相对于 basePath 的路径
  Future<void> readFileToLocal(String path, String savePath) async {
    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);
      final outFile = File(savePath);
      await outFile.parent.create(recursive: true);

      Log.info('WebDavComicManager', 'Reading file to local: $fullPath');
      await client.read2File(fullPath, outFile.path);
    });
  }

  /// 将数据写入 WebDAV 文件
  ///
  /// [path] 相对于 basePath 的路径
  /// [data] 要写入的字节数据
  Future<void> writeFile(String path, Uint8List data) async {
    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);
      Log.info('WebDavComicManager', 'Writing file: $fullPath');
      await client.write(fullPath, data);
    });
  }

  Future<void> createDirectoryAll(String path) async {
    return _withRetry(() async {
      final client = _getClient();
      final fullPath = _scopePath(path);
      Log.info('WebDavComicManager', 'Ensuring directory exists: $fullPath');
      await client.mkdirAll(fullPath);
    });
  }

  /// 扫描漫画目录（递归）
  ///
  /// [path] 相对于 basePath 的路径，默认为根目录 "/"
  /// [maxDepth] 最大递归深度，防止过深扫描
  Future<List<LocalComic>> scanComics(String path, {int maxDepth = 5}) async {
    final files = await listDirectory(path);
    if (path != '/') {
      final currentComic = await parseComicDirectory(path, knownFiles: files);
      if (currentComic != null) {
        return [currentComic];
      }
    }
    return _scanComicsRecursive(path, 0, maxDepth, knownFiles: files);
  }

  Future<List<LocalComic>> _scanComicsRecursive(
    String path,
    int currentDepth,
    int maxDepth, {
    List<WebDavFile>? knownFiles,
  }) async {
    if (currentDepth >= maxDepth) {
      Log.info('WebDavComicManager', 'Max scan depth reached at $path');
      return [];
    }

    var files = (knownFiles ?? await listDirectory(path))
        .where(
          (f) => !WebDavCachePaths.isInternalMetadataEntry(
            name: f.name,
            isDirectory: f.isDirectory,
          ),
        )
        .toList();
    var comics = <LocalComic>[];

    var directories = files.where((f) => f.isDirectory).toList()
      ..sort(_compareFilenames);
    var singleFileComics =
        files
            .where((f) => !f.isDirectory && _isSingleFileComicResource(f.name))
            .toList()
          ..sort(_compareFilenames);

    for (var dir in directories) {
      try {
        var comicPath = _joinPath(path, dir.name);
        var childFiles = await listDirectory(comicPath);
        var comic = await parseComicDirectory(
          comicPath,
          knownFiles: childFiles,
        );
        if (comic != null) {
          comics.add(comic);
        } else {
          // 非漫画目录，递归扫描子目录
          var subComics = await _scanComicsRecursive(
            comicPath,
            currentDepth + 1,
            maxDepth,
            knownFiles: childFiles,
          );
          comics.addAll(subComics);
        }
      } catch (e, s) {
        Log.error(
          'WebDavComicManager',
          'Failed to parse comic ${dir.name}: $e',
          s,
        );
      }
    }

    for (var file in singleFileComics) {
      try {
        var comic = await _parseComicFile(path, file);
        if (comic != null) {
          comics.add(comic);
        }
      } catch (e, s) {
        Log.error(
          'WebDavComicManager',
          'Failed to parse comic file ${file.name}: $e',
          s,
        );
      }
    }

    return comics;
  }

  /// 解析单个漫画目录
  ///
  /// [path] 相对于 basePath 的路径
  Future<LocalComic?> parseComicDirectory(
    String path, {
    List<WebDavFile>? knownFiles,
  }) async {
    var files = (knownFiles ?? await listDirectory(path))
        .where(
          (f) => !WebDavCachePaths.isInternalMetadataEntry(
            name: f.name,
            isDirectory: f.isDirectory,
          ),
        )
        .toList();

    // 分离目录和图片文件
    var subdirs = files.where((f) => f.isDirectory).toList();
    var imageFiles = files
        .where((f) => !f.isDirectory && _isImageFile(f.name))
        .toList();

    final chapterDirs = await _findChapterDirectories(path, subdirs);
    final hasChapters = chapterDirs.isNotEmpty;

    String coverPath;
    List<String> chapters = [];
    var tags = <String>[];

    if (hasChapters) {
      chapters = chapterDirs.map((d) => d.name).toList();
      if (imageFiles.isNotEmpty) {
        imageFiles.sort(_compareFilenames);
        coverPath = _pickCoverName(imageFiles);
        tags.add(WebDavCachePaths.rootCoverTag);
      } else {
        coverPath = chapterDirs.first.cover;
      }
    } else {
      // 单章节漫画
      if (imageFiles.isEmpty) {
        Log.warning('WebDavComicManager', 'No images found in $path');
        return null;
      }

      imageFiles.sort(_compareFilenames);
      coverPath = imageFiles
          .firstWhere(
            (f) => f.name.toLowerCase().startsWith('cover'),
            orElse: () => imageFiles.first,
          )
          .name;
    }

    // 提取漫画名称
    var name = path.split('/').last;

    // 生成稳定且可复现的唯一 ID，避免 hashCode 变化导致历史/收藏错位
    var id = 'webdav_${md5.convert(utf8.encode(path)).toString()}';

    return LocalComic(
      id: id,
      title: name,
      subtitle: '',
      tags: tags,
      directory: path, // 存储相对路径
      chapters: hasChapters
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: coverPath,
      comicType: ComicType.webdav,
      downloadedChapters: chapters,
      createdAt: DateTime.now(),
    );
  }

  Future<List<_WebDavChapterDirectory>> _findChapterDirectories(
    String path,
    List<WebDavFile> subdirs,
  ) async {
    var sortedSubdirs = [...subdirs]..sort(_compareFilenames);
    var chapters = <_WebDavChapterDirectory>[];

    for (var dir in sortedSubdirs) {
      var chapterPath = _joinPath(path, dir.name);
      var chapterFiles = await listDirectory(chapterPath);
      var chapterImages = chapterFiles
          .where((f) => !f.isDirectory && _isImageFile(f.name))
          .toList();
      if (chapterImages.isEmpty) {
        continue;
      }
      chapterImages.sort(_compareFilenames);
      chapters.add(
        _WebDavChapterDirectory(
          name: dir.name,
          cover: _pickCoverName(chapterImages),
        ),
      );
    }

    return chapters;
  }

  String _pickCoverName(List<WebDavFile> imageFiles) {
    return imageFiles
        .firstWhere(
          (f) => f.name.toLowerCase().startsWith('cover'),
          orElse: () => imageFiles.first,
        )
        .name;
  }

  Future<LocalComic?> _parseComicFile(String directory, WebDavFile file) async {
    final remotePath = _joinPath(directory, file.name);

    if (_isMobiFile(file.name)) {
      final book =
          await WebDavMobiService().prepareStreamingMeta(
            remotePath: remotePath,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          ) ??
          await WebDavMobiService().prepareFromWebDav(
            remotePath: remotePath,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          );
      return _buildSingleFileComic(
        id: book.id,
        title: book.title,
        subtitle: book.subtitle,
        tags: book.tags,
        directory: book.directory,
        cover: book.cover,
        createdAt: book.createdAt,
      );
    }

    if (_isArchiveFile(file.name)) {
      final book =
          await WebDavArchiveService().prepareStreamingMeta(
            remotePath: remotePath,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          ) ??
          await WebDavArchiveService().prepareFromWebDav(
            remotePath: remotePath,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          );
      return _buildSingleFileComic(
        id: book.id,
        title: book.title,
        subtitle: book.subtitle,
        tags: book.tags,
        directory: book.directory,
        cover: book.cover,
        createdAt: book.createdAt,
      );
    }

    if (_isEpubFile(file.name)) {
      final book =
          await WebDavEpubService().prepareStreamingMeta(
            remotePath: remotePath,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          ) ??
          await WebDavEpubService().prepareFromWebDav(
            remotePath: remotePath,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          );
      return _buildSingleFileComic(
        id: book.id,
        title: book.title,
        subtitle: book.subtitle,
        tags: book.tags,
        directory: book.directory,
        cover: book.cover,
        createdAt: book.createdAt,
      );
    }

    if (_isPdfFile(file.name)) {
      return _buildSingleFileComic(
        id: WebDavPdfService.buildBookId(remotePath),
        title: _stripFileExtension(file.name),
        subtitle: '',
        tags: const <String>['webdav:pdf'],
        directory: WebDavPdfService.encodeDirectory(remotePath),
        cover: '',
        createdAt: DateTime.now(),
      );
    }

    return null;
  }

  LocalComic _buildSingleFileComic({
    required String id,
    required String title,
    required String subtitle,
    required List<String> tags,
    required String directory,
    required String cover,
    required DateTime createdAt,
  }) {
    return LocalComic(
      id: id,
      title: title,
      subtitle: subtitle,
      tags: tags,
      directory: directory,
      chapters: null,
      cover: cover,
      comicType: ComicType.webdav,
      downloadedChapters: const <String>[],
      createdAt: createdAt,
    );
  }

  /// 获取缓存大小（字节）
  Future<int> getCacheSize() async {
    var totalSize = 0;
    for (var dirName in WebDavCachePaths.allCacheDirectoryNames) {
      var cacheDir = WebDavCachePaths.cacheDirectory(dirName);
      if (!await cacheDir.exists()) continue;
      await for (var entity in cacheDir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
    }
    return totalSize;
  }

  /// 清除缓存
  Future<void> clearCache() async {
    for (var dirName in WebDavCachePaths.allCacheDirectoryNames) {
      var cacheDir = WebDavCachePaths.cacheDirectory(dirName);
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    }
    Log.info('WebDavComicManager', 'Cache cleared');
    notifyListeners();
  }

  String _scopePath(String path) {
    final currentConfig = config;
    if (currentConfig == null || !currentConfig.isConfigured) {
      throw Exception('WebDAV not configured');
    }
    return WebDavPathUtils.scope(currentConfig, path);
  }

  String _joinPath(String base, String name) {
    return WebDavPathUtils.normalize(base == '/' ? '/$name' : '$base/$name');
  }

  /// 判断是否为图片文件
  bool _isImageFile(String filename) {
    const imageExtensions = [
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'jpe',
      'avif',
    ];
    var ext = filename.split('.').last.toLowerCase();
    return imageExtensions.contains(ext);
  }

  bool _isSingleFileComicResource(String filename) {
    return _isMobiFile(filename) ||
        _isArchiveFile(filename) ||
        _isEpubFile(filename) ||
        _isPdfFile(filename);
  }

  bool _isMobiFile(String filename) {
    const mobiExtensions = ['mobi', 'azw', 'azw3', 'azw4'];
    return mobiExtensions.contains(filename.split('.').last.toLowerCase());
  }

  bool _isArchiveFile(String filename) {
    const archiveExtensions = ['zip', 'cbz', '7z', 'cb7', 'rar', 'cbr'];
    return archiveExtensions.contains(filename.split('.').last.toLowerCase());
  }

  bool _isEpubFile(String filename) {
    return filename.split('.').last.toLowerCase() == 'epub';
  }

  bool _isPdfFile(String filename) {
    return filename.split('.').last.toLowerCase() == 'pdf';
  }

  String _stripFileExtension(String filename) {
    final index = filename.lastIndexOf('.');
    if (index > 0) {
      return filename.substring(0, index).trim();
    }
    return filename.trim();
  }

  /// 智能文件名比较（优先按数字排序）
  int _compareFilenames(dynamic a, dynamic b) {
    String aName = a is String ? a : (a as WebDavFile).name;
    String bName = b is String ? b : (b as WebDavFile).name;

    // 尝试提取数字前缀
    var aNum = int.tryParse(aName.split('.').first);
    var bNum = int.tryParse(bName.split('.').first);

    if (aNum != null && bNum != null) {
      return aNum.compareTo(bNum);
    }

    // 回退到字符串比较
    return aName.compareTo(bName);
  }

  @override
  void dispose() {
    _client = null;
    super.dispose();
  }
}
