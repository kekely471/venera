// WebDAV PDF 阅读页面
// @author: kirk

import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/foundation/webdav_pdf_service.dart';

class WebDavPdfReaderPage extends StatefulWidget {
  final String? filePath;
  final String? remotePath;
  final int? remoteSize;
  final String title;

  const WebDavPdfReaderPage({
    super.key,
    required this.filePath,
    required this.title,
  }) : remotePath = null,
       remoteSize = null;

  const WebDavPdfReaderPage.webdav({
    super.key,
    required this.remotePath,
    required this.title,
    this.remoteSize,
  }) : filePath = null,
       assert(remotePath != null);

  @override
  State<WebDavPdfReaderPage> createState() => _WebDavPdfReaderPageState();
}

class _WebDavPdfReaderPageState extends State<WebDavPdfReaderPage> {
  static const int _rangeChunkSize = 256 * 1024;
  static const int _maxRangeCacheChunks = 32;

  final _manager = WebDavComicManager();
  final LinkedHashMap<int, Uint8List> _rangeChunkCache = LinkedHashMap();
  final Map<int, Future<Uint8List>> _rangeChunkInFlight = {};

  FocusNode? _focusNode;
  int _currentPage = 1;
  int _totalPages = 0;
  PdfDocumentRef? _documentRef;
  int? _resolvedRemoteSize;
  bool _isPreparingDocument = true;
  String? _loadError;
  int _readSession = 0;
  int? _lastSavedPage;
  int? _lastSavedMaxPage;

  FocusNode get _keyboardFocusNode =>
      _focusNode ??= FocusNode(debugLabel: 'webdav_pdf_reader');

