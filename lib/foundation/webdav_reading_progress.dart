// WebDAV 阅读进度同步服务
// @author: kirk

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_cache.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';

/// WebDAV 阅读进度同步
///
/// 在 WebDAV 隐藏目录下维护阅读进度，
/// 仅同步 ComicType.webdav 的阅读记录。
class WebDavReadingProgress {
  static const _legacyFilePath = '/reading_progress.json';
  static const _version = 2;

  final _manager = WebDavComicManager();

  /// 推送本地 WebDAV 漫画阅读进度到远程，并按条目时间戳合并远端数据。
  Future<void> pushProgress() async {
    final localEntries = _collectLocalEntries();
    final remoteSnapshot = await _readRemoteSnapshot();
    final mergeResult = _mergeEntries(
      localEntries: localEntries,
      remoteEntries: remoteSnapshot.entries,
    );

    final updatedLocalCount = _applyRemoteNewerEntries(
      mergedEntries: mergeResult.entries,
      localEntries: localEntries,
    );
    await _writeRemoteEntries(mergeResult.entries);

    Log.info(
      'WebDavReadingProgress',
      'Pushed ${mergeResult.entries.length} progress records, updated local $updatedLocalCount records',
    );
  }

  /// 从远程拉取阅读进度并与本地合并。
  Future<int> pullProgress() async {
    final remoteSnapshot = await _readRemoteSnapshot();
    if (!remoteSnapshot.exists) {
      Log.info('WebDavReadingProgress', 'No remote progress file found');
      return 0;
    }

    final localEntries = _collectLocalEntries();
    final mergeResult = _mergeEntries(
      localEntries: localEntries,
      remoteEntries: remoteSnapshot.entries,
    );
    final updatedCount = _applyRemoteNewerEntries(
      mergedEntries: mergeResult.entries,
      localEntries: localEntries,
    );

    if (mergeResult.remoteNeedsUpdate || remoteSnapshot.isLegacyPath) {
      await _writeRemoteEntries(mergeResult.entries);
    }

    Log.info('WebDavReadingProgress', 'Pulled $updatedCount progress records');
    return updatedCount;
  }

  Map<String, _ReadingProgressEntry> _collectLocalEntries() {
    final histories = HistoryManager().getAll();
    final webdavHistories = histories
        .where((h) => h.type == ComicType.webdav)
        .toList();

    final items = <String, _ReadingProgressEntry>{};
    for (var history in webdavHistories) {
      items[history.id] = _ReadingProgressEntry.fromHistory(history);
    }
    return items;
  }

  Future<_RemoteProgressSnapshot> _readRemoteSnapshot() async {
    final primary = await _tryReadRemoteProgress(
      WebDavCachePaths.readingProgressFilePath,
    );
    if (primary != null) {
      return _RemoteProgressSnapshot(
        exists: true,
        isLegacyPath: false,
        entries: primary,
      );
    }

    final legacy = await _tryReadRemoteProgress(_legacyFilePath);
    if (legacy != null) {
      return _RemoteProgressSnapshot(
        exists: true,
        isLegacyPath: true,
        entries: legacy,
      );
    }

    return const _RemoteProgressSnapshot(
      exists: false,
      isLegacyPath: false,
      entries: <String, _ReadingProgressEntry>{},
    );
  }

