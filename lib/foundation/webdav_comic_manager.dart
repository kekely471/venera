// WebDAV 漫画管理器
// @author: kirk

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
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
  ///
  /// 返回格式: {'url': ..., 'username': ..., 'password': ..., 'basePath': ...}
  /// 如果未配置则返回 null
  Map<String, String>? get config {
    var cfg = appdata.settings['webdavComics'];
    if (cfg is! Map) return null;

    if (!cfg.containsKey('url') ||
        !cfg.containsKey('username') ||
        !cfg.containsKey('password') ||
        !cfg.containsKey('basePath')) {
      return null;
    }

    return {
      'url': cfg['url'].toString(),
      'username': cfg['username'].toString(),
      'password': cfg['password'].toString(),
      'basePath': cfg['basePath'].toString(),
    };
  }

  /// 是否已配置 WebDAV
  bool get isConfigured {
    var cfg = config;
    return cfg != null && cfg['url']!.isNotEmpty;
  }

  /// 保存配置
  Future<void> saveConfig(
    String url,
    String username,
    String password,
    String basePath,
  ) async {
    appdata.settings['webdavComics'] = {
      'url': url,
      'username': username,
      'password': password,
      'basePath': basePath,
    };
    await appdata.saveData();

    // 清除旧客户端
    _client = null;
    _lastUsed = null;

    notifyListeners();
  }

  /// 清除配置
  Future<void> clearConfig() async {
    appdata.settings['webdavComics'] = null;
    await appdata.saveData();

    _client = null;
    _lastUsed = null;

    notifyListeners();
  }

  /// 获取或创建 WebDAV 客户端
  webdav.Client _getClient() {
    var cfg = config;
    if (cfg == null) {
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
    _client = webdav.newClient(
      cfg['url']!,
      user: cfg['username']!,
      password: cfg['password']!,
      adapter: RHttpAdapter(),
    );
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
        if (i == maxRetries - 1) rethrow;
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

  /// 列举目录内容
  ///
  /// [path] 相对于 basePath 的路径（如 "/" 或 "/OnePiece"）
  Future<List<WebDavFile>> listDirectory(String path) async {
    return _withRetry(() async {
      var client = _getClient();
      var cfg = config!;
      var fullPath = _normalizePath('${cfg['basePath']}$path');

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
      var client = _getClient();
      var cfg = config!;
      var fullPath = _normalizePath('${cfg['basePath']}$path');

      Log.info('WebDavComicManager', 'Reading file: $fullPath');

      var bytes = await client.read(fullPath);
      return Uint8List.fromList(bytes);
    });
  }

  /// 检查文件是否存在
  Future<bool> fileExists(String path) async {
    try {
      return _withRetry(() async {
        var client = _getClient();
        var cfg = config!;
        var fullPath = _normalizePath('${cfg['basePath']}$path');

        var files = await client.readDir(fullPath);
        return files.isNotEmpty;
      });
    } catch (e) {
      return false;
    }
  }

  /// 扫描漫画目录（递归）
  ///
  /// [path] 相对于 basePath 的路径，默认为根目录 "/"
  /// [maxDepth] 最大递归深度，防止过深扫描
  Future<List<LocalComic>> scanComics(String path, {int maxDepth = 5}) async {
    return _scanComicsRecursive(path, 0, maxDepth);
  }

  Future<List<LocalComic>> _scanComicsRecursive(
    String path,
    int currentDepth,
    int maxDepth,
  ) async {
    if (currentDepth >= maxDepth) {
      Log.info('WebDavComicManager', 'Max scan depth reached at $path');
      return [];
    }

    var files = await listDirectory(path);
    var comics = <LocalComic>[];

    var directories = files.where((f) => f.isDirectory).toList();

    for (var dir in directories) {
      try {
        var comicPath = path == '/' ? '/${dir.name}' : '$path/${dir.name}';
        var comic = await parseComicDirectory(comicPath);
        if (comic != null) {
          comics.add(comic);
        } else {
          // 非漫画目录，递归扫描子目录
          var subComics = await _scanComicsRecursive(
            comicPath,
            currentDepth + 1,
            maxDepth,
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

    return comics;
  }

  /// 解析单个漫画目录
  ///
  /// [path] 相对于 basePath 的路径
  Future<LocalComic?> parseComicDirectory(String path) async {
    var files = await listDirectory(path);

    // 分离目录和图片文件
    var subdirs = files.where((f) => f.isDirectory).toList();
    var imageFiles = files
        .where((f) => !f.isDirectory && _isImageFile(f.name))
        .toList();

    // 判断是否有章节
    bool hasChapters = subdirs.isNotEmpty && imageFiles.isEmpty;

    String coverPath;
    List<String> chapters = [];

    if (hasChapters) {
      // 多章节漫画
      chapters = subdirs.map((d) => d.name).toList();
      chapters.sort(_compareFilenames);

      // 尝试在第一个章节中找封面
      var firstChapterFiles = await listDirectory('$path/${chapters.first}');
      var firstChapterImages = firstChapterFiles
          .where((f) => !f.isDirectory && _isImageFile(f.name))
          .toList();

      if (firstChapterImages.isEmpty) {
        Log.warning(
          'WebDavComicManager',
          'No images found in first chapter of $path',
        );
        return null;
      }

      firstChapterImages.sort(_compareFilenames);
      coverPath = firstChapterImages
          .firstWhere(
            (f) => f.name.toLowerCase().startsWith('cover'),
            orElse: () => firstChapterImages.first,
          )
          .name;
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

    // 生成唯一 ID
    var id = 'webdav_${path.hashCode.abs()}';

    return LocalComic(
      id: id,
      title: name,
      subtitle: '',
      tags: [],
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

  /// 获取缓存大小（字节）
  Future<int> getCacheSize() async {
    var totalSize = 0;
    for (var dirName in const ['webdav_comics', 'webdav_mobi', 'webdav_pdf']) {
      var cacheDir = Directory('${App.cachePath}/$dirName');
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
    for (var dirName in const ['webdav_comics', 'webdav_mobi', 'webdav_pdf']) {
      var cacheDir = Directory('${App.cachePath}/$dirName');
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    }
    Log.info('WebDavComicManager', 'Cache cleared');
    notifyListeners();
  }

  /// 规范化路径
  String _normalizePath(String path) {
    // 确保路径以 / 开头
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    // 移除重复的 /
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    return path;
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
