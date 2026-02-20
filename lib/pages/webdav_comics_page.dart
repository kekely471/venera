// WebDAV 漫画浏览管理页面
// @author: kirk

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_archive_service.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/foundation/webdav_mobi_service.dart';
import 'package:venera/foundation/webdav_pdf_service.dart';
import 'package:venera/pages/webdav_pdf_reader_page.dart';

import 'package:venera/utils/translations.dart';

class WebDavComicsPage extends StatefulWidget {
  const WebDavComicsPage({super.key});

  @override
  State<WebDavComicsPage> createState() => _WebDavComicsPageState();
}

class _WebDavComicsPageState extends State<WebDavComicsPage> {
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

  // 显示模式
  _ViewMode _viewMode = _ViewMode.browse;

  @override
  void initState() {
    super.initState();
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
      if (mounted) {
        setState(() {
          _currentPath = path;
          _currentFiles = files;
          _isBrowsing = false;
          _viewMode = _ViewMode.browse;
        });
      }
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

  Future<void> _clearCache() async {
    await _manager.clearCache();
    await _loadCacheSize();
    if (mounted) {
      showToast(message: "Cache Cleared".tl, context: context);
    }
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
          _buildBreadcrumb(),
          if (_error != null) _buildError(),
          if (_isBrowsing || _isScanning) _buildLoading(),
          if (_viewMode == _ViewMode.browse && !_isBrowsing) _buildFileList(),
          if (_viewMode == _ViewMode.scanned && !_isScanning)
            _buildScannedComics(),
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
      if (_viewMode == _ViewMode.scanned)
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
            icon: Icons.refresh,
            text: "Refresh".tl,
            onClick: () => _loadDirectory(_currentPath),
          ),
          MenuEntry(
            icon: Icons.cleaning_services_outlined,
            text:
                "${"Clear Cache".tl}${_cacheSize != null ? ' ($_cacheSize)' : ''}",
            onClick: _clearCache,
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
      showToast(message: "Loading...".tl, context: context);
      var mobiBook = await WebDavMobiService().prepareFromWebDav(
        remotePath: path,
        fileName: file.name,
        remoteSize: file.size,
        remoteModifiedTime: file.modifiedTime,
      );
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
      showToast(message: "Loading...".tl, context: context);
      final pdfBook = await WebDavPdfService().prepareFromWebDav(
        remotePath: path,
        fileName: file.name,
        remoteSize: file.size,
        remoteModifiedTime: file.modifiedTime,
      );
      if (!mounted) return;
      context.to(
        () => WebDavPdfReaderPage(
          filePath: pdfBook.filePath,
          title: pdfBook.title,
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
      final archiveBook = await WebDavArchiveService().prepareFromWebDav(
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
        // 如果目录包含图片，显示"阅读此漫画"按钮
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
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            var file = _currentFiles[index];
            return ListTile(
              leading: Icon(
                file.isDirectory ? Icons.folder : _getFileIcon(file.name),
                color: file.isDirectory
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(file.name),
              subtitle: file.isDirectory
                  ? null
                  : Text(_formatFileSize(file.size ?? 0)),
              trailing: file.isDirectory
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu_book, size: 20),
                          tooltip: "Read as comic".tl,
                          onPressed: () {
                            var path = _currentPath == '/'
                                ? '/${file.name}'
                                : '$_currentPath/${file.name}';
                            _openDirectoryAsComic(path);
                          },
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    )
                  : null,
              onTap: () {
                if (file.isDirectory) {
                  var newPath = _currentPath == '/'
                      ? '/${file.name}'
                      : '$_currentPath/${file.name}';
                  _loadDirectory(newPath);
                } else if (_isImageFile(file.name)) {
                  // 点击图片文件，打开当前目录为漫画
                  _openCurrentDirAsComic();
                } else if (_isMobiFile(file.name)) {
                  var path = _currentPath == '/'
                      ? '/${file.name}'
                      : '$_currentPath/${file.name}';
                  _openMobiFile(path, file);
                } else if (_isPdfFile(file.name)) {
                  var path = _currentPath == '/'
                      ? '/${file.name}'
                      : '$_currentPath/${file.name}';
                  _openPdfFile(path, file);
                } else if (_isArchiveFile(file.name)) {
                  var path = _currentPath == '/'
                      ? '/${file.name}'
                      : '$_currentPath/${file.name}';
                  _openArchiveFile(path, file);
                }
              },
            );
          }, childCount: _currentFiles.length),
        ),
      ],
    );
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
}

enum _ViewMode { browse, scanned }
