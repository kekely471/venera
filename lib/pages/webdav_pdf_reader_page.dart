// WebDAV PDF 阅读页面
// @author: kirk

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

class WebDavPdfReaderPage extends StatefulWidget {
  final String filePath;
  final String title;

  const WebDavPdfReaderPage({
    super.key,
    required this.filePath,
    required this.title,
  });

  @override
  State<WebDavPdfReaderPage> createState() => _WebDavPdfReaderPageState();
}

class _WebDavPdfReaderPageState extends State<WebDavPdfReaderPage> {
  FocusNode? _focusNode;
  int _currentPage = 1;
  int _totalPages = 0;

  FocusNode get _keyboardFocusNode =>
      _focusNode ??= FocusNode(debugLabel: 'webdav_pdf_reader');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keyboardFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode?.dispose();
    super.dispose();
  }

  Future<void> _goToPage(int page) async {
    if (_totalPages <= 0) return;
    final target = page.clamp(1, _totalPages);
    if (target == _currentPage) return;
    setState(() {
      _currentPage = target;
    });
  }

  Future<void> _goPrevPage() async => _goToPage(_currentPage - 1);

  Future<void> _goNextPage() async => _goToPage(_currentPage + 1);

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
        child: PdfDocumentViewBuilder.file(
          widget.filePath,
          builder: (context, document) {
            if (document == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final totalPages = document.pages.length;
            _totalPages = totalPages;
            if (_currentPage > totalPages && totalPages > 0) {
              _currentPage = totalPages;
            }
            if (_currentPage < 1 && totalPages > 0) {
              _currentPage = 1;
            }

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
                            _goNextPage();
                          } else {
                            _goPrevPage();
                          }
                        },
                        child: ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: PdfPageView(
                              key: ValueKey<int>(_currentPage),
                              document: document,
                              pageNumber: _currentPage,
                              backgroundColor: Colors.white,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                              ),
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
                        onPressed: _currentPage > 1 ? _goPrevPage : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            '$_currentPage / $totalPages',
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
                        onPressed: _currentPage < totalPages
                            ? _goNextPage
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
        ),
      ),
    );
  }
}
