// WebDAV 阅读进度同步服务
// @author: luoyang

import 'dart:convert';
import 'dart:typed_data';

import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';

/// WebDAV 阅读进度同步
///
/// 在 WebDAV basePath 下维护 `reading_progress.json`，
/// 仅同步 ComicType.webdav 的阅读进度。
class WebDavReadingProgress {
  static const _fileName = '/reading_progress.json';
  static const _version = 1;

  final _manager = WebDavComicManager();

  /// 推送本地 WebDAV 漫画阅读进度到远程
  Future<void> pushProgress() async {
    var histories = HistoryManager().getAll();
    var webdavHistories = histories
        .where((h) => h.type == ComicType.webdav)
        .toList();

    var items = <String, dynamic>{};
    for (var h in webdavHistories) {
      items[h.id] = {
        'ep': h.ep,
        'page': h.page,
        'group': h.group,
        'maxPage': h.maxPage,
        'readEpisode': h.readEpisode.toList(),
        'time': h.time.millisecondsSinceEpoch,
        'title': h.title,
        'subtitle': h.subtitle,
        'cover': h.cover,
      };
    }

    var data = {
      'version': _version,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'items': items,
    };

    var json = const JsonEncoder.withIndent('  ').convert(data);
    var bytes = Uint8List.fromList(utf8.encode(json));

    await _manager.writeFile(_fileName, bytes);
    Log.info('WebDavReadingProgress',
        'Pushed ${webdavHistories.length} progress records');
  }

  /// 从远程拉取阅读进度并覆盖本地
  Future<int> pullProgress() async {
    Uint8List bytes;
    try {
      bytes = await _manager.readFile(_fileName);
    } catch (e) {
      Log.info('WebDavReadingProgress',
          'No remote progress file found: $e');
      return 0;
    }

    var json = utf8.decode(bytes);
    var data = jsonDecode(json) as Map<String, dynamic>;
    var items = data['items'] as Map<String, dynamic>? ?? {};

    var count = 0;
    for (var entry in items.entries) {
      var id = entry.key;
      var value = entry.value as Map<String, dynamic>;

      var history = History.fromMap({
        'type': ComicType.webdav.value,
        'id': id,
        'ep': value['ep'] ?? 1,
        'page': value['page'] ?? 1,
        'max_page': value['maxPage'],
        'time': value['time'] ?? 0,
        'title': value['title'] ?? '',
        'subtitle': value['subtitle'] ?? '',
        'cover': value['cover'] ?? '',
        'readEpisode': value['readEpisode'] as List<dynamic>?,
      });
      history.group = value['group'] as int?;

      HistoryManager().addHistory(history);
      count++;
    }

    Log.info('WebDavReadingProgress', 'Pulled $count progress records');
    return count;
  }
}