  Future<Map<String, _ReadingProgressEntry>?> _tryReadRemoteProgress(
    String remotePath,
  ) async {
    Uint8List bytes;
    try {
      bytes = await _manager.readFile(remotePath);
    } catch (e) {
      if (_isNotFoundError(e)) {
        return null;
      }
      Log.error(
        'WebDavReadingProgress',
        'Failed to read remote progress file $remotePath: $e',
      );
      rethrow;
    }

    try {
      final json = utf8.decode(bytes);
      final data = jsonDecode(json);
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Invalid progress payload');
      }
      final items = data['items'];
      if (items is! Map) {
        return <String, _ReadingProgressEntry>{};
      }

      final result = <String, _ReadingProgressEntry>{};
      for (final entry in items.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          continue;
        }
        result[entry.key] = _ReadingProgressEntry.fromJson(entry.key, value);
      }
      return result;
    } catch (e, s) {
      Log.error(
        'WebDavReadingProgress',
        'Failed to parse remote progress JSON from $remotePath: $e',
        s,
      );
      throw Exception('Invalid remote reading progress data');
    }
  }

  _ProgressMergeResult _mergeEntries({
    required Map<String, _ReadingProgressEntry> localEntries,
    required Map<String, _ReadingProgressEntry> remoteEntries,
  }) {
    final merged = <String, _ReadingProgressEntry>{};
    final ids = <String>{...localEntries.keys, ...remoteEntries.keys};
    var remoteNeedsUpdate = false;

    for (final id in ids) {
      final local = localEntries[id];
      final remote = remoteEntries[id];

      if (local == null && remote != null) {
        merged[id] = remote;
        continue;
      }
      if (remote == null && local != null) {
        merged[id] = local;
        remoteNeedsUpdate = true;
        continue;
      }
      if (local == null || remote == null) {
        continue;
      }

      if (remote.timeMs > local.timeMs) {
        merged[id] = remote;
        continue;
      }

      merged[id] = local;
      if (!local.sameAs(remote)) {
        remoteNeedsUpdate = true;
      }
    }

    return _ProgressMergeResult(
      entries: merged,
      remoteNeedsUpdate: remoteNeedsUpdate,
    );
  }

  int _applyRemoteNewerEntries({
    required Map<String, _ReadingProgressEntry> mergedEntries,
    required Map<String, _ReadingProgressEntry> localEntries,
  }) {
    var updatedCount = 0;

    for (final entry in mergedEntries.entries) {
      final local = localEntries[entry.key];
      if (local != null && local.timeMs >= entry.value.timeMs) {
        continue;
      }
      HistoryManager().addHistory(entry.value.toHistory());
      updatedCount++;
    }

    return updatedCount;
  }

  Future<void> _writeRemoteEntries(
    Map<String, _ReadingProgressEntry> entries,
  ) async {
    await _manager.createDirectoryAll(WebDavCachePaths.metadataDirectoryPath);

    final items = <String, dynamic>{};
    for (final entry in entries.entries) {
      items[entry.key] = entry.value.toJson();
    }

    final data = {
      'version': _version,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'items': items,
    };

    final json = const JsonEncoder.withIndent('  ').convert(data);
    final bytes = Uint8List.fromList(utf8.encode(json));

    await _manager.writeFile(WebDavCachePaths.readingProgressFilePath, bytes);
  }

  bool _isNotFoundError(Object error) {
    if (error is DioException) {
      return error.response?.statusCode == 404;
    }

    final text = error.toString();
    return RegExp(r'Invalid Status Code:?\s*404\b').hasMatch(text) ||
        text.contains('404');
  }
}

class _RemoteProgressSnapshot {
  final bool exists;
  final bool isLegacyPath;
  final Map<String, _ReadingProgressEntry> entries;

  const _RemoteProgressSnapshot({
    required this.exists,
    required this.isLegacyPath,
    required this.entries,
  });
}

class _ProgressMergeResult {
  final Map<String, _ReadingProgressEntry> entries;
  final bool remoteNeedsUpdate;

  const _ProgressMergeResult({
    required this.entries,
    required this.remoteNeedsUpdate,
  });
}

class _ReadingProgressEntry {
  final String id;
  final int ep;
  final int page;
  final int? group;
  final int? maxPage;
  final Set<String> readEpisode;
  final int timeMs;
  final String title;
  final String subtitle;
  final String cover;

  const _ReadingProgressEntry({
    required this.id,
    required this.ep,
    required this.page,
    required this.group,
    required this.maxPage,
    required this.readEpisode,
    required this.timeMs,
    required this.title,
    required this.subtitle,
    required this.cover,
  });

  factory _ReadingProgressEntry.fromHistory(History history) {
    return _ReadingProgressEntry(
      id: history.id,
      ep: history.ep,
      page: history.page,
      group: history.group,
      maxPage: history.maxPage,
      readEpisode: history.readEpisode,
      timeMs: history.time.millisecondsSinceEpoch,
      title: history.title,
      subtitle: history.subtitle,
      cover: history.cover,
    );
  }

  factory _ReadingProgressEntry.fromJson(
    String id,
    Map<String, dynamic> json,
  ) {
    return _ReadingProgressEntry(
      id: id,
      ep: json['ep'] as int? ?? 1,
      page: json['page'] as int? ?? 1,
      group: json['group'] as int?,
      maxPage: json['maxPage'] as int?,
      readEpisode: Set<String>.from(
        (json['readEpisode'] as List<dynamic>? ?? const <dynamic>[]).map(
          (e) => e.toString(),
        ),
      ),
      timeMs: json['time'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ep': ep,
      'page': page,
      'group': group,
      'maxPage': maxPage,
      'readEpisode': readEpisode.toList(),
      'time': timeMs,
      'title': title,
      'subtitle': subtitle,
      'cover': cover,
    };
  }

  History toHistory() {
    final history = History.fromMap({
      'type': ComicType.webdav.value,
      'id': id,
      'ep': ep,
      'page': page,
      'max_page': maxPage,
      'time': timeMs,
      'title': title,
      'subtitle': subtitle,
      'cover': cover,
      'readEpisode': readEpisode.toList(),
    });
    history.group = group;
    return history;
  }

  bool sameAs(_ReadingProgressEntry other) {
    if (ep != other.ep ||
        page != other.page ||
        group != other.group ||
        maxPage != other.maxPage ||
        timeMs != other.timeMs ||
        title != other.title ||
        subtitle != other.subtitle ||
        cover != other.cover) {
      return false;
    }

    if (readEpisode.length != other.readEpisode.length) {
      return false;
    }

    for (final episode in readEpisode) {
      if (!other.readEpisode.contains(episode)) {
        return false;
      }
    }

    return true;
  }
}
