// WebDAV 漫画图片提供器
// @author: kirk

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_comic_manager.dart';
import 'package:venera/utils/io.dart';

/// WebDAV 漫画图片提供器
///
/// 用于加载 WebDAV 服务器上的漫画图片，支持本地缓存
class WebDavComicImageProvider extends BaseImageProvider<WebDavComicImageProvider> {
  final String remotePath;  // 相对于 basePath 的路径

  const WebDavComicImageProvider(this.remotePath);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    // 1. 检查缓存
    var cacheFile = _getCacheFile(remotePath);
    if (await cacheFile.exists()) {
      Log.info('WebDavComicImageProvider', 'Loading from cache: $remotePath');
      return await cacheFile.readAsBytes();
    }

    checkStop();

    // 2. 从 WebDAV 下载
    Log.info('WebDavComicImageProvider', 'Downloading from WebDAV: $remotePath');
    var manager = WebDavComicManager();
    var bytes = await manager.readFile(remotePath);

    checkStop();

    // 3. 写入缓存
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes);
      Log.info('WebDavComicImageProvider', 'Cached: $remotePath');
    } catch (e, s) {
      Log.error('WebDavComicImageProvider', 'Failed to cache image: $e', s);
      // 继续返回数据，即使缓存失败
    }

    return bytes;
  }

  @override
  String get key => "webdav://$remotePath";

  @override
  bool get enableResize => true;

  @override
  Future<WebDavComicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  /// 获取缓存文件路径
  File _getCacheFile(String path) {
    var cachePath = App.cachePath;
    // 规范化路径
    if (path.startsWith('/')) {
      path = path.substring(1);
    }
    return File('$cachePath/webdav_comics/$path');
  }
}