  @override
  void initState() {
    super.initState();
    _restoreReadingProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keyboardFocusNode.requestFocus();
    });
    _prepareDocumentRef();
  }

  @override
  void dispose() {
    _recordReadingProgress();
    _readSession++;
    _rangeChunkInFlight.clear();
    _rangeChunkCache.clear();
    _focusNode?.dispose();
    super.dispose();
  }

  String? get _historyId {
    final remotePath = widget.remotePath;
    if (remotePath == null) return null;
    return WebDavPdfService.buildBookId(remotePath);
  }

  void _restoreReadingProgress() {
    final historyId = _historyId;
    if (historyId == null) return;

    final history = HistoryManager().find(historyId, ComicType.webdav);
    if (history == null) return;

    _currentPage = history.page <= 0 ? 1 : history.page;
    _totalPages = history.maxPage ?? 0;
    _lastSavedPage = history.page <= 0 ? 1 : history.page;
    _lastSavedMaxPage = history.maxPage;
  }

  void _recordReadingProgress() {
    final historyId = _historyId;
    final remotePath = widget.remotePath;
    if (historyId == null || remotePath == null) return;

    final page = _currentPage <= 0 ? 1 : _currentPage;
    final maxPage = _totalPages > 0 ? _totalPages : null;
    if (_lastSavedPage == page && _lastSavedMaxPage == maxPage) {
      return;
    }

    _lastSavedPage = page;
    _lastSavedMaxPage = maxPage;

    final history = History.fromMap({
      'type': ComicType.webdav.value,
      'id': historyId,
      'ep': 1,
      'page': page,
      'max_page': maxPage,
      'time': DateTime.now().millisecondsSinceEpoch,
      'title': widget.title,
      'subtitle': '',
      'cover': remotePath,
      'readEpisode': const <String>[],
    });
    HistoryManager().addHistory(history);
  }

  Future<void> _prepareDocumentRef() async {
    final session = ++_readSession;
    setState(() {
      _isPreparingDocument = true;
      _loadError = null;
    });

    try {
      if (widget.remotePath != null) {
        var fileSize = widget.remoteSize;
        fileSize ??= await _manager.getFileSize(widget.remotePath!);
        if (fileSize <= 0) {
          throw Exception('Invalid PDF file size');
        }

        _resolvedRemoteSize = fileSize;
        final probeEnd = fileSize > 1 ? 1 : 0;
        final probeResult = await _manager.readFileRange(
          widget.remotePath!,
          start: 0,
          end: probeEnd,
        );
        if (probeResult.isPartial) {
          _documentRef = PdfDocumentRefCustom(
            fileSize: fileSize,
            sourceName: _buildRemoteSourceName(widget.remotePath!, fileSize),
            useProgressiveLoading: true,
            read: (buffer, position, size) =>
                _readRemoteBytes(buffer, position, size, session),
          );
        } else {
          final remoteName = _remoteFileName(widget.remotePath!);
          final localBook = await WebDavPdfService().prepareFromWebDav(
            remotePath: widget.remotePath!,
            fileName: remoteName,
            remoteSize: fileSize,
          );
          _documentRef = PdfDocumentRefFile(
            localBook.filePath,
            useProgressiveLoading: true,
          );
        }
      } else if (widget.filePath != null) {
        _documentRef = PdfDocumentRefFile(
          widget.filePath!,
          useProgressiveLoading: true,
        );
      } else {
        throw Exception('No PDF source provided');
      }
    } catch (e, s) {
      Log.error('WebDavPdfReaderPage', 'Failed to prepare pdf source: $e', s);
      if (!mounted || session != _readSession) return;
      setState(() {
        _isPreparingDocument = false;
        _loadError = e.toString();
      });
      return;
    }

    if (!mounted || session != _readSession) return;
    setState(() {
      _isPreparingDocument = false;
      _loadError = null;
    });
  }

  String _buildRemoteSourceName(String remotePath, int fileSize) {
    return 'webdav-pdf://$remotePath?size=$fileSize';
  }

  String _remoteFileName(String remotePath) {
    var index = remotePath.lastIndexOf('/');
    if (index >= 0 && index < remotePath.length - 1) {
      return remotePath.substring(index + 1);
    }
    return remotePath;
  }

  Future<int> _readRemoteBytes(
    Uint8List buffer,
    int position,
    int size,
    int session,
  ) async {
    if (session != _readSession) return 0;
    if (widget.remotePath == null || _resolvedRemoteSize == null) return 0;
    if (position < 0 || size <= 0) return 0;

    final totalSize = _resolvedRemoteSize!;
    if (position >= totalSize) return 0;

    final targetLength = math.min(size, totalSize - position);
    var copied = 0;

    while (copied < targetLength) {
      if (session != _readSession) return copied;

      final absoluteOffset = position + copied;
      final chunkIndex = absoluteOffset ~/ _rangeChunkSize;
      final chunkStart = chunkIndex * _rangeChunkSize;
      final chunkEnd = math.min(
        chunkStart + _rangeChunkSize - 1,
        totalSize - 1,
      );
      final chunk = await _getOrLoadChunk(
        remotePath: widget.remotePath!,
        chunkIndex: chunkIndex,
        chunkStart: chunkStart,
        chunkEnd: chunkEnd,
        session: session,
      );
      if (chunk.isEmpty) break;

      final offsetInChunk = absoluteOffset - chunkStart;
      if (offsetInChunk < 0 || offsetInChunk >= chunk.length) break;

      final canCopy = math.min(
        targetLength - copied,
        chunk.length - offsetInChunk,
      );
      buffer.setRange(copied, copied + canCopy, chunk, offsetInChunk);
      copied += canCopy;
    }

    return copied;
  }

  Future<Uint8List> _getOrLoadChunk({
    required String remotePath,
    required int chunkIndex,
    required int chunkStart,
    required int chunkEnd,
    required int session,
  }) async {
    final cached = _rangeChunkCache.remove(chunkIndex);
    if (cached != null) {
      _rangeChunkCache[chunkIndex] = cached;
      return cached;
    }

    final loading = _rangeChunkInFlight[chunkIndex];
    if (loading != null) {
      return loading;
    }

    final future = Future<Uint8List>(() async {
      final rangeResult = await _manager.readFileRange(
        remotePath,
        start: chunkStart,
        end: chunkEnd,
      );
      if (session != _readSession) return Uint8List(0);
      if (_resolvedRemoteSize == null && rangeResult.totalSize != null) {
        _resolvedRemoteSize = rangeResult.totalSize;
      }
      final bytes = rangeResult.bytes;
      if (bytes.isEmpty) return bytes;
      _rangeChunkCache[chunkIndex] = bytes;
      _trimChunkCache();
      return bytes;
    });

    _rangeChunkInFlight[chunkIndex] = future;
    try {
      return await future;
    } finally {
      if (identical(_rangeChunkInFlight[chunkIndex], future)) {
        _rangeChunkInFlight.remove(chunkIndex);
      }
    }
  }

  void _trimChunkCache() {
    while (_rangeChunkCache.length > _maxRangeCacheChunks) {
      _rangeChunkCache.remove(_rangeChunkCache.keys.first);
    }
  }

  Future<void> _goToPage(int page) async {
    if (_totalPages <= 0) return;
    final target = page.clamp(1, _totalPages);
    if (target == _currentPage) return;
    setState(() {
      _currentPage = target;
    });
    _recordReadingProgress();
  }

  Future<void> _goPrevPage() async => _goToPage(_currentPage - 1);

  Future<void> _goNextPage() async => _goToPage(_currentPage + 1);

  void _syncPageState(int totalPages) {
    final oldTotalPages = _totalPages;
    _totalPages = totalPages;
    if (totalPages <= 0) return;
    final clamped = _currentPage.clamp(1, totalPages);
    if (clamped == _currentPage) {
      if (oldTotalPages != totalPages) {
        _recordReadingProgress();
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _currentPage = clamped;
      });
      _recordReadingProgress();
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      _goPrevPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _goNextPage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTapToFlip(TapUpDetails details, BoxConstraints constraints) {
    _keyboardFocusNode.requestFocus();
    final width = constraints.maxWidth;
    if (width <= 0) return;
    final x = details.localPosition.dx;
    if (x < width * 0.5) {
      _goPrevPage();
    } else {
      _goNextPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Focus(
        autofocus: true,
        focusNode: _keyboardFocusNode,
        onKeyEvent: _handleKeyEvent,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isPreparingDocument) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36),
              const SizedBox(height: 12),
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _prepareDocumentRef,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_documentRef == null) {
      return const Center(child: Text('No readable source'));
    }

    return PdfDocumentViewBuilder(
      documentRef: _documentRef!,
      builder: (context, document) {
        if (document == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final totalPages = document.pages.length;
        _syncPageState(totalPages);
        if (totalPages <= 0) {
          return const Center(child: Text('No readable pages'));
        }
        final currentPage = _currentPage.clamp(1, totalPages);

        return Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) =>
                        _handleTapToFlip(details, constraints),
                    onHorizontalDragEnd: (details) {
                      _keyboardFocusNode.requestFocus();
                      final velocity = details.primaryVelocity ?? 0;
                      if (velocity.abs() < 120) return;
                      if (velocity < 0) {
                        _goToPage(currentPage + 1);
                      } else {
                        _goToPage(currentPage - 1);
                      }
                    },
                    child: ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: PdfPageView(
                          key: ValueKey<int>(currentPage),
                          document: document,
                          pageNumber: currentPage,
                          backgroundColor: Colors.white,
                          decoration: const BoxDecoration(color: Colors.white),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              height: 36,
              color: Colors.black,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  IconButton(
                    iconSize: 18,
                    splashRadius: 18,
                    color: Colors.white70,
                    onPressed: currentPage > 1
                        ? () => _goToPage(currentPage - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '$currentPage / $totalPages',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    iconSize: 18,
                    splashRadius: 18,
                    color: Colors.white70,
                    onPressed: currentPage < totalPages
                        ? () => _goToPage(currentPage + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
