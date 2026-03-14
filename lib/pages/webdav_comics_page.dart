// WebDAV 漫画浏览管理页面
// @author: kirk

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';
import 'package:venera/foundation/image_provider/webdav_comic_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_archive_service.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/foundation/webdav_mobi_service.dart';
import 'package:venera/foundation/webdav_reading_progress.dart';
import 'package:venera/pages/webdav_pdf_reader_page.dart';

import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart';

class WebDavComicsPage extends StatefulWidget {
  const WebDavComicsPage({super.key});

  @override
  State<WebDavComicsPage> createState() => _WebDavComicsPageState();
}

class _WebDavComicsPageState extends State<WebDavComicsPage> {
  static const int _largeDirectoryThreshold = 500;
  static const int _directoryCoverSearchMaxDepth = 4;
  static const int _directoryCoverSearchBranchPerLevel = 8;
  static const int _directoryCoverSearchMaxDirectoryVisits = 24;
  static const int _maxCoverResolveConcurrency = 3;
  static const int _maxCoverPrefetchConcurrency = 2;
  static const int _prefetchLimitNormalDirectory = 120;
  static const int _prefetchLimitLargeDirectory = 36;

  final _manager = WebDavComicManager();

  // 配置
  late TextEditingController _urlController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _basePathController;

  // 状态
  bool _isConfigured = false;
  bool _isScanning = false;
  bool _isBrowsing = false;
  String _currentPath = '/';
  List<WebDavFile> _currentFiles = [];
  List<LocalComic> _scannedComics = [];
  String? _error;
  String? _cacheSize;
  final Map<String, Future<String?>> _directoryCoverFutureCache = {};
  final Map<String, Future<String?>> _mobiCoverFutureCache = {};
  final Map<String, Future<String?>> _archiveCoverFutureCache = {};
  final Map<String, Future<String?>> _mobiCoverBuildFutureCache = {};
  final Map<String, Future<String?>> _archiveCoverBuildFutureCache = {};
  final Map<String, Future<void>> _remoteCoverCacheInFlight = {};
  bool _isLargeDirectory = false;
  int _coverResolveInFlight = 0;
  final List<Completer<void>> _coverResolveQueue = [];
  int _coverPrefetchInFlight = 0;
  final List<Completer<void>> _coverPrefetchQueue = [];
  int _coverPrefetchSession = 0;
  Timer? _coverRefreshTimer;

  // 显示模式
  _ViewMode _viewMode = _ViewMode.browse;

  // 书架数据
  List<LocalComic> _bookshelfComics = [];

  // 最近阅读
  List<History> _recentHistories = [];

  @override
  void initState() {
    super.initState();
    _loadRecentHistories();
    var config = _manager.config;
    _urlController = TextEditingController(text: config?['url'] ?? '');
    _usernameController = TextEditingController(
      text: config?['username'] ?? '',
    );
    _passwordController = TextEditingController(
      text: config?['password'] ?? '',
    );
    _basePathController = TextEditingController(
      text: config?['basePath'] ?? '/',
    );
    _isConfigured = _manager.isConfigured;

    if (_isConfigured) {
      _loadDirectory('/');
      _loadCacheSize();
    }
  }

  @override
  void dispose() {
    _coverPrefetchSession++;
    for (var waiter in _coverResolveQueue) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    for (var waiter in _coverPrefetchQueue) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _coverResolveQueue.clear();
    _coverPrefetchQueue.clear();
    _coverRefreshTimer?.cancel();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _basePathController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    var url = _urlController.text.trim();
    var username = _usernameController.text.trim();
    var password = _passwordController.text.trim();
    var basePath = _basePathController.text.trim();

    if (url.isEmpty) {
      setState(() {
        _error = 'URL is required';
      });
      return;
    }
    if (basePath.isEmpty) {
      basePath = '/';
    }

    await _manager.saveConfig(url, username, password, basePath);
    setState(() {
      _isConfigured = true;
      _error = null;
    });
    _loadDirectory('/');
    _loadCacheSize();
  }

  Future<void> _testConnection() async {
    try {
      // 临时保存配置以测试
      await _saveConfig();
      await _manager.listDirectory('/');
      if (mounted) {
        showToast(message: "Connection Successful".tl, context: context);
      }
    } catch (e) {
      if (mounted) {
        showToast(message: "${"Connection Failed".tl}: $e", context: context);
      }
    }
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isBrowsing = true;
      _error = null;
    });
    try {
      var files = await _manager.listDirectory(path);
      files.sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.compareTo(b.name);
      });
      var isLargeDirectory = files.length > _largeDirectoryThreshold;
      if (mounted) {
        setState(() {
          _currentPath = path;
          _currentFiles = files;
          _isBrowsing = false;
          _viewMode = _ViewMode.browse;
          _isLargeDirectory = isLargeDirectory;
        });
      }
      if (_directoryCoverFutureCache.length > 1200) {
        _directoryCoverFutureCache.clear();
      }
      if (_mobiCoverFutureCache.length > 1200) {
        _mobiCoverFutureCache.clear();
      }
      if (_archiveCoverFutureCache.length > 1200) {
        _archiveCoverFutureCache.clear();
      }
      _prefetchListCovers(path, files, isLargeDirectory);
    } catch (e, s) {
      Log.error('WebDavComicsPage', 'Failed to list directory: $e', s);
      if (mounted) {
        setState(() {
          _isBrowsing = false;
          _error = e.toString();
        });
      }
    }
  }

  void _prefetchListCovers(
    String basePath,
    List<WebDavFile> files,
    bool isLargeDirectory,
  ) {
    _coverPrefetchSession++;
    final session = _coverPrefetchSession;
    final candidates = files
        .where(
          (f) => f.isDirectory || _isMobiFile(f.name) || _isArchiveFile(f.name),
        )
        .take(
          isLargeDirectory
              ? _prefetchLimitLargeDirectory
              : _prefetchLimitNormalDirectory,
        )
        .toList();
    if (candidates.isEmpty) return;

    for (final file in candidates) {
      final path = _joinPath(basePath, file.name);
      unawaited(_prefetchCoverForEntry(path, file, session));
    }
  }

  Future<void> _prefetchCoverForEntry(
    String path,
    WebDavFile file,
    int session,
  ) async {
    if (session != _coverPrefetchSession) return;

    try {
      if (file.isDirectory) {
        final remoteCoverPath = await _resolveDirectoryCover(path);
        if (remoteCoverPath == null || session != _coverPrefetchSession) {
          return;
        }
        await _runWithCoverPrefetchSlot(
          () => _cacheRemoteImage(remoteCoverPath),
        );
        if (session == _coverPrefetchSession) {
          _scheduleCoverRefresh();
        }
        return;
      }

      if (_isMobiFile(file.name)) {
        final localCoverPath = await _ensureMobiFileCover(path, file);
        if (localCoverPath != null && session == _coverPrefetchSession) {
          _scheduleCoverRefresh();
        }
        return;
      }

      if (_isArchiveFile(file.name)) {
        final localCoverPath = await _ensureArchiveFileCover(path, file);
        if (localCoverPath != null && session == _coverPrefetchSession) {
          _scheduleCoverRefresh();
        }
      }
    } catch (e, s) {
      Log.warning('WebDavComicsPage', 'Failed to prefetch cover for $path: $e');
      Log.warning('WebDavComicsPage', s.toString());
    }
  }

  Future<T> _runWithCoverPrefetchSlot<T>(Future<T> Function() task) async {
    while (_coverPrefetchInFlight >= _maxCoverPrefetchConcurrency) {
      var completer = Completer<void>();
      _coverPrefetchQueue.add(completer);
      await completer.future;
    }
    _coverPrefetchInFlight++;
    try {
      return await task();
    } finally {
      _coverPrefetchInFlight--;
      if (_coverPrefetchQueue.isNotEmpty) {
        _coverPrefetchQueue.removeAt(0).complete();
      }
    }
  }

  void _scheduleCoverRefresh() {
    if (!mounted) return;
    if (_coverRefreshTimer != null) return;
    _coverRefreshTimer = Timer(const Duration(milliseconds: 120), () {
      _coverRefreshTimer = null;
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _cacheRemoteImage(String remotePath) async {
    var inFlight = _remoteCoverCacheInFlight[remotePath];
    if (inFlight != null) {
      await inFlight;
      return;
    }

    var future = Future<void>(() async {
      final cacheFile = _getRemoteImageCacheFile(remotePath);
      if (await cacheFile.exists()) {
        return;
      }
      final bytes = await _manager.readFile(remotePath);
      if (bytes.isEmpty) return;
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: false);
    });
    _remoteCoverCacheInFlight[remotePath] = future;

    try {
      await future;
    } catch (e, s) {
      Log.warning(
        'WebDavComicsPage',
        'Failed to cache remote cover for $remotePath: $e\n$s',
      );
    } finally {
      if (identical(_remoteCoverCacheInFlight[remotePath], future)) {
        _remoteCoverCacheInFlight.remove(remotePath);
      }
    }
  }

  File _getRemoteImageCacheFile(String remotePath) {
    var relative = remotePath;
    if (relative.startsWith('/')) {
      relative = relative.substring(1);
    }
    return File(FilePath.join(App.cachePath, 'webdav_comics', relative));
  }

  Future<void> _scanComics() async {
    setState(() {
      _isScanning = true;
      _error = null;
      _scannedComics = [];
    });
    try {
      var comics = await _manager.scanComics(_currentPath);
      if (mounted) {
        setState(() {
          _scannedComics = comics;
          _isScanning = false;
          _viewMode = _ViewMode.scanned;
        });
      }
    } catch (e, s) {
      Log.error('WebDavComicsPage', 'Failed to scan comics: $e', s);
      if (mounted) {
        setState(() {
          _isScanning = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _importComic(LocalComic comic) async {
    try {
      await _syncComicAndRead(comic, showImportedMessage: true);
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        showToast(message: "${"Import Failed".tl}: $e", context: context);
      }
    }
  }

  Future<void> _importAll() async {
    var count = 0;
    for (var comic in _scannedComics) {
      try {
        LocalManager().add(comic);
        count++;
      } catch (e) {
        Log.error('WebDavComicsPage', 'Failed to import ${comic.title}: $e');
      }
    }
    if (mounted) {
      showToast(
        message: "${"Imported".tl} $count ${"comics".tl}",
        context: context,
      );
      setState(() {});
    }
  }

  Future<void> _loadCacheSize() async {
    var size = await _manager.getCacheSize();
    if (mounted) {
      setState(() {
        if (size < 1024) {
          _cacheSize = '${size}B';
        } else if (size < 1024 * 1024) {
          _cacheSize = '${(size / 1024).toStringAsFixed(1)}KB';
        } else if (size < 1024 * 1024 * 1024) {
          _cacheSize = '${(size / 1024 / 1024).toStringAsFixed(1)}MB';
        } else {
          _cacheSize = '${(size / 1024 / 1024 / 1024).toStringAsFixed(1)}GB';
        }
      });
    }
  }

  Future<void> _pullReadingProgress() async {
    showToast(message: "Pulling progress...".tl, context: context);
    try {
      var service = WebDavReadingProgress();
      var count = await service.pullProgress();
      if (mounted) {
        showToast(
          message: "Pulled @count records".tlParams({'count': count}),
          context: context,
        );
      }
    } catch (e) {
      if (mounted) {
        showToast(message: "Error: $e", context: context);
      }
    }
  }

  Future<void> _pushReadingProgress() async {
    showToast(message: "Pushing progress...".tl, context: context);
    try {
      var service = WebDavReadingProgress();
      await service.pushProgress();
      if (mounted) {
        showToast(message: "Progress pushed".tl, context: context);
      }
    } catch (e) {
      if (mounted) {
        showToast(message: "Error: $e", context: context);
      }
    }
  }

  void _loadRecentHistories() {
    var all = HistoryManager()
        .getRecent()
        .where((h) => h.type == ComicType.webdav)
        .take(10)
        .toList();
    setState(() {
      _recentHistories = all;
    });
  }

  void _loadBookshelf() {
    var all = LocalManager()
        .getComics(LocalSortType.timeDesc)
        .where((c) => c.comicType == ComicType.webdav)
        .toList();
    setState(() {
      _bookshelfComics = all;
      _viewMode = _ViewMode.bookshelf;
    });
  }

  Future<void> _clearCache() async {
    await _manager.clearCache();
    await _loadCacheSize();
    if (mounted) {
      showToast(message: "Cache Cleared".tl, context: context);
    }
  }

  void _clearReadingHistory() {
    showConfirmDialog(
      context: context,
      title: "Clear Reading History".tl,
      content: "Clear all WebDAV reading history?".tl,
      onConfirm: () {
        HistoryManager().clearHistoryByType(ComicType.webdav);
        showToast(message: "Reading history cleared".tl, context: context);
      },
    );
  }

  Future<void> _disconnectWebDav() async {
    await _manager.clearConfig();
    setState(() {
      _isConfigured = false;
      _currentFiles = [];
      _scannedComics = [];
      _currentPath = '/';
      _urlController.clear();
      _usernameController.clear();
      _passwordController.clear();
      _basePathController.text = '/';
    });
  }

  void _navigateUp() {
    if (_currentPath == '/') return;
    var parts = _currentPath.split('/');
    parts.removeLast();
    var parentPath = parts.join('/');
    if (parentPath.isEmpty) parentPath = '/';
    _loadDirectory(parentPath);
  }

  bool _isImported(LocalComic comic) {
    return LocalManager().find(comic.id, ComicType.webdav) != null;
  }

  // 面包屑路径
  List<String> get _breadcrumbs {
    if (_currentPath == '/') return ['/'];
    var parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    return ['/', ...parts];
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        if (!_isConfigured)
          _buildConfigForm()
        else ...[
          _buildToolbar(),
          if (_viewMode == _ViewMode.browse) _buildRecentReading(),
          if (_viewMode != _ViewMode.bookshelf) _buildBreadcrumb(),
          if (_error != null) _buildError(),
          if (_isBrowsing || _isScanning) _buildLoading(),
          if (_viewMode == _ViewMode.browse && !_isBrowsing) _buildFileList(),
          if (_viewMode == _ViewMode.scanned && !_isScanning)
            _buildScannedComics(),
          if (_viewMode == _ViewMode.bookshelf) _buildBookshelf(),
        ],
      ],
    );
  }

  Widget _buildToolbar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: _buildActions()),
      ),
    );
  }

  List<Widget> _buildActions() {
    if (!_isConfigured) return [];
    return [
      if (_viewMode == _ViewMode.scanned || _viewMode == _ViewMode.bookshelf)
        Tooltip(
          message: "Browse".tl,
          child: IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: () {
              setState(() {
                _viewMode = _ViewMode.browse;
              });
            },
          ),
        ),
      Tooltip(
        message: "Scan Comics".tl,
        child: IconButton(
          icon: const Icon(Icons.document_scanner_outlined),
          onPressed: _isScanning ? null : _scanComics,
        ),
      ),
      const Spacer(),
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.collections_bookmark_outlined,
            text: "Bookshelf".tl,
            onClick: _loadBookshelf,
          ),
          MenuEntry(
            icon: Icons.refresh,
            text: "Refresh".tl,
            onClick: () => _loadDirectory(_currentPath),
          ),
          MenuEntry(
            icon: Icons.cloud_download_outlined,
            text: "Pull Progress".tl,
            onClick: _pullReadingProgress,
          ),
          MenuEntry(
            icon: Icons.cloud_upload_outlined,
            text: "Push Progress".tl,
            onClick: _pushReadingProgress,
          ),
          MenuEntry(
            icon: Icons.cleaning_services_outlined,
            text:
                "${"Clear Cache".tl}${_cacheSize != null ? ' ($_cacheSize)' : ''}",
            onClick: _clearCache,
          ),
          MenuEntry(
            icon: Icons.history_outlined,
            text: "Clear Reading History".tl,
            onClick: _clearReadingHistory,
          ),
          MenuEntry(
            icon: Icons.settings,
            text: "Settings".tl,
            onClick: () => _showConfigDialog(),
          ),
          MenuEntry(
            icon: Icons.link_off,
            text: "Disconnect".tl,
            onClick: _disconnectWebDav,
          ),
        ],
      ),
    ];
  }

  Widget _buildConfigForm() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            Icon(
              Icons.cloud_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              "Connect to WebDAV".tl,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: "WebDAV URL".tl,
                hintText: "https://your-nas.com/dav",
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _basePathController,
              decoration: InputDecoration(
                labelText: "Base Path".tl,
                hintText: "/comics",
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.folder),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testConnection,
                    child: Text("Test Connection".tl),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saveConfig,
                    child: Text("Connect".tl),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumb() {
    return SliverToBoxAdapter(
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (_currentPath != '/')
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 20),
                onPressed: _navigateUp,
                tooltip: "Up".tl,
              ),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _breadcrumbs.length,
                separatorBuilder: (_, __) => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.chevron_right, size: 16),
                ),
                itemBuilder: (context, index) {
                  var label = _breadcrumbs[index];
                  return GestureDetector(
                    onTap: () {
                      if (index == 0) {
                        _loadDirectory('/');
                      } else {
                        var path =
                            '/${_breadcrumbs.skip(1).take(index).join('/')}';
                        _loadDirectory(path);
                      }
                    },
                    child: Center(
                      child: Text(
                        label == '/' ? 'Root' : label,
                        style: TextStyle(
                          color: index == _breadcrumbs.length - 1
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          fontWeight: index == _breadcrumbs.length - 1
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _loadDirectory(_currentPath),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_isScanning ? "Scanning...".tl : "Loading...".tl),
            ],
          ),
        ),
      ),
    );
  }

  /// 尝试将目录作为漫画打开
  Future<void> _openDirectoryAsComic(String path) async {
    try {
      showToast(message: "Loading...".tl, context: context);
      var comic = await _manager.parseComicDirectory(path);
      if (comic == null) {
        if (mounted) {
          showToast(
            message: "Not a valid comic directory".tl,
            context: context,
          );
        }
        return;
      }
      await _syncComicAndRead(comic);
    } catch (e) {
      Log.error('WebDavComicsPage', 'Failed to open as comic: $e');
      if (mounted) {
        showToast(message: "Error: $e", context: context);
      }
    }
  }

  /// 将当前目录作为漫画打开
  Future<void> _openCurrentDirAsComic() async {
    await _openDirectoryAsComic(_currentPath);
  }

  Future<void> _openMobiFile(String path, WebDavFile file) async {
    try {
      // 优先尝试流式模式（仅下载头部元数据）
      var mobiBook = await WebDavMobiService().prepareStreamingMeta(
        remotePath: path,
        fileName: file.name,
        remoteSize: file.size,
        remoteModifiedTime: file.modifiedTime,
      );

      // 流式模式不可用时 fallback 到全量下载
      if (mobiBook == null) {
        if (mounted) {
          showToast(message: "Loading...".tl, context: context);
        }
        mobiBook = await WebDavMobiService().prepareFromWebDav(
          remotePath: path,
          fileName: file.name,
          remoteSize: file.size,
          remoteModifiedTime: file.modifiedTime,
        );
      }

      var comic = LocalComic(
        id: mobiBook.id,
        title: mobiBook.title,
        subtitle: mobiBook.subtitle,
        tags: mobiBook.tags,
        directory: mobiBook.directory,
        chapters: null,
        cover: mobiBook.cover,
        comicType: ComicType.webdav,
        downloadedChapters: <String>[],
        createdAt: mobiBook.createdAt,
      );
      await _syncComicAndRead(comic);
    } catch (e, s) {
      Log.error('WebDavComicsPage', 'Failed to open mobi file: $e', s);
      if (mounted) {
        showToast(message: "Error: $e", context: context);
      }
    }
  }

  Future<void> _openPdfFile(String path, WebDavFile file) async {
    try {
      if (!mounted) return;
      context.to(
        () => WebDavPdfReaderPage.webdav(
          remotePath: path,
          title: _stripFileExtension(file.name),
          remoteSize: file.size,
        ),
      );
    } catch (e, s) {
      Log.error('WebDavComicsPage', 'Failed to open pdf file: $e', s);
      if (mounted) {
        showToast(message: "Error: $e", context: context);
      }
    }
  }

  Future<void> _openArchiveFile(String path, WebDavFile file) async {
    try {
      showToast(message: "Loading...".tl, context: context);
      final archiveBook =
          await WebDavArchiveService().prepareStreamingMeta(
            remotePath: path,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          ) ??
          await WebDavArchiveService().prepareFromWebDav(
            remotePath: path,
            fileName: file.name,
            remoteSize: file.size,
            remoteModifiedTime: file.modifiedTime,
          );
      var comic = LocalComic(
        id: archiveBook.id,
        title: archiveBook.title,
        subtitle: archiveBook.subtitle,
        tags: archiveBook.tags,
        directory: archiveBook.directory,
        chapters: null,
        cover: archiveBook.cover,
        comicType: ComicType.webdav,
        downloadedChapters: <String>[],
        createdAt: archiveBook.createdAt,
      );
      await _syncComicAndRead(comic);
    } catch (e, s) {
      Log.error('WebDavComicsPage', 'Failed to open archive file: $e', s);
      if (mounted) {
        showToast(message: "Error: $e", context: context);
      }
    }
  }

  Future<void> _syncComicAndRead(
    LocalComic comic, {
    bool showImportedMessage = false,
  }) async {
    // 每次阅读前同步一次，避免扫描结果与本地缓存记录不一致。
    await LocalManager().add(comic);
    var latest = LocalManager().find(comic.id, ComicType.webdav) ?? comic;
    if (mounted && showImportedMessage) {
      showToast(message: "${"Imported".tl}: ${comic.title}", context: context);
    }
    if (mounted) {
      latest.read();
    }
  }

  Widget _buildFileList() {
    if (_currentFiles.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              "Empty directory".tl,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ),
      );
    }

    // 检查当前目录是否包含图片文件
    var hasImages = _currentFiles.any(
      (f) => !f.isDirectory && _isImageFile(f.name),
    );

    return SliverMainAxisGroup(
      slivers: [
        if (hasImages)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.menu_book),
                label: Text("Read this comic".tl),
                onPressed: _openCurrentDirAsComic,
              ),
            ),
          ),
        if (_isLargeDirectory)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                "Large directory detected. Cover prefetch is limited to the first items."
                    .tl,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 0.66,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              var file = _currentFiles[index];
              return _buildBrowseCard(file);
            }, childCount: _currentFiles.length),
          ),
        ),
      ],
    );
  }

  Widget _buildBrowseCard(WebDavFile file) {
    var path = _joinPath(_currentPath, file.name);
    var subtitle = file.isDirectory
        ? "Directory".tl
        : _formatFileSize(file.size ?? 0);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _handleBrowseTap(file),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildBrowseCardCover(file, path)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
              child: Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (file.isDirectory)
              SizedBox(
                height: 34,
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () => _openDirectoryAsComic(path),
                        icon: const Icon(Icons.menu_book, size: 16),
                        label: Text("Read as comic".tl, maxLines: 1),
                      ),
                    ),
                    IconButton(
                      tooltip: "Open".tl,
                      onPressed: () => _loadDirectory(path),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseCardCover(WebDavFile file, String path) {
    if (file.isDirectory) {
      return FutureBuilder<String?>(
        future: _resolveDirectoryCover(path),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _buildCoverPlaceholder(
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          var coverPath = snapshot.data;
          if (coverPath != null) {
            return _buildRemoteCover(coverPath);
          }
          return _buildCoverPlaceholder(
            Icon(
              Icons.folder,
              size: 44,
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        },
      );
    }

    if (_isImageFile(file.name)) {
      return _buildRemoteCover(path);
    }

    if (_isMobiFile(file.name)) {
      return FutureBuilder<String?>(
        future: _resolveMobiFileCover(path, file),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _buildCoverPlaceholder(
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          var localCoverPath = snapshot.data;
          if (localCoverPath != null) {
            return _buildLocalCover(localCoverPath);
          }
          return _buildCoverPlaceholder(
            Icon(
              Icons.menu_book,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        },
      );
    }

    if (_isArchiveFile(file.name)) {
      return FutureBuilder<String?>(
        future: _resolveArchiveFileCover(path, file),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _buildCoverPlaceholder(
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          var localCoverPath = snapshot.data;
          if (localCoverPath != null) {
            return _buildLocalCover(localCoverPath);
          }
          return _buildCoverPlaceholder(
            Icon(
              Icons.archive,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        },
      );
    }

    return _buildCoverPlaceholder(
      Icon(
        _getFileIcon(file.name),
        size: 40,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildCoverPlaceholder(Widget child) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _buildRemoteCover(String remotePath) {
    return Image(
      image: WebDavComicImageProvider(remotePath),
      fit: BoxFit.cover,
      errorBuilder: (context, _, __) => _buildCoverPlaceholder(
        Icon(
          Icons.broken_image_outlined,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildLocalCover(String localPath) {
    return Image.file(
      File(localPath),
      fit: BoxFit.cover,
      errorBuilder: (context, _, __) => _buildCoverPlaceholder(
        Icon(
          Icons.broken_image_outlined,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Future<String?> _resolveMobiFileCover(String remotePath, WebDavFile file) {
    var key = _buildFileCoverCacheKey(remotePath, file);
    var cached = _mobiCoverFutureCache[key];
    if (cached != null) {
      return cached;
    }

    var future = Future<String?>(() async {
      try {
        var cachedMobiCover = _findCachedMobiCover(remotePath);
        if (cachedMobiCover != null) {
          return cachedMobiCover;
        }

        var previewFile = _getMobiPreviewFile(remotePath);
        if (await previewFile.exists()) {
          return previewFile.path;
        }
        return null;
      } catch (e, s) {
        Log.warning(
          'WebDavComicsPage',
          'Failed to resolve mobi cover for $remotePath: $e\n$s',
        );
        return null;
      }
    });
    _mobiCoverFutureCache[key] = future;
    future.then((value) {
      if (value == null) {
        _mobiCoverFutureCache.remove(key);
      }
    });
    return future;
  }

  Future<String?> _ensureMobiFileCover(String remotePath, WebDavFile file) {
    var key = _buildFileCoverCacheKey(remotePath, file);
    var cachedBuild = _mobiCoverBuildFutureCache[key];
    if (cachedBuild != null) {
      return cachedBuild;
    }

    var future = Future<String?>(() async {
      var cached = await _resolveMobiFileCover(remotePath, file);
      if (cached != null) {
        return cached;
      }
      var localCoverPath = await _runWithCoverPrefetchSlot(
        () => _buildMobiFileCover(remotePath, file),
      );
      if (localCoverPath != null) {
        _mobiCoverFutureCache[key] = Future.value(localCoverPath);
      }
      return localCoverPath;
    });

    _mobiCoverBuildFutureCache[key] = future;
    future.whenComplete(() {
      _mobiCoverBuildFutureCache.remove(key);
    });
    return future;
  }

  Future<String?> _buildMobiFileCover(
    String remotePath,
    WebDavFile file,
  ) async {
    try {
      // 优先尝试 Range 请求流式获取封面
      final coverPath = await WebDavMobiService().fetchCoverOnly(
        remotePath: remotePath,
        remoteSize: file.size,
      );
      if (coverPath != null) {
        return coverPath;
      }

      // Fallback: 全量下载解析
      final mobiBook = await WebDavMobiService().prepareFromWebDav(
        remotePath: remotePath,
        fileName: file.name,
        remoteSize: file.size,
        remoteModifiedTime: file.modifiedTime,
      );
      final cacheDir = WebDavMobiService.decodeDirectory(mobiBook.directory);
      if (cacheDir == null || cacheDir.isEmpty) {
        return _findCachedMobiCover(remotePath);
      }
      final coverFile = File(FilePath.join(cacheDir, mobiBook.cover));
      if (await coverFile.exists()) {
        return coverFile.path;
      }
      return _findCachedMobiCover(remotePath);
    } catch (e, s) {
      Log.warning(
        'WebDavComicsPage',
        'Failed to build mobi cover for $remotePath: $e\n$s',
      );
      return null;
    }
  }

  String? _findCachedMobiCover(String remotePath) {
    var key = md5.convert(utf8.encode(remotePath)).toString();
    var cacheDir = Directory(FilePath.join(App.cachePath, 'webdav_mobi', key));
    if (!cacheDir.existsSync()) {
      return null;
    }
    var files = cacheDir
        .listSync()
        .whereType<File>()
        .where((f) => _isImageFile(f.name))
        .toList();
    if (files.isEmpty) {
      return null;
    }
    files.sort((a, b) => a.name.compareTo(b.name));
    return files.first.path;
  }

  File _getMobiPreviewFile(String remotePath) {
    var key = md5.convert(utf8.encode(remotePath)).toString();
    return File(
      FilePath.join(App.cachePath, 'webdav_mobi_preview', '$key.bin'),
    );
  }

  Future<String?> _resolveArchiveFileCover(String remotePath, WebDavFile file) {
    var key = _buildFileCoverCacheKey(remotePath, file);
    var cached = _archiveCoverFutureCache[key];
    if (cached != null) {
      return cached;
    }

    var future = Future<String?>(() async {
      try {
        return _findCachedArchiveCover(remotePath);
      } catch (e, s) {
        Log.warning(
          'WebDavComicsPage',
          'Failed to resolve archive cover for $remotePath: $e\n$s',
        );
        return null;
      }
    });
    _archiveCoverFutureCache[key] = future;
    future.then((value) {
      if (value == null) {
        _archiveCoverFutureCache.remove(key);
      }
    });
    return future;
  }

  Future<String?> _ensureArchiveFileCover(String remotePath, WebDavFile file) {
    var key = _buildFileCoverCacheKey(remotePath, file);
    var cachedBuild = _archiveCoverBuildFutureCache[key];
    if (cachedBuild != null) {
      return cachedBuild;
    }

    var future = Future<String?>(() async {
      var cached = await _resolveArchiveFileCover(remotePath, file);
      if (cached != null) {
        return cached;
      }
      var localCoverPath = await _runWithCoverPrefetchSlot(
        () => _buildArchiveFileCover(remotePath, file),
      );
      if (localCoverPath != null) {
        _archiveCoverFutureCache[key] = Future.value(localCoverPath);
      }
      return localCoverPath;
    });

    _archiveCoverBuildFutureCache[key] = future;
    future.whenComplete(() {
      _archiveCoverBuildFutureCache.remove(key);
    });
    return future;
  }

  Future<String?> _buildArchiveFileCover(
    String remotePath,
    WebDavFile file,
  ) async {
    try {
      final streamCover = await WebDavArchiveService().fetchCoverOnly(
        remotePath: remotePath,
        fileName: file.name,
        remoteSize: file.size,
        remoteModifiedTime: file.modifiedTime,
      );
      if (streamCover != null) {
        return streamCover;
      }

      final archiveBook = await WebDavArchiveService().prepareFromWebDav(
        remotePath: remotePath,
        fileName: file.name,
        remoteSize: file.size,
        remoteModifiedTime: file.modifiedTime,
      );
      final cacheDir = WebDavArchiveService.decodeDirectory(
        archiveBook.directory,
      );
      if (cacheDir == null || cacheDir.isEmpty) {
        return _findCachedArchiveCover(remotePath);
      }
      final coverFile = File(FilePath.join(cacheDir, archiveBook.cover));
      if (await coverFile.exists()) {
        return coverFile.path;
      }
      return _findCachedArchiveCover(remotePath);
    } catch (e, s) {
      Log.warning(
        'WebDavComicsPage',
        'Failed to build archive cover for $remotePath: $e\n$s',
      );
      return null;
    }
  }

  String? _findCachedArchiveCover(String remotePath) {
    var key = md5.convert(utf8.encode(remotePath)).toString();
    var streamCacheDir = Directory(
      FilePath.join(App.cachePath, 'webdav_archive_stream', key),
    );
    if (streamCacheDir.existsSync()) {
      try {
        var metadataFile = streamCacheDir.joinFile('meta.json');
        if (metadataFile.existsSync()) {
          var metadata = jsonDecode(metadataFile.readAsStringSync());
          if (metadata is Map && metadata['cover'] is String) {
            var cover = (metadata['cover'] as String).trim();
            if (cover.isNotEmpty) {
              var coverFile = streamCacheDir.joinFile(cover);
              if (coverFile.existsSync()) {
                return coverFile.path;
              }
            }
          }
        }
      } catch (_) {
        // ignore broken metadata
      }
    }

    var cacheDir = Directory(
      FilePath.join(App.cachePath, 'webdav_archive', key),
    );
    if (!cacheDir.existsSync()) {
      return null;
    }

    try {
      var metadataFile = cacheDir.joinFile('meta.json');
      if (metadataFile.existsSync()) {
        var metadata = jsonDecode(metadataFile.readAsStringSync());
        if (metadata is Map && metadata['cover'] is String) {
          var cover = (metadata['cover'] as String).trim();
          if (cover.isNotEmpty) {
            var coverFile = cacheDir.joinFile(cover);
            if (coverFile.existsSync()) {
              return coverFile.path;
            }
          }
        }
      }
    } catch (_) {
      // ignore broken metadata
    }

    var files = cacheDir
        .listSync()
        .whereType<File>()
        .where((f) => _isImageFile(f.name))
        .toList();
    if (files.isEmpty) {
      return null;
    }
    files.sort((a, b) => a.name.compareTo(b.name));
    return files.first.path;
  }

  String _buildFileCoverCacheKey(String remotePath, WebDavFile file) {
    return '$remotePath|${file.size ?? -1}|${file.modifiedTime?.millisecondsSinceEpoch ?? -1}';
  }

  Future<String?> _resolveDirectoryCover(String directoryPath) {
    var cached = _directoryCoverFutureCache[directoryPath];
    if (cached != null) {
      return cached;
    }

    var future = _runWithCoverResolveSlot(() async {
      try {
        return await _findDirectoryCoverRecursive(directoryPath, 0);
      } catch (e, s) {
        Log.warning(
          'WebDavComicsPage',
          'Failed to resolve cover for $directoryPath: $e\n$s',
        );
        return null;
      }
    });
    _directoryCoverFutureCache[directoryPath] = future;
    future.then((value) {
      if (value == null) {
        _directoryCoverFutureCache.remove(directoryPath);
      }
    });
    return future;
  }

  Future<String?> _findDirectoryCoverRecursive(
    String directoryPath,
    int depth,
  ) async {
    var queue = <_CoverSearchNode>[_CoverSearchNode(directoryPath, depth)];
    var visited = 0;

    while (queue.isNotEmpty &&
        visited < _directoryCoverSearchMaxDirectoryVisits) {
      var node = queue.removeAt(0);
      visited++;

      var files = await _manager.listDirectory(node.path);
      var directCover = _pickFirstImageInDirectory(node.path, files);
      if (directCover != null) {
        return directCover;
      }

      if (node.depth >= _directoryCoverSearchMaxDepth) {
        continue;
      }

      var subDirs = files.where((f) => f.isDirectory).toList();
      subDirs.sort(_compareWebDavFileName);
      for (
        var i = 0;
        i < subDirs.length && i < _directoryCoverSearchBranchPerLevel;
        i++
      ) {
        queue.add(
          _CoverSearchNode(
            _joinPath(node.path, subDirs[i].name),
            node.depth + 1,
          ),
        );
      }
    }
    return null;
  }

  String? _pickFirstImageInDirectory(
    String directoryPath,
    List<WebDavFile> files,
  ) {
    var images = files
        .where((f) => !f.isDirectory && _isImageFile(f.name))
        .toList();
    if (images.isEmpty) {
      return null;
    }
    images.sort(_compareWebDavFileName);
    var cover = images.firstWhere(
      (f) => f.name.toLowerCase().startsWith('cover'),
      orElse: () => images.first,
    );
    return _joinPath(directoryPath, cover.name);
  }

  Future<T> _runWithCoverResolveSlot<T>(Future<T> Function() task) async {
    while (_coverResolveInFlight >= _maxCoverResolveConcurrency) {
      var completer = Completer<void>();
      _coverResolveQueue.add(completer);
      await completer.future;
    }
    _coverResolveInFlight++;
    try {
      return await task();
    } finally {
      _coverResolveInFlight--;
      if (_coverResolveQueue.isNotEmpty) {
        _coverResolveQueue.removeAt(0).complete();
      }
    }
  }

  int _compareWebDavFileName(WebDavFile a, WebDavFile b) {
    var aNum = int.tryParse(a.name.split('.').first);
    var bNum = int.tryParse(b.name.split('.').first);
    if (aNum != null && bNum != null) {
      return aNum.compareTo(bNum);
    }
    return a.name.compareTo(b.name);
  }

  String _joinPath(String parent, String name) {
    return parent == '/' ? '/$name' : '$parent/$name';
  }

  void _handleBrowseTap(WebDavFile file) {
    var path = _joinPath(_currentPath, file.name);
    if (file.isDirectory) {
      _loadDirectory(path);
      return;
    }

    if (_isImageFile(file.name)) {
      _openCurrentDirAsComic();
      return;
    }

    if (_isMobiFile(file.name)) {
      _openMobiFile(path, file);
      return;
    }

    if (_isPdfFile(file.name)) {
      _openPdfFile(path, file);
      return;
    }

    if (_isArchiveFile(file.name)) {
      _openArchiveFile(path, file);
    }
  }

  bool _isImageFile(String filename) {
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
    var ext = filename.split('.').last.toLowerCase();
    return imageExtensions.contains(ext);
  }

  bool _isMobiFile(String filename) {
    var ext = filename.split('.').last.toLowerCase();
    return ext == 'mobi' || ext == 'azw' || ext == 'azw3' || ext == 'azw4';
  }

  bool _isPdfFile(String filename) {
    return filename.split('.').last.toLowerCase() == 'pdf';
  }

  bool _isArchiveFile(String filename) {
    const archiveExtensions = ['zip', 'cbz', '7z', 'cb7', 'rar', 'cbr'];
    return archiveExtensions.contains(filename.split('.').last.toLowerCase());
  }

  Widget _buildScannedComics() {
    if (_scannedComics.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(
              children: [
                const Icon(Icons.search_off, size: 48),
                const SizedBox(height: 16),
                Text("No comics found".tl),
              ],
            ),
          ),
        ),
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  "${"Found".tl} ${_scannedComics.length} ${"comics".tl}",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.download, size: 18),
                  label: Text("Import All".tl),
                  onPressed: _importAll,
                ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            var comic = _scannedComics[index];
            var imported = _isImported(comic);
            return ListTile(
              leading: Icon(
                Icons.menu_book,
                color: imported ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(comic.title),
              subtitle: Text(
                comic.hasChapters
                    ? "${comic.chapters!.length} ${"chapters".tl}"
                    : "Single volume".tl,
              ),
              trailing: imported
                  ? Chip(
                      label: Text("Imported".tl),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                    )
                  : IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () => _importComic(comic),
                    ),
              onTap: () async {
                Log.info(
                  'WebDavComicsPage',
                  'Tapped comic: ${comic.title}, imported: $imported',
                );
                try {
                  if (imported) {
                    await _syncComicAndRead(comic);
                  } else {
                    await _importComic(comic);
                  }
                } catch (e, s) {
                  Log.error('WebDavComicsPage', 'Failed to open comic: $e', s);
                  if (mounted) {
                    showToast(message: 'Error: $e', context: context);
                  }
                }
              },
            );
          }, childCount: _scannedComics.length),
        ),
      ],
    );
  }

  Widget _buildRecentReading() {
    if (_recentHistories.isEmpty) return const SliverToBoxAdapter();

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              "Recent Reading".tl,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _recentHistories.length,
              itemBuilder: (context, index) {
                var history = _recentHistories[index];
                return _buildRecentItem(history);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentItem(History history) {
    var localComic = LocalManager().find(history.id, ComicType.webdav);
    return GestureDetector(
      onTap: () {
        if (localComic != null) {
          localComic.read();
        }
      },
      child: Container(
        width: 100,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: Image(
                    image: HistoryImageProvider(history),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    errorBuilder: (_, __, ___) =>
                        const Center(child: Icon(Icons.menu_book, size: 32)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              history.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              history.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookshelf() {
    if (_bookshelfComics.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(
              children: [
                const Icon(Icons.collections_bookmark_outlined, size: 48),
                const SizedBox(height: 16),
                Text("No imported comics".tl),
              ],
            ),
          ),
        ),
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "${_bookshelfComics.length} ${"comics".tl}",
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGridComics(
            comics: _bookshelfComics,
            onTap: (comic, _) {
              var localComic = comic as LocalComic;
              localComic.read();
            },
          ),
        ),
      ],
    );
  }

  void _showConfigDialog() {
    var config = _manager.config;
    _urlController.text = config?['url'] ?? '';
    _usernameController.text = config?['username'] ?? '';
    _passwordController.text = config?['password'] ?? '';
    _basePathController.text = config?['basePath'] ?? '/';

    showDialog(
      context: context,
      builder: (dialogContext) {
        return ContentDialog(
          title: "WebDAV Settings".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: "WebDAV URL".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: "Username".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "Password".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _basePathController,
                decoration: InputDecoration(
                  labelText: "Base Path".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                _saveConfig();
                dialogContext.pop();
              },
              child: Text("Save".tl),
            ),
          ],
        );
      },
    );
  }

  IconData _getFileIcon(String filename) {
    var ext = filename.split('.').last.toLowerCase();
    const imageExts = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'avif'];
    const archiveExts = ['zip', 'cbz', 'rar', 'cbr', 'cb7', '7z'];
    if (imageExts.contains(ext)) return Icons.image;
    if (ext == 'mobi' || ext == 'azw' || ext == 'azw3' || ext == 'azw4') {
      return Icons.menu_book;
    }
    if (archiveExts.contains(ext)) return Icons.archive;
    if (ext == 'pdf') return Icons.picture_as_pdf;
    return Icons.insert_drive_file;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)}GB';
  }

  String _stripFileExtension(String fileName) {
    var index = fileName.lastIndexOf('.');
    if (index > 0) {
      return fileName.substring(0, index).trim();
    }
    return fileName.trim();
  }
}

enum _ViewMode { browse, scanned, bookshelf }

class _CoverSearchNode {
  final String path;
  final int depth;

  const _CoverSearchNode(this.path, this.depth);
}
